<?php
$x = 16;
$y = 14;
nes_put($x, $y, "X");
while (true) {
    $k = fgets(STDIN);
    nes_put($x, $y, " ");
    if ($k === "L") $x = $x - 1;
    if ($k === "R") $x = $x + 1;
    if ($k === "U") $y = $y - 1;
    if ($k === "D") $y = $y + 1;
    nes_put($x, $y, "X");
}
