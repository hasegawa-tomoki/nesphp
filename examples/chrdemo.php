<?php
// CHR bank 切替デモ (MMC1 4KB 独立 banking)
//
// 押すたびに状態が進む:
//   p=1: 通常テキスト (BG = 4KB bank 0)
//   p=2: BG をインバースに切替 (BG = 4KB bank 1)
//   p=3: BG を通常に戻す (BG = 4KB bank 0)
//   p=4: sprite を別 bank に切替 (SPR = 4KB bank 2, 初期は bank 0 コピー)
//   p=5: sprite を元に戻す (SPR = 4KB bank 0)
//
// nes_chr_bg($n): BG 用の 4KB CHR bank を切替 (MMC1 CHR bank 0, $0000)
// nes_chr_spr($n): sprite 用の 4KB CHR bank を切替 (MMC1 CHR bank 1, $1000)
// BG と sprite は独立して切替可能。

$p = 0;

while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;
    if ($p === 6) { $p = 1; }

    if ($p === 1) {
        nes_chr_bg(0);
        nes_chr_spr(0);
        nes_cls();
        nes_puts(4, 4, "CHR BANK DEMO (MMC1)");
        nes_puts(4, 7, "STATE 1: NORMAL");
    }
    if ($p === 2) {
        nes_chr_bg(1);
        nes_puts(4, 10, "STATE 2: BG INVERSE");
    }
    if ($p === 3) {
        nes_chr_bg(0);
        nes_puts(4, 13, "STATE 3: BG NORMAL");
    }
    if ($p === 4) {
        nes_chr_spr(2);
        nes_puts(4, 16, "STATE 4: SPR BANK 2");
    }
    if ($p === 5) {
        nes_chr_spr(0);
        nes_puts(4, 19, "STATE 5: SPR BANK 0");
    }
}
