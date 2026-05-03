<?php
// Tetris Phase 2: I-piece の入力 + 自然落下
//
// 操作:
//   ←/→: 押した瞬間に 1 マス横移動 (edge trigger、押しっぱは連続移動しない)
//   ↓:   押しっぱでソフトドロップ (連続落下)
//   自然落下: 30 フレに 1 マス (0.5 秒/cell)
//
// 衝突: 横壁 (col 4 / col 13) で停止、床 (row 24) で停止。
// Phase 3 で着地時の locking + 新ピース生成、Phase 4 でライン消し。

// 静的レイアウト (Phase 1 と同じ)
nes_puts(4, 1, "TETRIS");
nes_puts(3, 4,  "+----------+");
nes_puts(3, 25, "+----------+");
for ($y = 5; $y <= 24; $y++) {
    nes_put(3, $y, "|");
    nes_put(14, $y, "|");
}
nes_puts(17, 5, "SCORE");
nes_putint(17, 6, 0);
nes_puts(17, 9, "LINES");
nes_putint(17, 10, 0);
nes_puts(17, 13, "NEXT");

// I-piece 初期位置 (盤上端中央)
$px = 7;
$py = 5;
nes_puts($px, $py, "\x05\x05\x05\x05");

$frame = 0;
$prev_btn = 0;

while (true) {
    nes_vsync();
    $b = nes_btn();
    // 押した瞬間だけ拾う edge detect: pressed = b AND NOT prev
    // 16-bit `~` がないので `0xFF - prev_btn` で 8-bit 反転代用
    $pressed = $b & (0xFF - $prev_btn);
    $prev_btn = $b;

    // ----- 移動量計算 -----
    $dx = 0;
    $dy = 0;

    // 横移動 (edge trigger)
    if (($pressed & 0x02) && $px > 4) {        // ← 左
        $dx = 0 - 1;
    } elseif (($pressed & 0x01) && $px < 10) { // ← 右 (rightmost block @ col $px+3 ≤ 13)
        $dx = 1;
    }

    // 自然落下 (30 フレに 1 回)
    $frame = $frame + 1;
    if ($frame >= 30) {
        $frame = 0;
        $dy = 1;
    }
    // ソフトドロップ (押しっぱ、自然落下と同フレでも結局 dy=1 で OK)
    if ($b & 0x04) {
        $dy = 1;
    }

    // 床で止まる
    if ($py + $dy > 24) {
        $dy = 0;
    }

    // ----- erase + 位置更新 + redraw -----
    // 移動が無くてもこの 8 ops は実行される (= 256B/frame の NMI キュー予算には余裕)
    nes_puts($px, $py, "    ");
    $px = $px + $dx;
    $py = $py + $dy;
    nes_puts($px, $py, "\x05\x05\x05\x05");
}
