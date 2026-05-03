<?php
$x = 7;
$mask = 15 << ($x - 4);
echo $mask;   // expect 120

echo " ";

$y = 5;
$grid = [0, 0, 0];
$grid[0] = $grid[0] | $mask;
echo $grid[0];   // expect 120

echo " ";

if (($grid[0] & $mask) !== 0) { echo "HIT"; } else { echo "MISS"; }
