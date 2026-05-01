<?php
// リアルタイム入力 API (nes_vsync + nes_btn) のデモ。
//
// nes_btn() は 0 引数で、コントローラの現在状態を IS_LONG (下位 1B = bitmask)
// で返す。呼び出し側で `$b & 0x80` のようにビット演算で検査する。
//
// mask bit: A=0x80 B=0x40 Select=0x20 Start=0x10 U=0x08 D=0x04 L=0x02 R=0x01

$x = 120;
$y = 120;
nes_sprite_at(0, $x, $y, 88);  // tile 88 = 'X'

while (true) {
    nes_vsync();
    $b = nes_btn();
    if ($b & 0x02) { $x = $x - 1; }  // Left
    if ($b & 0x01) { $x = $x + 1; }  // Right
    if ($b & 0x08) { $y = $y - 1; }  // Up
    if ($b & 0x04) { $y = $y + 1; }  // Down
    nes_sprite_at(0, $x, $y, 88);
}
