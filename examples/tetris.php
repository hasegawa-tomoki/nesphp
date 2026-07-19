<?php
// Tetris: 7 種ピース + 4 回転 + ランダム + 入力 + 落下 + lock + line clear + score
//
// 色付け: BPS Famicom 版に倣い palette 1 を 1 種類だけ使う方式。
//   palette 1 = (黒 bg, 白, 赤, 緑)、CHR タイル 0x05-0x0B が 7 ピースに対応。
//   play field 全 cell を attribute = 1 にすることで 2×2 attribute 境界での
//   color bleed を回避。
//
// レンガ壁: tile 0x0C を palette 0 (default colors のグレー系) で描画、
//   play field を取り囲む。frame は row 3 / row 26 に出して play field の
//   attribute block と被らないようにする。
//
// shape table (16-bit × 28 entries) は user RAM offset 0-55 に格納。
// 各 cell の lock 済タイル番号は USER_RAM_EXT (bank 3、8KB) の offset 0-209 に
// 保存 (21 行 × 10 列 = 210 cell)。user RAM (256B) には収まらないので bank 3 を使う。

nes_puts(4, 1, "TETRIS");

// レンガ壁: play field (col 4-13, row 5-24) の外側を tile 0x0C で囲む。
//   * 上下: row 3, row 26 × col 3-14 (12 cells 各)
//   * 左右: col 3, col 14 × row 4-25 (22 cells 各)
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
nes_puts(17, 7, "    0");

// ピース色用 palette 1: 白/赤/緑 (universal bg = 黒)
nes_palette(1, 0x30, 0x16, 0x1A);

// play field 全 cell (col 4-13, row 5-24 = attr block (2-6, 2-12)) を pal 1 に
$ay = 2;
while ($ay <= 12) {
    $ax = 2;
    while ($ax <= 6) {
        nes_attr($ax, $ay, 1);
        $ax = $ax + 1;
    }
    $ay = $ay + 1;
}

// shape 表: 7 ピース × 4 回転 = 28 entry × 2 byte = 56 byte
//   I (横) 0x00F0 / I (縦) 0x2222 / I (横) 0x00F0 / I (縦) 0x2222
//   O      0x0660 (4 回転とも同じ)
//   T (下) 0x0720 / T (左) 0x0262 / T (上) 0x0270 / T (右) 0x0232
//   S      0x0360 / 0x0462 / 0x0360 / 0x0462
//   Z      0x0630 / 0x0264 / 0x0630 / 0x0264
//   L      0x0470 / 0x0322 / 0x0710 / 0x0226
//   J      0x0170 / 0x0223 / 0x0740 / 0x0622
nes_pokestr(0, "\xF0\x00\x22\x22\xF0\x00\x22\x22\x60\x06\x60\x06\x60\x06\x60\x06\x20\x07\x62\x02\x70\x02\x32\x02\x60\x03\x62\x04\x60\x03\x62\x04\x30\x06\x64\x02\x30\x06\x64\x02\x70\x04\x22\x03\x10\x07\x26\x02\x70\x01\x23\x02\x40\x07\x22\x06");

$grid = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
$first_time = 1;
$score = 0;

// セッションループ: 起動時 + GAME OVER 後の再スタートで何度でも回す
while (true) {
    // タイトル / GAME OVER 画面
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

    // メッセージ消去
    if ($first_time === 0) {
        nes_puts(5, 13, "         ");
    }
    nes_puts(4, 17, "          ");

    // play field cell + tile grid を全 cell クリア
    $idx = 0;
    while ($idx < 210) {
        $r = $idx / 10;
        $c = $idx - $r * 10;
        nes_put($c + 4, $r + 5, " ");
        nes_poke_ext($idx, 0);
        $idx = $idx + 1;
    }

    // $grid bitmask 全クリア
    $i = 0;
    while ($i < 21) {
        $grid[$i] = 0;
        $i = $i + 1;
    }

    // score リセット
    $score = 0;
    nes_putint(17, 7, $score);
    $first_time = 0;

    // 初回ピース
    $piece = (nes_rand() & 0x7FFF) % 7;
    $tile  = $piece + 5;
    $rot = 0;
    $ofs = ($piece * 4 + $rot) * 2;
    $shape = nes_peek16($ofs);
    $px = 6;
    $py = 5;

    $i = 0;
    while ($i < 16) {
        if (($shape >> $i) & 1) {
            nes_put($px + ($i & 3), $py + ($i >> 2), $tile);
        }
        $i = $i + 1;
    }

    $frame = 0;
    $prev_btn = 0;
    $game_over = 0;

while ($game_over === 0) {
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
    elseif ($pressed & 0x40) { $rot_d = 3; }      // B = 反時計回り (= -1 mod 4)
    $frame = $frame + 1;
    if ($frame >= 30) { $frame = 0; $dy = 1; }
    if ($b & 0x04)    { $dy = 1; }

    if ($dx | $dy | $rot_d) {
        // 移動前の状態を保存。衝突判定は $grid ビットマスクだけを見るので
        // 画面はまだ触らない (消去→判定→再描画だと判定の数フレーム間
        // ピースが消えてちらつく)。描画は判定が全部終わってから差分だけ行う。
        $old_shape = $shape;
        $old_px = $px;
        $old_py = $py;
        $moved = 0;

        // Phase 0: 回転 (現在位置で形だけ変える、collide なら無視)
        if ($rot_d) {
            $new_rot = ($rot + $rot_d) & 3;
            $new_ofs = ($piece * 4 + $new_rot) * 2;
            $new_shape = nes_peek16($new_ofs);
            $collide = 0;
            $i = 0;
            while ($i < 16) {
                if (($new_shape >> $i) & 1) {
                    $cx = $px + ($i & 3);
                    $cy = $py + ($i >> 2);
                    if ($cx < 4 || $cx > 13 || $cy > 25 || $cy < 5) {
                        $collide = 1;
                    } elseif ($grid[$cy - 5] & (1 << ($cx - 4))) {
                        $collide = 1;
                    }
                }
                $i = $i + 1;
            }
            if ($collide === 0) {
                $rot = $new_rot;
                $shape = $new_shape;
                $moved = 1;
            }
        }

        // Phase 1: 水平 (壁/壁内ブロックに collide なら無視、lock しない)
        if ($dx) {
            $new_px = $px + $dx;
            $collide = 0;
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cx = $new_px + ($i & 3);
                    $cy = $py + ($i >> 2);
                    if ($cx < 4 || $cx > 13 || $cy > 25 || $cy < 5) {
                        $collide = 1;
                    } elseif ($grid[$cy - 5] & (1 << ($cx - 4))) {
                        $collide = 1;
                    }
                }
                $i = $i + 1;
            }
            if ($collide === 0) {
                $px = $new_px;
                $moved = 1;
            }
        }

        // Phase 2: 落下 (collide なら lock)
        $locked = 0;
        if ($dy > 0) {
            $new_py = $py + 1;
            $collide = 0;
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cx = $px + ($i & 3);
                    $cy = $new_py + ($i >> 2);
                    if ($cx < 4 || $cx > 13 || $cy > 25 || $cy < 5) {
                        $collide = 1;
                    } elseif ($grid[$cy - 5] & (1 << ($cx - 4))) {
                        $collide = 1;
                    }
                }
                $i = $i + 1;
            }
            if ($collide === 0) {
                $py = $new_py;
                $moved = 1;
            } else {
                $locked = 1;
            }
        }

        // 差分描画: 新位置を先に描いてから、新位置と重ならない旧セルだけ消す。
        // どの瞬間もピースが画面から完全に消えないので、erase→draw が別々の
        // VBlank に流れてもちらつかない。重なりセルは同一タイルなので触らない。
        // 注: if ($moved) で囲むとネストが 8 段になり compiler の backpatch
        // stack (7 段) を超えるので、$i = 16 でループをスキップする方式。
        $i = 0;
        if ($moved === 0) { $i = 16; }
        while ($i < 16) {
            if (($shape >> $i) & 1) {
                nes_put($px + ($i & 3), $py + ($i >> 2), $tile);
            }
            $i = $i + 1;
        }
        $i = 0;
        if ($moved === 0) { $i = 16; }
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
                        $j = $ly * 4 + $lx - 20;
                        $keep = ($shape >> $j) & 1;
                    }
                }
                if ($keep === 0) {
                    nes_put($cx, $cy, " ");
                }
            }
            $i = $i + 1;
        }

        if ($locked) {
            // grid bitmask + 各 cell タイル番号を user RAM へ
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cy = $py + ($i >> 2);
                    $cx = $px + ($i & 3);
                    $grid[$cy - 5] = $grid[$cy - 5] | (1 << ($cx - 4));
                    nes_poke_ext(($cy - 5) * 10 + ($cx - 4), $tile);
                }
                $i = $i + 1;
            }

            // ライン消去: bitmask を詰めつつ user RAM のタイル row もコピー
            $line_clears = 0;
            $write_row = 20;
            $read_row = 20;
            while ($read_row >= 0) {
                $row_val = $grid[$read_row];
                if ($row_val === 1023) {
                    $line_clears = $line_clears + 1;
                } else {
                    $grid[$write_row] = $row_val;
                    $col = 0;
                    while ($col < 10) {
                        $v = nes_peek_ext($read_row * 10 + $col);
                        nes_poke_ext($write_row * 10 + $col, $v);
                        $col = $col + 1;
                    }
                    $write_row = $write_row - 1;
                }
                $read_row = $read_row - 1;
            }
            while ($write_row >= 0) {
                $grid[$write_row] = 0;
                $col = 0;
                while ($col < 10) {
                    nes_poke_ext($write_row * 10 + $col, 0);
                    $col = $col + 1;
                }
                $write_row = $write_row - 1;
            }

            if ($line_clears > 0) {
                $score = $score + $line_clears * 100;
                nes_putint(17, 7, $score);
                // 全 210 cell 再描画。NMI queue が VBlank 予算を超えないよう
                // 21 行ごとに nes_vsync() で drain させる。21 cell = ~84 byte の
                // queue 流量で 1 frame の budget (NMI flush ~100B) に収まる。
                $idx = 0;
                while ($idx < 210) {
                    $r = $idx / 10;
                    $c = $idx - $r * 10;
                    $sx = $c + 4;
                    $sy = $r + 5;
                    $t = nes_peek_ext($idx);
                    if ($t !== 0) {
                        nes_put($sx, $sy, $t);
                    } else {
                        nes_put($sx, $sy, " ");
                    }
                    $idx = $idx + 1;
                    if ($c === 9) { nes_vsync(); }   // 1 行分流したら sync
                }
            }

            // 次ピース
            $piece = (nes_rand() & 0x7FFF) % 7;
            $tile  = $piece + 5;
            $rot = 0;
            $ofs = ($piece * 4) * 2;
            $shape = nes_peek16($ofs);
            $px = 6;
            $py = 5;

            // spawn 行が既占有 → GAME OVER フラグを立てて inner ループ抜け
            if ($grid[0] !== 0) {
                $game_over = 1;
            } else {
                // 新ピース描画
                $i = 0;
                while ($i < 16) {
                    if (($shape >> $i) & 1) {
                        nes_put($px + ($i & 3), $py + ($i >> 2), $tile);
                    }
                    $i = $i + 1;
                }
            }
        }
    }
}  // game over → 戻ってタイトル/GAME OVER 画面 → PUSH START 待ち
}  // 外側セッションループ
