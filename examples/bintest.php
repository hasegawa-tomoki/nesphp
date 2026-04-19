<?php
// 2 進 / 16 進 / 10 進リテラルの混在テスト
$a = 0b1010;         // = 10
$b = 0xFF;           // = 255
$c = 15;             // decimal
echo $a;             // 10
echo $b - $c;        // 240
echo 0b11 & 0b10;    // 2
echo 0b01 | 0b10;    // 3
