<?php
// 初期状態で row 19 (field) = 全列フル → 1 ピース落とすだけで line clear 発火するはず

nes_puts(4, 1, "LINE CLEAR TEST");
nes_puts(3, 4,  "+----------+");
nes_puts(3, 25, "+----------+");
for ($y = 5; $y <= 24; $y++) {
    nes_put(3, $y, "|");
    nes_put(14, $y, "|");
}
nes_puts(17, 5, "SCORE");
nes_puts(17, 7, "    0");

$grid = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1023];
nes_puts(4, 24, "##########");

$px = 7;
$py = 5;
$score = 0;
nes_puts($px, $py, "\x05\x05\x05\x05");

$frame = 0;
$prev_btn = 0;

while (true) {
    nes_vsync();
    $b = nes_btn();
    $pressed = $b & (0xFF - $prev_btn);
    $prev_btn = $b;

    $dx = 0;
    $dy = 0;
    if ($pressed & 0x02)     { $dx = 0 - 1; }
    elseif ($pressed & 0x01) { $dx = 1; }
    $frame = $frame + 1;
    if ($frame >= 30) { $frame = 0; $dy = 1; }
    if ($b & 0x04)    { $dy = 1; }

    if ($dx !== 0 || $dy !== 0) {
        $new_px = $px + $dx;
        $new_py = $py + $dy;

        $collide = 0;
        if ($new_px < 4 || $new_px + 3 > 13 || $new_py > 24) {
            $collide = 1;
        } else {
            $piece_mask = 15 << ($new_px - 4);
            if (($grid[$new_py - 5] & $piece_mask) !== 0) {
                $collide = 1;
            }
        }

        if ($collide === 0) {
            nes_puts($px, $py, "    ");
            $px = $new_px;
            $py = $new_py;
            nes_puts($px, $py, "\x05\x05\x05\x05");
        } elseif ($dy > 0) {
            $piece_mask = 15 << ($px - 4);
            $grid[$py - 5] = $grid[$py - 5] | $piece_mask;

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
                nes_putint(17, 7, $score);
            }

            $px = 7;
            $py = 5;
            $spawn_mask = 15 << 3;
            if (($grid[0] & $spawn_mask) !== 0) {
                nes_puts(5, 14, "GAME OVER");
                while (true) { nes_vsync(); }
            }
            nes_puts($px, $py, "\x05\x05\x05\x05");
        }
    }
}
