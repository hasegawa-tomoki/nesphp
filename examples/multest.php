<?php
// * / % の動作確認
echo 5 * 3;          echo " ";   // 15
echo 100 / 7;        echo " ";   // 14
echo 100 % 7;        echo " ";   // 2
echo 1 + 2 * 3;      echo " ";   // 7 (precedence: * binds tighter)
echo (1 + 2) * 3;    echo " ";   // 9 (paren override)
echo 7 / 0;          echo " ";   // 0 (silent fallback)
echo 0 - 6 * 2;      echo " ";   // -12 (signed wrap)

// game-like: grid index
$y = 5;
$x = 3;
echo $y * 10 + $x;               // 53
