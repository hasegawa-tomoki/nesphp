<?php
// Phase 3 デモ: sprite_mode 中に nes_puts / echo を動的に呼ぶ
//
// 従来 (Phase 5B 時点): nes_sprite_at 呼び出し後は rendering が常時 ON になり、
// echo / nes_put / nes_puts は使えなかった (nametable 直書きが PPU latch を
// 壊す)。
//
// Phase 3 で NMI 同期書き込みキューを入れたので、sprite_mode 中でも
// nes_puts / nes_put が動く (実際の PPU 書き込みは次 VBlank で反映される)。
//
// 操作:
//   十字キー: スプライト 'X' を 2 ピクセル単位で動かす
//   A:        "HIT!" が行を 1 つずつ下にずれて表示される
//   B:        カーソル位置に 'B' を 1 文字ぶん置く (nes_put テスト)
//
// スプライトは常時動いていて (NMI 毎フレーム OAM DMA)、それと並行して
// テキストが VBlank 同期で追記される様子が見える。

$x = 120;
$y = 120;
$row = 8;

// 初期タイトルは forced_blanking 中に書く
nes_puts(3, 2, "PHASE 3: NMI SYNC DEMO");
nes_puts(3, 4, "ARROWS: MOVE SPRITE");
nes_puts(3, 5, "A: WRITE HIT LINE");

// sprite_mode に突入
nes_sprite_at(0, $x, $y, 88);  // tile 88 = 'X'

while (true) {
    $k = fgets(STDIN);

    if ($k === "L") $x = $x - 2;
    if ($k === "R") $x = $x + 2;
    if ($k === "U") $y = $y - 2;
    if ($k === "D") $y = $y + 2;
    nes_sprite_at(0, $x, $y, 88);

    if ($k === "A") {
        // sprite_mode 中の nes_puts: NMI キュー経由で次 VBlank に反映
        nes_puts(3, $row, "HIT!");
        $row = $row + 1;
        if ($row === 20) $row = 8;
    }

    if ($k === "B") {
        // sprite_mode 中の nes_put: 同じく NMI キュー経由
        nes_put(25, $row, "*");
    }
}
