<?php
// else / elseif / <= / > / >= / 括弧式 の動作確認

// --- 比較演算子 (if 経由で結果確認) ---
$a = 5;
if ($a <= 5) { echo "A"; } else { echo "X"; }   // A
if ($a > 4)  { echo "B"; }                       // B
if ($a >= 5) { echo "C"; }                       // C
if ($a > 5)  { echo "X"; }                       // (出ない)
echo " ";

// --- else / elseif チェーン ---
$x = 10;
if ($x < 5)        { echo "Z"; }
elseif ($x < 15)   { echo "T"; }
else                { echo "U"; }
echo " ";

$y = 2;
if ($y === 1)      { echo "1"; }
elseif ($y === 2)  { echo "2"; }
elseif ($y === 3)  { echo "3"; }
else                { echo "?"; }
echo " ";

// --- 括弧式 (precedence override) ---
$p = 1 + (2 << 3);   // 1 + 16 = 17
echo $p;
echo " ";
$q = 1 + 2 << 3;     // (1+2) << 3 = 24 (default precedence)
echo $q;
