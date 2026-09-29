<?php
// nes_scroll / nametable 2 枚 (x 0-63) の検証
// 左半分 (NT0) に 'A'、右半分 (NT1) に 'B' を敷き、NT1 側は palette 1 (赤)。
// 毎フレーム x を 1px、2 フレームに 1px y を進めて 4 方向に流す。
nes_palette(1, 0x16, 0x16, 0x16);
$y = 0;
while ($y < 30) {
    $x = 0;
    while ($x < 32) {
        nes_put($x, $y, "A");
        $x2 = $x + 32;
        nes_put($x2, $y, "B");
        $x = $x + 1;
    }
    $y = $y + 1;
}
$y = 0;
while ($y < 15) {
    $x = 16;
    while ($x < 32) {
        nes_attr($x, $y, 1);
        $x = $x + 1;
    }
    $y = $y + 1;
}
nes_puts(0, 0, "NT0 TOP-LEFT");
nes_put(32, 0, "N"); nes_put(33, 0, "T"); nes_put(34, 0, "1");
nes_put(0, 29, "L"); nes_put(1, 29, "B");
nes_put(63, 29, "R"); nes_put(62, 29, "B");

$sx = 0;
$sy = 0;
$f = 0;
nes_sprite_at(0, 120, 112, 0x80);
while (true) {
    nes_vsync();
    $sx = $sx + 1;
    if ($sx === 512) { $sx = 0; }
    $f = $f + 1;
    if ($f === 2) {
        $f = 0;
        $sy = $sy + 1;
        if ($sy === 240) { $sy = 0; }
    }
    nes_scroll($sx, $sy);
}
