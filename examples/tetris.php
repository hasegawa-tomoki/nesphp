<?php
// Tetris: 7 種ピース + 4 回転 + ランダム + 入力 + 落下 + lock + line clear + score
//
// 色付け方式: BPS 版 Famicom テトリスに倣い、palette 1 を 1 種類だけ使う
// (色 1=白 / 色 2=赤 / 色 3=緑、bg=黒)。各ピースは CHR タイル 0x05-0x0B
// で識別 (緑/赤/白の縁取り + コアの組合せ)。play field 全体の attribute を 1 に
// 設定するので 2×2 attribute 境界でのカラーブリードが発生しない。
//
// shape table (16-bit × 28 entries) は user RAM offset 0-55 に格納。
// 各 cell の lock 済タイル番号は user RAM offset 64-263 (200 byte) に保存。
// line clear 時の全面再描画はこの per-cell タイル情報を使う。

nes_puts(4, 1, "TETRIS");
nes_puts(3, 4,  "+----------+");
nes_puts(3, 25, "+----------+");
for ($y = 5; $y <= 24; $y++) {
    nes_put(3, $y, "|");
    nes_put(14, $y, "|");
}
nes_puts(17, 5, "SCORE");
nes_puts(17, 7, "    0");

// ピース色用 palette: 黒 (universal bg) / 白 / 赤 / 緑
nes_palette(1, 0x30, 0x16, 0x1A);

// play field 全 cell (col 4-13, row 5-24 = attr (2-6, 2-12)) を palette 1 に。
// ループで 5×11 = 55 個の attribute byte を設定する。
$ay = 2;
while ($ay <= 12) {
    $ax = 2;
    while ($ax <= 6) {
        nes_attr($ax, $ay, 1);
        $ax = $ax + 1;
    }
    $ay = $ay + 1;
}

// 4x4 bbox エンコード: bit i = (i&3, i>>2) のセル。bit 0 = 左上、bit 15 = 右下。
// 7 ピース × 4 回転 = 28 entry × 2 byte = 56 byte。
//   I (横) 0x00F0 / I (縦) 0x2222 / I (横) 0x00F0 / I (縦) 0x2222
//   O      0x0660 (4 回転とも同じ)
//   T (下) 0x0720 / T (左) 0x0262 / T (上) 0x0270 / T (右) 0x0232
//   S      0x0360 / 0x0462 / 0x0360 / 0x0462
//   Z      0x0630 / 0x0264 / 0x0630 / 0x0264
//   L      0x0470 / 0x0322 / 0x0710 / 0x0226
//   J      0x0170 / 0x0223 / 0x0740 / 0x0622
nes_pokestr(0, "\xF0\x00\x22\x22\xF0\x00\x22\x22\x60\x06\x60\x06\x60\x06\x60\x06\x20\x07\x62\x02\x70\x02\x32\x02\x60\x03\x62\x04\x60\x03\x62\x04\x30\x06\x64\x02\x30\x06\x64\x02\x70\x04\x22\x03\x10\x07\x26\x02\x70\x01\x23\x02\x40\x07\x22\x06");

$grid = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

nes_srand(12345);
$piece = (nes_rand() & 0x7FFF) % 7;
$tile  = $piece + 5;     // タイル番号: I=0x05, O=0x06, T=0x07, S=0x08, Z=0x09, L=0x0A, J=0x0B
$rot = 0;
$ofs = ($piece * 4 + $rot) * 2;
$shape = nes_peek16($ofs);
$px = 6;
$py = 5;
$score = 0;

// 初期ピース描画は省略 — $frame=29 で開始することで初手で auto-fall を発火させ、
// move ハンドラの "新位置描画" 経路で 1 段下に落としつつ描画する
$frame = 29;
$prev_btn = 0;

while (true) {
    nes_vsync();
    $b = nes_btn();
    $pressed = $b & (0xFF - $prev_btn);
    $prev_btn = $b;

    $dx = 0;
    $dy = 0;
    $rot_d = 0;
    if ($pressed & 0x02)     { $dx = 0 - 1; }
    elseif ($pressed & 0x01) { $dx = 1; }
    if ($pressed & 0x80)     { $rot_d = 1; }      // A ボタン = 回転
    $frame = $frame + 1;
    if ($frame >= 30) { $frame = 0; $dy = 1; }
    if ($b & 0x04)    { $dy = 1; }

    if ($dx | $dy | $rot_d) {
        $new_px = $px + $dx;
        $new_py = $py + $dy;
        $new_rot = ($rot + $rot_d) & 3;
        $new_ofs = ($piece * 4 + $new_rot) * 2;
        $new_shape = nes_peek16($new_ofs);

        $collide = 0;
        $i = 0;
        while ($i < 16) {
            if (($new_shape >> $i) & 1) {
                $cx = $new_px + ($i & 3);
                $cy = $new_py + ($i >> 2);
                if ($cx < 4 || $cx > 13 || $cy > 24 || $cy < 5) {
                    $collide = 1;
                } elseif ($grid[$cy - 5] & (1 << ($cx - 4))) {
                    $collide = 1;
                }
            }
            $i = $i + 1;
        }

        if ($collide === 0) {
            // 旧位置消去
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    nes_put($px + ($i & 3), $py + ($i >> 2), " ");
                }
                $i = $i + 1;
            }
            $px = $new_px;
            $py = $new_py;
            $rot = $new_rot;
            $shape = $new_shape;
            // 新位置描画 (ピース色付タイル)
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    nes_put($px + ($i & 3), $py + ($i >> 2), $tile);
                }
                $i = $i + 1;
            }
        } elseif ($dy > 0 && $rot_d === 0) {
            // 落下方向で衝突 → lock。$grid bitmask + 各 cell タイル番号を user RAM へ。
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cy = $py + ($i >> 2);
                    $cx = $px + ($i & 3);
                    $grid[$cy - 5] = $grid[$cy - 5] | (1 << ($cx - 4));
                    nes_poke(64 + ($cy - 5) * 10 + ($cx - 4), $tile);
                }
                $i = $i + 1;
            }

            // ライン消去: bitmask を詰めつつ user RAM のタイル row もコピー
            $line_clears = 0;
            $write_row = 19;
            $read_row = 19;
            while ($read_row >= 0) {
                if ($grid[$read_row] === 1023) {
                    $line_clears = $line_clears + 1;
                } else {
                    $grid[$write_row] = $grid[$read_row];
                    // タイル row をコピー (read_row → write_row、10 byte)
                    $col = 0;
                    while ($col < 10) {
                        nes_poke(64 + $write_row * 10 + $col, nes_peek(64 + $read_row * 10 + $col));
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
                    nes_poke(64 + $write_row * 10 + $col, 0);
                    $col = $col + 1;
                }
                $write_row = $write_row - 1;
            }

            if ($line_clears > 0) {
                $score = $score + $line_clears * 100;
                nes_putint(17, 7, $score);
                // 全面再描画: 各 cell の lock 済タイル番号を user RAM から読出して描画。
                $idx = 0;
                while ($idx < 200) {
                    $r = $idx / 10;
                    $c = $idx - $r * 10;
                    $sx = $c + 4;
                    $sy = $r + 5;
                    nes_put($sx, $sy, " ");
                    $t = nes_peek(64 + $idx);
                    if ($t !== 0) {
                        nes_put($sx, $sy, $t);
                    }
                    $idx = $idx + 1;
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

            // spawn 行が既占有 → GAME OVER
            if ($grid[0] !== 0) {
                nes_puts(5, 14, "GAME OVER");
                nes_puts(5, 16, "SCORE:");
                nes_putint(13, 16, $score);
                while (true) { nes_vsync(); }
            }

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
