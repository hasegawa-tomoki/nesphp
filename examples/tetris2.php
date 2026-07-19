<?php
// Tetris v2: tetris.php の作り直し (tetris.php は参照用に残置)
//
// v1 からの修正点:
//   * GAME OVER 判定: v1 は「grid[0] (最上段) にセルが固定されたとき」のみで、
//     ほとんどの shape は上段が空なので実質発動しなかった。v2 は新ピースの
//     スポーン位置 (px=6, py=5) と固定ブロックの重なりで判定する。
//   * ライン消去: 圧縮ロジックを整理。ext RAM には「描画タイル番号」を直接
//     持たせ (空セル = 0x20 スペース)、消去後の再描画は変化した行
//     (row 0..最下消去行) だけに限定して高速化。
//   * 移動判定を 1 つの衝突判定ループに統合 (回転/水平/落下の 3 フェーズ)。
//   * 落下ピースは差分描画 (新位置を描いてから重ならない旧セルだけ消す)。
//     どの瞬間もピースが消えないのでちらつかない。
//
// キャラクタ (ピースタイル 0x05-0x0B、レンガ 0x0C) と shape table は v1 踏襲。
//
// compiler 制約への対応:
//   * ブロックネストは最大 7 段 (backpatch stack 上限)
//   * `/` (除算) は host PHP と結果が変わるので不使用 (行×列の 2 重ループで代替)
//   * 乗算の優先順位に依存しないよう括弧を明示
//   * ネストした関数呼び出しは不可 → 一時変数を経由

nes_puts(4, 1, "TETRIS 2");

// レンガ壁: play field (col 4-13, row 5-25) の外側を tile 0x0C で囲む
$x = 3;
while ($x <= 14) {
    nes_put($x, 3, 0x0C);
    nes_put($x, 26, 0x0C);
    $x = $x + 1;
}
$y = 4;
while ($y <= 25) {
    nes_put(3, $y, 0x0C);
    nes_put(14, $y, 0x0C);
    $y = $y + 1;
}

nes_puts(17, 5, "SCORE");

// ピース色用 palette 1: 白/赤/緑 (universal bg = 黒)
nes_palette(1, 0x30, 0x16, 0x1A);

// play field 全 cell を attribute palette 1 に
$ay = 2;
while ($ay <= 12) {
    $ax = 2;
    while ($ax <= 6) {
        nes_attr($ax, $ay, 1);
        $ax = $ax + 1;
    }
    $ay = $ay + 1;
}

// shape 表 (v1 と同一): 7 ピース × 4 回転 = 28 entry × 2 byte
//   I: 0x00F0/0x2222  O: 0x0660  T: 0x0720/0x0262/0x0270/0x0232
//   S: 0x0360/0x0462  Z: 0x0630/0x0264
//   L: 0x0470/0x0322/0x0710/0x0226  J: 0x0170/0x0223/0x0740/0x0622
nes_pokestr(0, "\xF0\x00\x22\x22\xF0\x00\x22\x22\x60\x06\x60\x06\x60\x06\x60\x06\x20\x07\x62\x02\x70\x02\x32\x02\x60\x03\x62\x04\x60\x03\x62\x04\x30\x06\x64\x02\x30\x06\x64\x02\x70\x04\x22\x03\x10\x07\x26\x02\x70\x01\x23\x02\x40\x07\x22\x06");

// grid: 21 行分の占有 bitmask (bit0 = 左端 col 4)
$grid = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
$first_time = 1;
$score = 0;

// セッションループ: 起動時 + GAME OVER 後の再スタート
while (true) {
    if ($first_time === 0) {
        nes_puts(5, 13, "GAME OVER");
    }
    nes_puts(4, 17, "PUSH START");

    // PUSH START 待ちでランダム seed を稼ぐ
    $seed = 1;
    $ready = 0;
    while ($ready === 0) {
        nes_vsync();
        $seed = $seed + 1;
        if (nes_btn() & 0x10) {
            $ready = 1;
        }
    }
    nes_srand($seed);
    $first_time = 0;

    // field クリア (画面 + grid + ext)。GAME OVER / PUSH START の表示も
    // play field 内 (col 4-13) なのでこのループが消してくれる。
    // ext RAM は「描画タイル」を持つので空セル = 0x20 (スペース)。
    $r = 0;
    while ($r < 21) {
        $grid[$r] = 0;
        $c = 0;
        while ($c < 10) {
            nes_put($c + 4, $r + 5, " ");
            nes_poke_ext(($r * 10) + $c, 0x20);
            $c = $c + 1;
        }
        $r = $r + 1;
    }

    $score = 0;
    nes_putint(17, 7, $score);

    $game_over = 0;
    $spawn = 1;
    $frame = 0;
    $prev_btn = 0;
    $piece = 0;
    $tile = 0;
    $rot = 0;
    $shape = 0;
    $px = 6;
    $py = 5;

    while ($game_over === 0) {
        // --- スポーン (初回 + lock 後) ---
        if ($spawn) {
            $spawn = 0;
            $piece = (nes_rand() & 0x7FFF) % 7;
            $tile = $piece + 5;
            $rot = 0;
            $shape = nes_peek16($piece * 8);
            $px = 6;
            $py = 5;

            // GAME OVER 判定: スポーン位置 (grid 列 2-5, 行 0-3) との重なり。
            // px=6 固定なので grid 行を 2bit 右シフトすると shape の行 nibble と
            // 桁が揃う。
            $i = 0;
            while ($i < 4) {
                if (($shape >> ($i * 4)) & 0xF & ($grid[$i] >> 2)) {
                    $game_over = 1;
                }
                $i = $i + 1;
            }

            // スポーン描画 (重なって死んだときも「詰まった」のが見えるよう描く)
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    nes_put($px + ($i & 3), $py + ($i >> 2), $tile);
                }
                $i = $i + 1;
            }
        }

        nes_vsync();
        $b = nes_btn();
        $pressed = $b & (0xFF - $prev_btn);
        $prev_btn = $b;

        $dx = 0;
        $dy = 0;
        $rot_d = 0;
        if ($pressed & 0x02)     { $dx = 0 - 1; }
        elseif ($pressed & 0x01) { $dx = 1; }
        if ($pressed & 0x80)     { $rot_d = 1; }      // A = 時計回り
        elseif ($pressed & 0x40) { $rot_d = 3; }      // B = 反時計回り
        $frame = $frame + 1;
        if ($frame >= 30) { $frame = 0; $dy = 1; }    // 自然落下
        if ($b & 0x04)    { $dy = 1; }                // 下ボタン = ソフトドロップ

        $locked = 0;
        if ($dx | $dy | $rot_d) {
            $old_shape = $shape;
            $old_px = $px;
            $old_py = $py;
            $moved = 0;

            // --- 移動 3 フェーズ (0=回転, 1=水平, 2=落下) を共通の衝突判定で ---
            // 実行しないフェーズは $i を 16 にしてループをスキップ ($do * 16)。
            $ph = 0;
            while ($ph < 3) {
                $do = 0;
                $cshape = $shape;
                $cpx = $px;
                $cpy = $py;
                $crot = $rot;
                if ($ph === 0 && $rot_d) {
                    $crot = ($rot + $rot_d) & 3;
                    $cshape = nes_peek16((($piece * 4) + $crot) * 2);
                    $do = 1;
                }
                if ($ph === 1 && $dx) { $cpx = $px + $dx; $do = 1; }
                if ($ph === 2 && $dy) { $cpy = $py + 1; $do = 1; }

                $collide = 0;
                $i = 16 - ($do * 16);
                while ($i < 16) {
                    if (($cshape >> $i) & 1) {
                        $cx = $cpx + ($i & 3);
                        $cy = $cpy + ($i >> 2);
                        if ($cx < 4 || $cx > 13 || $cy < 5 || $cy > 25) {
                            $collide = 1;
                        } elseif ($grid[$cy - 5] & (1 << ($cx - 4))) {
                            $collide = 1;
                        }
                    }
                    $i = $i + 1;
                }
                if ($do) {
                    if ($collide === 0) {
                        $shape = $cshape;
                        $px = $cpx;
                        $py = $cpy;
                        $rot = $crot;
                        $moved = 1;
                    } elseif ($ph === 2) {
                        $locked = 1;      // 落下だけは collide = 固定
                    }
                }
                $ph = $ph + 1;
            }

            // --- 差分描画: 新位置を先に描き、重ならない旧セルだけ消す ---
            // ($moved = 0 のときは $i = 16 で両ループをスキップ)
            $i = 16 - ($moved * 16);
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    nes_put($px + ($i & 3), $py + ($i >> 2), $tile);
                }
                $i = $i + 1;
            }
            $i = 16 - ($moved * 16);
            while ($i < 16) {
                if (($old_shape >> $i) & 1) {
                    $cx = $old_px + ($i & 3);
                    $cy = $old_py + ($i >> 2);
                    // 新ピースのローカル座標 (+4 オフセットで負数を回避)
                    $lx = $cx + 4 - $px;
                    $ly = $cy + 4 - $py;
                    $keep = 0;
                    if ($lx >= 4 && $lx < 8) {
                        if ($ly >= 4 && $ly < 8) {
                            $keep = ($shape >> (($ly * 4) + $lx - 20)) & 1;
                        }
                    }
                    if ($keep === 0) {
                        nes_put($cx, $cy, " ");
                    }
                }
                $i = $i + 1;
            }

            // --- 固定 + ライン消去 ---
            if ($locked) {
                // grid bitmask + 描画タイルを ext RAM へ
                $i = 0;
                while ($i < 16) {
                    if (($shape >> $i) & 1) {
                        $cx = $px + ($i & 3);
                        $cy = $py + ($i >> 2);
                        $grid[$cy - 5] = $grid[$cy - 5] | (1 << ($cx - 4));
                        nes_poke_ext((($cy - 5) * 10) + $cx - 4, $tile);
                    }
                    $i = $i + 1;
                }

                // ライン消去: 下から走査し、揃っていない行だけ $w へ詰める。
                // $low = 消えた行のうち最下 (最初に見つかる full 行 = 最大 index)。
                $lines = 0;
                $low = 0;
                $w = 20;
                $rr = 20;
                while ($rr >= 0) {
                    if ($grid[$rr] === 1023) {
                        $lines = $lines + 1;
                        if ($lines === 1) { $low = $rr; }
                    } else {
                        $grid[$w] = $grid[$rr];
                        $c = 0;
                        while ($c < 10) {
                            $v = nes_peek_ext(($rr * 10) + $c);
                            nes_poke_ext(($w * 10) + $c, $v);
                            $c = $c + 1;
                        }
                        $w = $w - 1;
                    }
                    $rr = $rr - 1;
                }
                // 詰めた分だけ上を空行に
                while ($w >= 0) {
                    $grid[$w] = 0;
                    $c = 0;
                    while ($c < 10) {
                        nes_poke_ext(($w * 10) + $c, 0x20);
                        $c = $c + 1;
                    }
                    $w = $w - 1;
                }

                if ($lines > 0) {
                    // スコア: 1/2/3/4 lines = 100/400/900/1600 (同時消しボーナス)
                    $score = $score + ($lines * $lines * 100);
                    nes_putint(17, 7, $score);
                    // 変化したのは row 0..$low だけなのでそこだけ再描画。
                    // ext は描画タイルそのものを持つので if 分岐なしで put できる。
                    // 1 行ごとに vsync して NMI queue を drain させる。
                    $rr = 0;
                    while ($rr <= $low) {
                        $c = 0;
                        while ($c < 10) {
                            $v = nes_peek_ext(($rr * 10) + $c);
                            nes_put($c + 4, $rr + 5, $v);
                            $c = $c + 1;
                        }
                        nes_vsync();
                        $rr = $rr + 1;
                    }
                }

                $spawn = 1;   // 次ループ先頭でスポーン + GAME OVER 判定
            }
        }
    }  // game over → タイトル/GAME OVER 画面へ
}  // 外側セッションループ
