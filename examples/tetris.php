<?php
// Tetris Phase 5b: 7 種ピース + 4 回転 + ランダム + 入力 + 落下 + lock + line clear + score
// shape table は user RAM ($0700-) に格納し peek で参照 (zval オーバーヘッド回避)

nes_puts(4, 1, "TETRIS");
nes_puts(3, 4,  "+----------+");
nes_puts(3, 25, "+----------+");
for ($y = 5; $y <= 24; $y++) {
    nes_put(3, $y, "|");
    nes_put(14, $y, "|");
}
nes_puts(17, 5, "SCORE");
nes_puts(17, 7, "    0");

// 4x4 bbox エンコード: bit i = (i&3, i>>2) のセル。bit 0 = 左上、bit 15 = 右下。
// 16-bit 値、user RAM に lo/hi の順で 2 byte ずつ詰める。
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
$rot = 0;
// shape を peek で 16-bit 復元 ($piece*4 + $rot) * 2
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

        // 4 行 (4×4 bbox) × 4 列の collision check
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
            // 新位置描画
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    nes_put($px + ($i & 3), $py + ($i >> 2), "\x05");
                }
                $i = $i + 1;
            }
        } elseif ($dy > 0 && $rot_d === 0) {
            // 落下方向で衝突 → lock。$shape の各セルを grid に焼き込む。
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    $cy = $py + ($i >> 2);
                    $cx = $px + ($i & 3);
                    $grid[$cy - 5] = $grid[$cy - 5] | (1 << ($cx - 4));
                }
                $i = $i + 1;
            }

            // ライン消去
            $line_clears = 0;
            $write_row = 19;
            $read_row = 19;
            while ($read_row >= 0) {
                if ($grid[$read_row] === 1023) {
                    $line_clears = $line_clears + 1;
                } else {
                    $grid[$write_row] = $grid[$read_row];
                    $write_row = $write_row - 1;
                }
                $read_row = $read_row - 1;
            }
            while ($write_row >= 0) {
                $grid[$write_row] = 0;
                $write_row = $write_row - 1;
            }

            if ($line_clears > 0) {
                $score = $score + $line_clears * 100;
                nes_putint(17, 7, $score);
                // 全面再描画 (Phase 5c): lineclear_test.php と同じ単一ループ方式。
                // " " で先にクリア → 必要なセルだけ "\x05" で上書き (else 不要)。
                $idx = 0;
                while ($idx < 200) {
                    $r = $idx / 10;
                    $c = $idx - $r * 10;
                    $sx = $c + 4;
                    $sy = $r + 5;
                    nes_put($sx, $sy, " ");
                    if (($grid[$r] & (1 << $c)) !== 0) {
                        nes_put($sx, $sy, "\x05");
                    }
                    $idx = $idx + 1;
                }
            }

            // 次ピース
            $piece = (nes_rand() & 0x7FFF) % 7;
            $rot = 0;
            $ofs = ($piece * 4) * 2;
            $shape = nes_peek16($ofs);
            $px = 6;
            $py = 5;

            // 簡易 game over: spawn 行が既占有 → メッセージ表示 + 静止
            if ($grid[0] !== 0) {
                nes_puts(5, 14, "GAME OVER");
                while (true) { nes_vsync(); }
            }

            // 新ピース描画
            $i = 0;
            while ($i < 16) {
                if (($shape >> $i) & 1) {
                    nes_put($px + ($i & 3), $py + ($i >> 2), "\x05");
                }
                $i = $i + 1;
            }
        }
    }
}
