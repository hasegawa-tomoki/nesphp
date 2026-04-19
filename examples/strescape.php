<?php
// \xHH エスケープ確認
// タイル番号で Japanese kanji 等を出力 (CHR に独自タイルを配置済の前提)
echo "A\x42C";       // "ABC" (0x41, 0x42, 0x43 = 'A','B','C')
echo "\x48\x49";     // "HI"
echo "\\\"";         // リテラル `\` と `"`
