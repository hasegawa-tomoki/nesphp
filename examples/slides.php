<?php
// プレゼンテーション: ボタンを押すごとに 1 行ずつ出す。
// 最後のスライドで「RESET」行を出した後にボタンを押すと先頭から。
//
// 制御: A / B / 十字キー / Start / Select どれでも「次へ」。
// 1 行目以降は nes_puts で描画、nes_cls で画面クリア。

$p = 0;

while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;

    if ($p === 7) {
        $p = 1;
    }

    if ($p === 1) {
        nes_cls();
        nes_puts(4, 4, "NESPHP PRESENTATION");
    }
    if ($p === 2) {
        nes_puts(4, 7, "1. PHP ON FAMICOM");
    }
    if ($p === 3) {
        nes_puts(4, 9, "2. ZEND OPCODE ON 6502");
    }
    if ($p === 4) {
        nes_puts(4, 11, "3. L3 ROM LAYOUT");
    }
    if ($p === 5) {
        nes_puts(4, 13, "4. ROMAN OVER UTILITY");
    }
    if ($p === 6) {
        nes_puts(4, 16, "PRESS ANY KEY TO RESET");
    }
}
