<?php
// runtime index による配列書込テスト
$xs = [10, 20, 30];

$xs[1] = 99;          // literal index — 既知 OK
echo $xs[1];          // 99
echo " ";

$i = 2;
$xs[$i] = 88;         // ★runtime index write
echo $xs[$i];         // 期待 88
echo " ";

$xs[$i] = $xs[$i] + 1; // ★runtime index 自己参照
echo $xs[$i];         // 期待 89
