<?php
// nes_putint デモ: sprite が動きながらスコアが毎秒 7 ずつ加算されていく HUD。
// sprite_mode 中なので nes_putint は NMI 同期キュー経由で次 VBlank に反映される。
//
// 操作: 十字キーで sprite を動かす

nes_puts(8, 5, "SCORE:");
nes_puts(8, 7, "MOVE WITH ARROWS");

$x = 120;
$y = 120;
nes_sprite_at(0, $x, $y, 65);   // sprite_mode 突入

$score = 0;
$frame = 0;

while (true) {
    nes_vsync();
    $frame = $frame + 1;
    if ($frame >= 60) {        // 1 秒ごと
        $frame = 0;
        $score = $score + 7;
        nes_putint(15, 5, $score);
    }

    $b = nes_btn();
    if ($b & 0x02) { $x = $x - 1; }   // L
    if ($b & 0x01) { $x = $x + 1; }   // R
    if ($b & 0x08) { $y = $y - 1; }   // U
    if ($b & 0x04) { $y = $y + 1; }   // D
    nes_sprite_at(0, $x, $y, 65);
}
