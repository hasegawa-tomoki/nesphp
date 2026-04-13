<?php
$x = 120;
$y = 120;
nes_sprite($x, $y, 65);
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 2;
    if ($k === "R") $x = $x + 2;
    if ($k === "U") $y = $y - 2;
    if ($k === "D") $y = $y + 2;
    nes_sprite($x, $y, 65);
}
