<?php
// CHR bank + PPUCTRL bit 4 切替のデモ
//
// 押すたびに状態が進む:
//   p=1: 通常テキスト
//   p=2: nes_chr_bg(1) でインバース (同じ bank 内 pattern table 1 = 白抜き)
//   p=3: nes_chr_bg(0) で通常に戻す
//   p=4: nes_chr_bank(1) → バンク 1 (初期は bank 0 コピーなので見た目変化なし、
//        差し替え後は別タイルセットに切替わる)
//   p=5: nes_chr_bank(0) に戻す
//
// プレゼンでは「bank 0 = 本文、bank 1 = タイトル用装飾フォント」みたいに
// 割り当てると効く。

$p = 0;

while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;
    if ($p === 6) { $p = 1; }

    if ($p === 1) {
        nes_chr_bg(0);
        nes_chr_bank(0);
        nes_cls();
        nes_puts(4, 4, "PATTERN TABLE DEMO");
        nes_puts(4, 7, "STATE 1: NORMAL");
    }
    if ($p === 2) {
        nes_chr_bg(1);
        nes_puts(4, 10, "STATE 2: INVERSE");
    }
    if ($p === 3) {
        nes_chr_bg(0);
        nes_puts(4, 13, "STATE 3: BACK");
    }
    if ($p === 4) {
        nes_chr_bank(1);
        nes_puts(4, 16, "STATE 4: BANK 1");
    }
    if ($p === 5) {
        nes_chr_bank(0);
        nes_puts(4, 19, "STATE 5: BANK 0");
    }
}
