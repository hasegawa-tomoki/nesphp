<?php
// Phase 3.1 デモ: sprite_mode 中に nes_cls で画面クリアしてから再描画する
//
// 従来 (Phase 3 時点): sprite_mode 中の nes_cls は rendering on 中に PPUDATA を
// 叩くため画面破壊を起こしていた。Phase 3.1 で「一時的に rendering を OFF に
// して clear → VBlank 待ち → rendering 再 ON」するようにしたため、1-2 フレーム
// の黒フラッシュを挟んで安全にクリアできるようになった。
//
// 操作:
//   十字キー: スプライト 'X' を 2 ピクセル単位で動かす
//   A:        画面クリア + 新しいテキスト表示 (スライド遷移のトランジション)

$x = 120;
$y = 120;
$p = 0;

nes_puts(3, 2, "PHASE 3.1: CLS DEMO");
nes_puts(3, 4, "PRESS A TO CLEAR");
nes_puts(3, 5, "ARROWS MOVE SPRITE");

// sprite_mode に突入
nes_sprite($x, $y, 88);  // tile 88 = 'X'

while (true) {
    $k = fgets(STDIN);

    if ($k === "L") $x = $x - 2;
    if ($k === "R") $x = $x + 2;
    if ($k === "U") $y = $y - 2;
    if ($k === "D") $y = $y + 2;
    nes_sprite($x, $y, 88);

    if ($k === "A") {
        $p = $p + 1;
        if ($p === 4) $p = 1;

        // sprite_mode 中の nes_cls: brief force-blanking で安全にクリア
        nes_cls();

        if ($p === 1) {
            nes_puts(3, 4, "SLIDE ONE");
            nes_puts(3, 6, "HELLO FROM CLS");
        }
        if ($p === 2) {
            nes_puts(3, 4, "SLIDE TWO");
            nes_puts(3, 6, "STILL MOVING");
        }
        if ($p === 3) {
            nes_puts(3, 4, "SLIDE THREE");
            nes_puts(3, 6, "BACK TO ONE NEXT");
        }
    }
}
