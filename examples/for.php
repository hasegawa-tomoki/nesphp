<?php
// PRE_INC (for ループの最適化で $i++ → PRE_INC)
for ($i = 0; $i < 5; $i++) {
    echo $i;
}
// POST_INC / POST_DEC (結果を使うと残る)
$a = 10;
$b = $a++;  // $b = 10, $a = 11
echo $b;
$c = $a--;  // $c = 11, $a = 10
echo $c;
echo $a;    // 10
