<?php
nes_srand(1);
$x = 100;
$y = 100;
nes_sprite_at(0, $x, $y, 65);

while (true) {
    nes_vsync();
    $r = nes_rand();
    $dir = $r & 3;
    if ($dir === 0) { $x = $x + 1; }
    if ($dir === 1) { $x = $x - 1; }
    if ($dir === 2) { $y = $y + 1; }
    if ($dir === 3) { $y = $y - 1; }
    nes_sprite_at(0, $x, $y, 65);
}
