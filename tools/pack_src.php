<?php
/**
 * pack_src.php — PHP ソースを NES カートリッジ向けにパック。
 *
 * 用途: on-NES 自己ホストコンパイラ (vm/compiler.s) が読む ROM 内ブロックを作る。
 *
 * 出力フォーマット (little-endian):
 *   offset  size  意味
 *   0       2     src_len        本体 ASCII 長
 *   2       2     pool_off       zend_string プール先頭までの byte offset
 *   4       2     pool_count     プール内 zend_string 数
 *   6       2     reserved (0)
 *   8       N     ASCII 本体 (<?php タグ除去済み、N = src_len)
 *   ...     M     (pad to pool_off)
 *   pool_off:     zend_string プール (spec/01-rom-format.md §4 準拠、24B header
 *                 + content + null terminator を連結)
 *
 * プールの意図:
 *   - 文字列リテラルは ROM に固定配置したい (strings hello.nes で見える方がロマン)
 *   - pack_src 時に PHP ソースを先行スキャンして文字列リテラルを列挙し、
 *     各々に対して Zend 互換の 24B zend_string ヘッダを ROM 内に焼き込む
 *   - NES 側コンパイラは source 中の文字列リテラルを順に読み、対応する
 *     pool エントリの ROM アドレスを zval.value.str (OPS_BASE 相対 offset) に
 *     書き込むだけ。PRG-RAM には zend_string を emit しない
 *
 * 仕様:
 *   - 先頭の <?php タグを剥がす
 *   - 末尾の余分な空白をトリム、改行 1 つ残す
 *   - ASCII 以外は compile error
 *   - 文字列リテラルはダブルクォート限定、エスケープ未対応 (M-A スコープ)
 *   - 最大サイズは PRG bank 0 の 16KB
 *
 * 使い方: php tools/pack_src.php <input.php> <output.src.bin>
 */

if ($argc !== 3) {
    fwrite(STDERR, "usage: php pack_src.php <input.php> <output.src.bin>\n");
    exit(1);
}

$in  = $argv[1];
$out = $argv[2];

$src = file_get_contents($in);
if ($src === false) {
    fwrite(STDERR, "pack_src: cannot read $in\n");
    exit(1);
}

// <?php タグ剥がし
if (substr($src, 0, 5) !== '<?php') {
    fwrite(STDERR, "pack_src: input must start with <?php\n");
    exit(1);
}
$body = substr($src, 5);
$body = rtrim($body) . "\n";

// ASCII チェック
for ($i = 0, $n = strlen($body); $i < $n; $i++) {
    $c = ord($body[$i]);
    if ($c > 0x7F) {
        fwrite(STDERR, "pack_src: non-ASCII byte 0x" . dechex($c) . " at offset $i\n");
        exit(1);
    }
}

$src_len = strlen($body);

// 文字列リテラルをスキャン (M-A: ダブルクォート、エスケープなし)
$strings = [];
$i = 0;
while ($i < $src_len) {
    if ($body[$i] === '"') {
        $i++;
        $start = $i;
        while ($i < $src_len && $body[$i] !== '"') {
            $i++;
        }
        if ($i === $src_len) {
            fwrite(STDERR, "pack_src: unterminated string literal at offset $start\n");
            exit(1);
        }
        $strings[] = substr($body, $start, $i - $start);
        $i++;
    } else {
        $i++;
    }
}

// zend_string プールを構築 (spec/01-rom-format.md §4)
$pool = '';
foreach ($strings as $s) {
    $pool .= pack('V', 0);            // refcount
    $pool .= pack('V', 0x40);         // gc.type_info (IMMUTABLE)
    $pool .= pack('P', 0);            // hash = 0 (8B)
    $pool .= pack('P', strlen($s));   // len (8B, 下位 2B のみ有効想定)
    $pool .= $s;
    $pool .= "\0";                    // null terminator
}

// レイアウト: 8B ヘッダ + src + (pad to 4) + pool
$header_size = 8;
$pool_off = $header_size + $src_len;
// 4B alignment
if ($pool_off & 3) {
    $pool_off = ($pool_off + 3) & ~3;
}
$pad = $pool_off - ($header_size + $src_len);

$cap = 16384;
$total = $pool_off + strlen($pool);
if ($total > $cap) {
    fwrite(STDERR, "pack_src: total size $total B > $cap B cap\n");
    exit(1);
}

$bin  = pack('vvvv', $src_len, $pool_off, count($strings), 0);
$bin .= $body;
$bin .= str_repeat("\0", $pad);
$bin .= $pool;

if (file_put_contents($out, $bin) === false) {
    fwrite(STDERR, "pack_src: cannot write $out\n");
    exit(1);
}

$pool_bytes = strlen($pool);
$nstr = count($strings);
fwrite(STDERR, "[pack_src] $out: src={$src_len}B, {$nstr} strings, pool={$pool_bytes}B, total={$total}B\n");
