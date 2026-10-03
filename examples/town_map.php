<?php
// map-edit/index.html が生成 (手で編集しない)。examples/town.php が require で取り込む。
// マップ 32x28 メタタイル、NPC/宝箱 26、メッセージ 26 件、グリフ 305 タイル。
// 本体は examples/town.data.bin (PRG-ROM bank 2 = GAMEDATA) にあり、起動時に bank 3 へ展開する。
$MW = 32;
$MH = 28;
$hx = 28;
$hy = 23;
$NPC_N = 26;
nes_rom_copy(0, 0, 8192);
