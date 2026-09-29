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

// require 'file.php'; / require __DIR__ . '/file.php'; をホスト側でインライン展開する。
// on-NES コンパイラは require を知らないので、展開後のソースだけが ROM に載る。
// 展開先の先頭 <?php 行は削る。パスは include 元ファイルのディレクトリ基準。
$baseDir = dirname(realpath($argv[1]));
$src = preg_replace_callback(
    '/^[ \t]*require\s+(?:__DIR__\s*\.\s*)?[\'"]\/?([^\'"]+)[\'"]\s*;[ \t]*$/m',
    function (array $m) use ($baseDir): string {
        $path = $baseDir . '/' . $m[1];
        $inc = file_get_contents($path);
        if ($inc === false) {
            fwrite(STDERR, "pack_src: cannot read required file {$path}\n");
            exit(1);
        }
        $inc = preg_replace('/^<\?php[ \t]*\r?\n?/', '', $inc, 1);
        fwrite(STDERR, "[pack_src] inlined {$m[1]} (" . strlen($inc) . "B)\n");
        return "// --- begin {$m[1]} ---\n" . rtrim($inc) . "\n// --- end {$m[1]} ---";
    },
    $src
);

// サイズ削減: 文字列リテラル外の // コメントを削り、行頭/行末の空白を落とす。
// 改行は残すので、on-NES コンパイラが出す ERR L<行> は元ソースの行番号のまま。
$lines = explode("\n", $src);
foreach ($lines as &$line) {
    $out = '';
    $q = null;                       // 現在の引用符 (" or ') / null
    $n = strlen($line);
    for ($i = 0; $i < $n; $i++) {
        $ch = $line[$i];
        if ($q === null) {
            if ($ch === '"' || $ch === "'") {
                $q = $ch;
            } elseif ($ch === '/' && $i + 1 < $n && $line[$i + 1] === '/') {
                break;               // コメント開始: 行の残りを捨てる
            }
        } else {
            if ($ch === '\\' && $i + 1 < $n) {   // エスケープは 2 文字まとめて通す
                $out .= $ch . $line[$i + 1];
                $i++;
                continue;
            }
            if ($ch === $q) {
                $q = null;
            }
        }
        $out .= $ch;
    }
    $line = trim($out);
}
unset($line);
$src = implode("\n", $lines);

// 非 ASCII バイトは pass through する (NES lexer がコメント/文字列内で透過)。
// 外側に出てきた non-ASCII は NES 側で compile error (ERR L/C 画面表示)。
$len = strlen($src);
if ($len > 16382) {
    fwrite(STDERR, "pack_src: source too long ({$len}B > 16382B cap)\n");
    exit(1);
}

file_put_contents($argv[2], pack('v', $len) . $src);
fwrite(STDERR, "[pack_src] {$argv[2]}: src={$len}B\n");
