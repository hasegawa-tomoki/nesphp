<?php
// peek/poke/pokestr スモークテスト

nes_pokestr(0, "ABCDE");      // user_ram[0..4] = 'A'..'E'
nes_poke(5, 70);                // user_ram[5] = 'F'
nes_poke(6, 0);                 // user_ram[6] = 0 (= space tile)

// 表示: row 5 col 4 から 6 文字
$i = 0;
while ($i < 6) {
    nes_put($i + 4, 5, " ");    // forced_blanking で先に枠書く必要なし
    $i = $i + 1;
}

// peek で読んで 1 文字ずつ書き戻す
$i = 0;
while ($i < 6) {
    $b = nes_peek($i);
    nes_putint($i + 4, 7, $b);  // 値を 5 桁で表示
    $i = $i + 1;
}
