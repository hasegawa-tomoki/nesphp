<?php
// Tetris Phase 3 (DEBUG): py / frame / locked count を HUD に表示

nes_puts(4, 1, "TETRIS");
nes_puts(3, 4,  "+----------+");
nes_puts(3, 25, "+----------+");
for ($y = 5; $y <= 24; $y++) {
    nes_put(3, $y, "|");
    nes_put(14, $y, "|");
}
nes_puts(17, 5, "PY");
nes_puts(17, 7, "FR");
nes_puts(17, 9, "LK");
nes_puts(17, 11, "G0");
nes_puts(17, 13, "G1");
nes_puts(17, 15, "G19");
nes_puts(17, 17, "LP");
nes_puts(17, 19, "G0F");

$grid = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

$px = 7;
$py = 5;
nes_puts($px, $py, "\x05\x05\x05\x05");

$frame = 0;
$prev_btn = 0;
$lock_count = 0;

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
            $last_lock_py = $py;
            $grid[$py - 5] = $grid[$py - 5] | $piece_mask;
            $lock_count = $lock_count + 1;
            $px = 7;
            $py = 5;
            $spawn_mask = 15 << 3;
            if (($grid[0] & $spawn_mask) !== 0) {
                nes_puts(5, 14, "GAME OVER");
                nes_putint(20, 17, $last_lock_py);   // 最後の lock_py
                nes_putint(20, 19, $grid[0]);         // 最終 grid[0]
                while (true) { nes_vsync(); }
            }
            nes_puts($px, $py, "\x05\x05\x05\x05");
        }
    }

    nes_putint(20, 5, $py);
    nes_putint(20, 7, $frame);
    nes_putint(20, 9, $lock_count);
    nes_putint(20, 11, $grid[0]);
    nes_putint(20, 13, $grid[1]);
    nes_putint(20, 15, $grid[19]);
}
