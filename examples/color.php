<?php
// カラフルプレゼンデモ + 日本国旗カスタムタイル
//
// NES カラーコード: 上位 2bit = 明るさ, 下位 4bit = 色相
//   $0F=黒, $30=白, $16=暗赤, $26=赤, $12=暗青, $22=青,
//   $1A=暗緑, $2A=緑, $21=水色, $28=黄
//
// 日本国旗はカスタムタイル 0x01-0x04 (2×2 = 16×16 px)。
//   色 1 = 白 (旗の地), 色 2 = 赤 (日の丸)。
//   nes_put で int リテラルとしてタイル番号を直接指定する。

// === 背景色: 黒 ===
nes_bg_color(0x0F);

// === パレット設定 ===
// BG palette 0: 白 + 赤 (本文 + 国旗用)
nes_palette(0, 0x30, 0x16, 0x10);

// BG palette 1: 赤系 (タイトル用)
nes_palette(1, 0x26, 0x16, 0x30);

// BG palette 2: 緑系 (ハイライト用)
nes_palette(2, 0x2A, 0x1A, 0x30);

// BG palette 3: 水色系 (フッター用)
nes_palette(3, 0x21, 0x11, 0x30);

// === attribute 設定: 行ごとの色分け ===

// タイトル行 (y=1, タイル row 2-3) → パレット 1 (赤)
$ax = 0;
while ($ax < 16) {
    nes_attr($ax, 1, 1);
    $ax = $ax + 1;
}

// ハイライト行 (y=4, タイル row 8-9) → パレット 2 (緑)
$ax = 0;
while ($ax < 16) {
    nes_attr($ax, 4, 2);
    $ax = $ax + 1;
}

// フッター行 (y=12, タイル row 24-25) → パレット 3 (水色)
$ax = 0;
while ($ax < 16) {
    nes_attr($ax, 12, 3);
    $ax = $ax + 1;
}

// === テキスト表示 ===

// パレット 1 (赤) のタイトル行
nes_puts(6, 2, "NESPHP IN COLOR");

// パレット 0 (白) のデフォルト行
nes_puts(4, 5, "PHP ON FAMICOM");
nes_puts(4, 7, "ZEND OPCODE ON 6502");

// パレット 2 (緑) のハイライト行
nes_puts(4, 9, "ROMAN OVER UTILITY");

// パレット 0 (白) 通常テキスト
nes_puts(4, 12, "COLORS:");
nes_puts(6, 13, "4 BG PALETTES");
nes_puts(6, 14, "16x16 PX GRANULARITY");

// === 日本国旗 (カスタムタイル 0x01-0x04) ===
// パレット 0: c1=白, c2=赤 なので国旗が正しく表示される
nes_put(14, 17, 1);
nes_put(15, 17, 2);
nes_put(14, 18, 3);
nes_put(15, 18, 4);
nes_puts(18, 17, "MADE IN");
nes_puts(18, 18, "JAPAN");

// パレット 3 (水色) のフッター
nes_puts(4, 25, "PRESS ANY BUTTON");
