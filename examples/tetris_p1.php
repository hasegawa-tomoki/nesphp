<?php
// Tetris Phase 1: 静的描画
//
// レイアウト:
//   col 3..14 = 盤の枠 (内側 10 マス: col 4-13)
//   row 4..25 = 盤の高さ (内側 20 行: row 5-24)
//   col 17..  = HUD (SCORE / LINES / NEXT)
//
// CHR 拡張 (chr/make_font.php):
//   \x05 = 中塗りブロック (palette color 1 = $30 白)
//   \x06 = 枠線付きブロック (外周 color 2 + 内側 color 1)
// nes_put の第 3 引数は char リテラルなので、`"\x05"` のような escape で
// タイル番号を直接指定する。

// タイトル
nes_puts(4, 1, "TETRIS");

// 盤の上下枠 (col 3..14、12 マス: '+' '-...' '+')
nes_puts(3, 4,  "+----------+");
nes_puts(3, 25, "+----------+");

// 盤の左右縦枠
for ($y = 5; $y <= 24; $y++) {
    nes_put(3, $y, "|");
    nes_put(14, $y, "|");
}

// HUD ラベルと初期値
nes_puts(17, 5, "SCORE");
nes_putint(17, 6, 0);
nes_puts(17, 9, "LINES");
nes_putint(17, 10, 0);
nes_puts(17, 13, "NEXT");

// I-piece (4 ブロック横並び) を盤中央 (col 7..10、row 14) に静的に置く
// 中塗りブロック \x05 を 4 個
nes_puts(7, 14, "\x05\x05\x05\x05");

// プログラム終了で ZEND_RETURN が走り、rendering ON + halt
