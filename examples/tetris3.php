<?php
// Tetris v3: 「テトリスを作る」からのゼロベース実装
// (tetris.php / tetris2.php とは独立。CHR キャラクタのみ共用)
//
// 仕様 (標準テトリス準拠):
//   * フィールド 10×20 + 画面外の隠し 2 行 (ピースは枠の上から降ってくる)
//   * 7 種ピース、NES 準拠の回転 (3×3 box の中心ピボット、I は 4×4、O は不変。
//     回転してもピースの見かけ位置がズレない)
//   * NEXT プレビュー / LINES カウント / LEVEL (10 ライン毎に落下加速)
//   * スコア: 40/100/300/1200 × (LEVEL+1)
//   * DAS: 左右押しっぱなしで遅延後リピート移動。下 = ソフトドロップ
//   * A = 時計回り / B = 反時計回り (壁蹴りなし = NES 準拠)
//   * GAME OVER: スポーン位置が埋まっている (block out) または
//     隠し行にロックされた (lock out)
//
// 座標系:
//   * field (fx, fy): fx 0-9, fy 0-21。fy 0-1 が隠し行
//   * screen: x = fx + 12, y = fy + 4 (可視は fy >= 2 → 画面 row 6-25)
//   * $grid[fy] = 10bit 占有 bitmask (bit fx、1023 = full)
//   * ext RAM offset fy*10+fx = そのセルの描画タイル (空 = 0x20)
//
// shape table: 16bit bitmap × 7 ピース × 4 回転。bit = row*4 + col (row0 が上)。
// 3×3 ピースは box (1,1) を、I は box 中心をピボットに時計回りで定義。
//   I: 0x0F00 0x4444 (2 状態)      O: 0x0660 (不変)
//   T: 0x0270 0x0232 0x0072 0x0262 (下/左/上/右)
//   S: 0x0360 0x0231 (2 状態)      Z: 0x0630 0x0132 (2 状態)
//   L: 0x0170 0x0223 0x0074 0x0622
//   J: 0x0470 0x0322 0x0071 0x0226
//
// compiler 制約: ネスト最大 7 段 / `/` 不使用 (host PHP 検証互換) /
// 乗算は括弧で結合明示 / ネスト関数呼び出し不可

nes_puts(13, 2, "TETRIS");

// レンガ枠: 左右の壁 + 底のみ (天井なし)。ピースは開いた上から降ってくる。
// 壁は row 5 まで伸ばして開口部を井戸らしく見せる (row 5 は隠し行なので
// ピース描画と干渉しない)。
$c = 11;
while ($c <= 22) {
    nes_put($c, 26, 0x0C);
    $c = $c + 1;
}
$r = 5;
while ($r <= 25) {
    nes_put(11, $r, 0x0C);
    nes_put(22, $r, 0x0C);
    $r = $r + 1;
}

// サイドパネル
nes_puts(24, 6, "SCORE");
nes_puts(24, 10, "NEXT");
nes_puts(24, 16, "LINES");
nes_puts(24, 20, "LEVEL");

// ピース色 palette 1 (白/赤/緑)。field とプレビュー欄の attribute を palette 1 に。
// field は col 12-21 / row 6-25 = attr block (6-10, 3-12) にぴったり整列し、
// 枠 (col 11/22, row 5/26) は隣の block に落ちるので色が滲まない。
nes_palette(1, 0x30, 0x16, 0x1A);
$r = 3;
while ($r <= 12) {
    $c = 6;
    while ($c <= 10) {
        nes_attr($c, $r, 1);
        $c = $c + 1;
    }
    $r = $r + 1;
}
nes_attr(12, 6, 1);   // NEXT プレビュー欄 (col 24-27, row 12-13)
nes_attr(13, 6, 1);

// shape table → user RAM offset 0-55 (little-endian 16bit × 28)
nes_pokestr(0, "\x00\x0F\x44\x44\x00\x0F\x44\x44\x60\x06\x60\x06\x60\x06\x60\x06\x70\x02\x32\x02\x72\x00\x62\x02\x60\x03\x31\x02\x60\x03\x31\x02\x30\x06\x32\x01\x30\x06\x32\x01\x70\x01\x23\x02\x74\x00\x22\x06\x70\x04\x22\x03\x71\x00\x26\x02");

// grid: 22 行 (0-1 = 隠し行)
$grid = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
$first = 1;
$piece = 0;

// セッションループ: 起動時 + GAME OVER 後の再スタート
while (true) {
    if ($first === 0) {
        nes_puts(12, 14, "GAME OVER");
    }
    nes_puts(12, 16, "PUSH START");

    // START 待ちで乱数 seed を稼ぐ
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
    $first = 0;

    // field クリア (隠し行含む)。GAME OVER / PUSH START の文字も field 内なので
    // このループが消してくれる。ext RAM は描画タイル (空 = 0x20)。
    $r = 0;
    while ($r < 22) {
        $grid[$r] = 0;
        $c = 0;
        while ($c < 10) {
            nes_poke_ext(($r * 10) + $c, 0x20);
            if ($r >= 2) { nes_put($c + 12, $r + 4, " "); }
            $c = $c + 1;
        }
        $r = $r + 1;
    }

    $score = 0;
    $tlines = 0;
    $level = 0;
    $lvlcnt = 0;
    $gdel = 48;               // 落下間隔 (ループ周回数)。level +1 毎に -5、下限 8
    nes_putint(24, 7, $score);
    nes_putint(24, 17, $tlines);
    nes_putint(24, 21, $level);

    $next = (nes_rand() & 0x7FFF) % 7;
    $game_over = 0;
    $spawn = 1;
    $prev_btn = 0;
    $das = 0;
    $gtimer = 0;
    $tile = 0;
    $rot = 0;
    $shape = 0;
    $px = 3;
    $py = 0;

    while ($game_over === 0) {
        // --- スポーン ---
        if ($spawn) {
            $spawn = 0;
            $piece = $next;
            $tile = $piece + 5;
            $rot = 0;
            $shape = nes_peek16($piece * 8);
            $px = 3;              // 3 幅ピースが field col 3-5 (中央) に出る
            $py = 0;              // box row0 = 隠し行 0
            $gtimer = 0;

            // 次ピース抽選 (NES 式: 8 面ダイス → 7 か前回と同じなら振り直し)
            $next = (nes_rand() >> 3) & 7;
            if ($next === 7 || $next === $piece) {
                $next = (nes_rand() & 0x7FFF) % 7;
            }

            // NEXT プレビュー描画 (rot0 は必ず box row 1-2 に収まる)
            $v = nes_peek16($next * 8);
            $i = 4;
            while ($i < 12) {
                $t = 0x20;
                if (($v >> $i) & 1) { $t = $next + 5; }
                nes_put(24 + ($i & 3), 11 + ($i >> 2), $t);
                $i = $i + 1;
            }

            // block out: スポーン位置 (px=3 固定 → grid bit 3-6) が既に埋まって
            // いたら GAME OVER。grid 行を 3bit 右シフトすると shape の行 nibble と
            // 桁が揃う。
            $i = 0;
            while ($i < 4) {
                if (($shape >> ($i * 4)) & 0xF & ($grid[$i] >> 3)) {
                    $game_over = 1;
                }
                $i = $i + 1;
            }

            // スポーン描画 (可視行のみ。隠し行のセルは枠の上なので描かない)
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cy = $py + ($i >> 2);
                    if ($cy >= 2) {
                        nes_put($px + ($i & 3) + 12, $cy + 4, $tile);
                    }
                }
                $i = $i + 1;
            }
        }

        nes_vsync();
        $b = nes_btn();
        $pressed = $b & (0xFF - $prev_btn);
        $prev_btn = $b;

        // --- 入力 → dx / dy / rot_d ---
        $dx = 0;
        $dy = 0;
        $rot_d = 0;
        if ($pressed & 0x02)     { $dx = 0 - 1; $das = 0; }
        elseif ($pressed & 0x01) { $dx = 1; $das = 0; }
        elseif ($b & 0x03) {
            // DAS: 押しっぱなしは 10 カウント遅延の後 2 カウント毎にリピート
            $das = $das + 1;
            if ($das >= 10) {
                $das = 8;
                if ($b & 0x02) { $dx = 0 - 1; }
                else { $dx = 1; }
            }
        }
        if ($pressed & 0x80)     { $rot_d = 1; }      // A = 時計回り
        elseif ($pressed & 0x40) { $rot_d = 3; }      // B = 反時計回り
        $gtimer = $gtimer + 1;
        if ($gtimer >= $gdel) { $gtimer = 0; $dy = 1; }
        if ($b & 0x04) { $dy = 1; }                   // ソフトドロップ

        $locked = 0;
        if ($dx | $dy | $rot_d) {
            $old_shape = $shape;
            $old_px = $px;
            $old_py = $py;
            $moved = 0;

            // --- 移動 3 フェーズ (0=回転, 1=水平, 2=落下) 共通衝突判定 ---
            // 実行しないフェーズは $i = 16 でループをスキップ。
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
                        if ($cx < 0 || $cx > 9 || $cy > 21) {
                            $collide = 1;
                        } elseif ($grid[$cy] & (1 << $cx)) {
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
                        $locked = 1;      // 落下衝突のみ固定
                    }
                }
                $ph = $ph + 1;
            }

            // --- 差分描画: 新位置を先に描き、重ならない旧セルだけ消す ---
            // ピースがどの瞬間も画面から消えないのでちらつかない。
            // ($moved = 0 なら $i = 16 で両ループをスキップ)
            $i = 16 - ($moved * 16);
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cx = $px + ($i & 3);
                    $cy = $py + ($i >> 2);
                    if ($cy >= 2) { nes_put($cx + 12, $cy + 4, $tile); }
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
                    if ($keep === 0 && $cy >= 2) {
                        nes_put($cx + 12, $cy + 4, " ");
                    }
                }
                $i = $i + 1;
            }

            // --- 固定 + ライン消去 ---
            if ($locked) {
                $i = 0;
                while ($i < 16) {
                    if (($shape >> $i) & 1) {
                        $cx = $px + ($i & 3);
                        $cy = $py + ($i >> 2);
                        $grid[$cy] = $grid[$cy] | (1 << $cx);
                        nes_poke_ext(($cy * 10) + $cx, $tile);
                        if ($cy < 2) { $game_over = 1; }   // lock out
                    }
                    $i = $i + 1;
                }
                // ライン消去: 下から走査し、揃っていない行だけ $w へ詰める。
                // $low = 消えた行のうち最下 (最初に見つかる full 行)。
                $lines = 0;
                $low = 0;
                $w = 21;
                $rr = 21;
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
                    // スコア: 40/100/300/1200 × (LEVEL+1)
                    $pts = 40;
                    if ($lines === 2) { $pts = 100; }
                    if ($lines === 3) { $pts = 300; }
                    if ($lines === 4) { $pts = 1200; }
                    $score = $score + ($pts * ($level + 1));
                    nes_putint(24, 7, $score);
                    $tlines = $tlines + $lines;
                    nes_putint(24, 17, $tlines);
                    // 10 ラインで LEVEL +1、落下加速
                    $lvlcnt = $lvlcnt + $lines;
                    if ($lvlcnt >= 10) {
                        $lvlcnt = $lvlcnt - 10;
                        $level = $level + 1;
                        $gdel = $gdel - 5;
                        if ($gdel < 8) { $gdel = 8; }
                        nes_putint(24, 21, $level);
                    }
                    // 変化した可視行 (2..$low) のみ再描画。1 行毎に vsync で
                    // NMI queue を drain。
                    $rr = 2;
                    while ($rr <= $low) {
                        $c = 0;
                        while ($c < 10) {
                            $v = nes_peek_ext(($rr * 10) + $c);
                            nes_put($c + 12, $rr + 4, $v);
                            $c = $c + 1;
                        }
                        nes_vsync();
                        $rr = $rr + 1;
                    }
                }

                $spawn = 1;   // 次ループ先頭でスポーン + block out 判定
            }
        }
    }  // game over → タイトル/GAME OVER 画面へ
}  // 外側セッションループ
