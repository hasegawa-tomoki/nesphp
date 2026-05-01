<?php
// nes_rand デモ (シンプル版): 毎フレーム 8 個のスプライトがランダムウォーク

nes_srand(1);

$xs = [40, 60, 80, 100, 140, 160, 180, 200];
$ys = [80, 80, 80, 80, 80, 80, 80, 80];

for ($i = 0; $i < 8; $i++) {
    nes_sprite_at($i, $xs[$i], $ys[$i], 65);
}

while (true) {
    nes_vsync();
    for ($i = 0; $i < 8; $i++) {
        $r = nes_rand();
        $dir = $r & 3;
        if ($dir === 0) { $xs[$i] = $xs[$i] + 1; }
        if ($dir === 1) { $xs[$i] = $xs[$i] - 1; }
        if ($dir === 2) { $ys[$i] = $ys[$i] + 1; }
        if ($dir === 3) { $ys[$i] = $ys[$i] - 1; }
        nes_sprite_at($i, $xs[$i], $ys[$i], 65);
    }
}
