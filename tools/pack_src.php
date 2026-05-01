<?php
/**
 * pack_src.php — PHP ソースを NES カートリッジ向けにパック。
 *
 * 出力フォーマット:
 *   offset  size  意味
 *   0       2     src_len (u16, little-endian)
 *   2       N     ASCII 本体 (<?php タグ含め、そのまま)
 *
 * on-NES コンパイラ (vm/compiler.s) が src_len を読み、$8002 以降の ASCII を
 * lex/parse する。ホスト側の前処理は「長さ前置 + ASCII 確認」のみ。
 *
 * 使い方: php tools/pack_src.php <input.php> <output.src.bin>
 */

if ($argc !== 3) {
    fwrite(STDERR, "usage: php pack_src.php <input.php> <output.src.bin>\n");
    exit(1);
}

$src = file_get_contents($argv[1]);
if ($src === false) {
    fwrite(STDERR, "pack_src: cannot read {$argv[1]}\n");
    exit(1);
}

// 非 ASCII バイトは pass through する (NES lexer がコメント/文字列内で透過)。
// 外側に出てきた non-ASCII は NES 側で compile error (ERR L/C 画面表示)。
//
// 16366B = 16KB (PRG bank 0) - 2B (u16 length prefix) - 16B (bank 0 末尾の
// MMC1 reset trampoline + ベクタミラー、vm/nesphp.cfg / vm/nesphp.s 参照)。
$len = strlen($src);
if ($len > 16366) {
    fwrite(STDERR, "pack_src: source too long ({$len}B > 16366B cap)\n");
    exit(1);
}

file_put_contents($argv[2], pack('v', $len) . $src);
fwrite(STDERR, "[pack_src] {$argv[2]}: src={$len}B\n");
