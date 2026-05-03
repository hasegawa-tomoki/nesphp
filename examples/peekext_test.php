<?php
// USER_RAM_EXT (PRG-RAM bank 2) スモークテスト

nes_puts(8, 12, "USER RAM EXT TEST");

// 1. poke_ext + peek_ext: byte 単位の R/W
nes_poke_ext(0, 66);     // 'B'
nes_poke_ext(1, 65);     // 'A'
$b0 = nes_peek_ext(0);
$b1 = nes_peek_ext(1);
nes_putint(11, 14, $b0);   // 期待 66
nes_putint(20, 14, $b1);   // 期待 65

// 2. peek16_ext テスト
nes_poke_ext(100, 0x34);
nes_poke_ext(101, 0x12);
$v = nes_peek16_ext(100);
nes_putint(13, 16, $v);    // 期待 4660

// 3. pokestr_ext テスト
nes_pokestr_ext(200, "XY");
$x = nes_peek_ext(200);
$y = nes_peek_ext(201);
nes_putint(11, 18, $x);    // 期待 88 ('X')
nes_putint(20, 18, $y);    // 期待 89 ('Y')
