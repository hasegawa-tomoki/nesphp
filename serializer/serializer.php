<?php
/**
 * nesphp serializer — opcache dump → L3 ROM binary (ops.bin)
 *
 * spec の単一の真実:
 *   spec/01-rom-format.md (バイナリレイアウト)
 *   spec/04-opcode-mapping.md (opcode 番号)
 *
 * 入力:
 *   argv[1] = opcache dump (stderr of php -dopcache.opt_debug_level=0x10000 script.php)
 *   argv[2] = 出力ファイル (ops.bin)
 *
 * 出力 ops.bin の構造:
 *   [16B] op_array header
 *   [N*24B] zend_op[] (handler 除去)
 *   [M*16B] literals[] (zval)
 *   [可変] zend_string プール (24B header + content + null + padding)
 *
 * PHP 8.4 固定。
 */

declare(strict_types=1);

const PHP_VERSION_REQUIRED_MAJOR = 8;
const PHP_VERSION_REQUIRED_MINOR = 4;

// === Zend 定数 (PHP 8.4.6 Zend/zend_vm_opcodes.h より確定) ===
const ZEND_NOP         = 0;
const ZEND_RETURN      = 62;
const ZEND_ECHO        = 136;

// === Zend operand type (zend_compile.h) ===
const IS_UNUSED        = 0;
const IS_CONST         = 1;
const IS_TMP_VAR       = 2;
const IS_VAR           = 4;
const IS_CV            = 8;

// === zval type IDs (zend_types.h) ===
const TYPE_UNDEF       = 0;
const TYPE_NULL        = 1;
const TYPE_FALSE       = 2;
const TYPE_TRUE        = 3;
const TYPE_LONG        = 4;
const TYPE_DOUBLE      = 5;
const TYPE_STRING      = 6;
const TYPE_ARRAY       = 7;
const TYPE_OBJECT      = 8;

// === サイズ定数 (spec/01-rom-format.md) ===
const HEADER_SIZE      = 16;
const ZEND_OP_SIZE     = 24;   // handler 除去版
const ZVAL_SIZE        = 16;
const ZSTR_HEADER_SIZE = 24;

// === ニーモニック → opcode 番号 (MVP 対応分のみ) ===
const OPCODE_MAP = [
    'NOP'    => ZEND_NOP,
    'ECHO'   => ZEND_ECHO,
    'RETURN' => ZEND_RETURN,
];

// =================================================================
// メイン
// =================================================================

function main(array $argv): void
{
    if (count($argv) < 3) {
        fwrite(STDERR, "Usage: php serializer.php <ops.txt> <ops.bin>\n");
        exit(1);
    }
    [$_, $inPath, $outPath] = $argv;

    if (!is_file($inPath)) {
        fail("input not found: $inPath");
    }

    check_php_version();

    $text = file_get_contents($inPath);
    $dump = parse_opcache_dump($text);
    $bin  = emit_ops_bin($dump);

    // literals_off を後から埋めるので、既に emit_ops_bin 内で確定している
    if (@file_put_contents($outPath, $bin) === false) {
        fail("failed to write $outPath");
    }

    fprintf(
        STDERR,
        "[serializer] %s: %d ops, %d literals, %d bytes\n",
        $outPath,
        count($dump['ops']),
        count($dump['literals']),
        strlen($bin),
    );
}

function fail(string $msg): never
{
    fwrite(STDERR, "[serializer] error: $msg\n");
    exit(1);
}

function check_php_version(): void
{
    if (PHP_MAJOR_VERSION !== PHP_VERSION_REQUIRED_MAJOR
        || PHP_MINOR_VERSION !== PHP_VERSION_REQUIRED_MINOR) {
        fail(sprintf(
            "PHP %d.%d required (running %d.%d). nesphp is version-locked.",
            PHP_VERSION_REQUIRED_MAJOR,
            PHP_VERSION_REQUIRED_MINOR,
            PHP_MAJOR_VERSION,
            PHP_MINOR_VERSION,
        ));
    }
}

// =================================================================
// opcache ダンプのパース
// =================================================================

/**
 * 入力例:
 *   $_main:
 *        ; (lines=2, args=0, vars=0, tmps=0)
 *        ; (before optimizer)
 *        ; /path/to/hello.php:1-2
 *        ; return  [] RANGE[0..0]
 *   0000 ECHO string("HELLO, NES!")
 *   0001 RETURN int(1)
 *
 * 出力: ['header' => [...], 'ops' => [...], 'literals' => [...]]
 */
function parse_opcache_dump(string $text): array
{
    $ops = [];
    $literals = [];
    $litIndex = []; // dedup: text key → literal index

    $header = [
        'lines' => 0,
        'vars'  => 0,
        'tmps'  => 0,
    ];

    foreach (preg_split('/\R/', $text) as $line) {
        if (preg_match('/^\s*;\s*\(lines=(\d+),\s*args=\d+,\s*vars=(\d+),\s*tmps=(\d+)\)/', $line, $m)) {
            $header['lines'] = (int)$m[1];
            $header['vars']  = (int)$m[2];
            $header['tmps']  = (int)$m[3];
            continue;
        }

        if (!preg_match('/^(\d{4})\s+([A-Z_]+)(?:\s+(.*))?$/', $line, $m)) {
            continue;
        }
        $index    = (int)$m[1];
        $mnemonic = $m[2];
        $operands = trim($m[3] ?? '');

        if (!array_key_exists($mnemonic, OPCODE_MAP)) {
            fail("unsupported Zend opcode in MVP: $mnemonic at line $index");
        }

        [$op1Type, $op1Val, $op2Type, $op2Val] = split_operands($operands, $literals, $litIndex);

        $ops[$index] = [
            'opcode'         => OPCODE_MAP[$mnemonic],
            'mnemonic'       => $mnemonic,
            'op1'            => $op1Val,
            'op1_type'       => $op1Type,
            'op2'            => $op2Val,
            'op2_type'       => $op2Type,
            'result'         => 0,
            'result_type'    => IS_UNUSED,
            'extended_value' => 0,
            'lineno'         => 1, // MVP では 1 固定
        ];
    }

    if (!$ops) {
        fail('no opcodes parsed from dump');
    }
    ksort($ops);
    $ops = array_values($ops);

    return [
        'header'   => $header,
        'ops'      => $ops,
        'literals' => $literals,
    ];
}

/**
 * ECHO/RETURN の operand 部分 (1 個) をパースして (type, val) を返す。
 * MVP では 1 operand のみ対応。
 *
 * @param array<int, array{type: int, value: mixed}> $literals
 * @param array<string, int> $litIndex
 * @return array{0:int, 1:int, 2:int, 3:int}
 */
function split_operands(string $s, array &$literals, array &$litIndex): array
{
    if ($s === '') {
        return [IS_UNUSED, 0, IS_UNUSED, 0];
    }

    // MVP では ECHO も RETURN も 1 operand のみ (op1 = IS_CONST)
    $op1 = parse_literal_operand($s, $literals, $litIndex);
    return [IS_CONST, $op1, IS_UNUSED, 0];
}

/**
 * `string("HELLO, NES!")` や `int(1)` を literal プールに登録し、バイトオフセットを返す。
 *
 * @param array<int, array{type: int, value: mixed}> $literals
 * @param array<string, int> $litIndex
 */
function parse_literal_operand(string $s, array &$literals, array &$litIndex): int
{
    if (preg_match('/^string\("((?:[^"\\\\]|\\\\.)*)"\)$/', $s, $m)) {
        $value = stripcslashes($m[1]);
        validate_ascii($value);
        $key = "string:$value";
    } elseif (preg_match('/^int\((-?\d+)\)$/', $s, $m)) {
        $value = (int)$m[1];
        if ($value < -32768 || $value > 32767) {
            fail("integer literal out of 16bit range: $value");
        }
        $key = "int:$value";
    } elseif ($s === 'null') {
        $value = null;
        $key = 'null';
    } elseif ($s === 'bool(true)' || $s === 'true') {
        $value = true;
        $key = 'true';
    } elseif ($s === 'bool(false)' || $s === 'false') {
        $value = false;
        $key = 'false';
    } else {
        fail("unsupported literal operand: $s");
    }

    if (!array_key_exists($key, $litIndex)) {
        $idx = count($literals);
        $literals[] = literal_record($value);
        $litIndex[$key] = $idx;
    }
    // Zend は op1.constant にバイトオフセットを入れるので、index * 16 を返す
    return $litIndex[$key] * ZVAL_SIZE;
}

function validate_ascii(string $s): void
{
    for ($i = 0; $i < strlen($s); $i++) {
        $c = ord($s[$i]);
        if ($c > 0x7F || $c < 0x20) {
            fail(sprintf(
                "non-printable-ASCII byte 0x%02x in string literal: %s",
                $c,
                var_export($s, true),
            ));
        }
    }
}

function literal_record(mixed $value): array
{
    return match (true) {
        is_int($value)    => ['type' => TYPE_LONG,  'value' => $value],
        is_string($value) => ['type' => TYPE_STRING,'value' => $value],
        is_null($value)   => ['type' => TYPE_NULL,  'value' => null],
        $value === true   => ['type' => TYPE_TRUE,  'value' => true],
        $value === false  => ['type' => TYPE_FALSE, 'value' => false],
        default           => fail('unreachable literal type'),
    };
}

// =================================================================
// バイナリ生成
// =================================================================

function emit_ops_bin(array $dump): string
{
    $ops       = $dump['ops'];
    $literals  = $dump['literals'];
    $numOps    = count($ops);
    $numLits   = count($literals);

    // レイアウトを決める:
    //   offset 0:                   header (16B)
    //   offset 16:                  zend_op[0..numOps-1]
    //   offset 16 + numOps*24:      literals[0..numLits-1]
    //   offset literals_end:        zend_string プール
    $opsOff     = HEADER_SIZE;
    $litsOff    = $opsOff + $numOps * ZEND_OP_SIZE;
    $stringPool = '';
    $stringOffsets = []; // literal index → zend_string へのオフセット (ops.bin 先頭からのバイト)

    // 1. 文字列プールを先に組む (literals[] が offset を参照する)
    $stringPoolStart = $litsOff + $numLits * ZVAL_SIZE;
    foreach ($literals as $i => $lit) {
        if ($lit['type'] === TYPE_STRING) {
            $stringOffsets[$i] = $stringPoolStart + strlen($stringPool);
            $stringPool .= pack_zend_string($lit['value']);
        }
    }

    // 2. ヘッダ
    $header = pack_header(
        numOpcodes: $numOps,
        literalsOff: $litsOff,
        numLiterals: $numLits,
        numCvs:  $dump['header']['vars'],
        numTmps: $dump['header']['tmps'],
    );

    // 3. ops
    $opsBin = '';
    foreach ($ops as $op) {
        $opsBin .= pack_zend_op($op);
    }
    assert(strlen($opsBin) === $numOps * ZEND_OP_SIZE);

    // 4. literals
    $litsBin = '';
    foreach ($literals as $i => $lit) {
        $litsBin .= pack_zval($lit, $stringOffsets[$i] ?? 0);
    }
    assert(strlen($litsBin) === $numLits * ZVAL_SIZE);

    return $header . $opsBin . $litsBin . $stringPool;
}

function pack_header(
    int $numOpcodes,
    int $literalsOff,
    int $numLiterals,
    int $numCvs,
    int $numTmps,
): string {
    // spec/01-rom-format.md
    // 0  u16 num_opcodes
    // 2  u16 literals_off
    // 4  u16 num_literals
    // 6  u16 num_cvs
    // 8  u16 num_tmps
    // 10 u8  php_version_major
    // 11 u8  php_version_minor
    // 12 4B  reserved
    $bin = pack(
        'vvvvv',
        $numOpcodes,
        $literalsOff,
        $numLiterals,
        $numCvs,
        $numTmps,
    );
    $bin .= chr(PHP_VERSION_REQUIRED_MAJOR);
    $bin .= chr(PHP_VERSION_REQUIRED_MINOR);
    $bin .= "\x00\x00\x00\x00";
    assert(strlen($bin) === HEADER_SIZE);
    return $bin;
}

function pack_zend_op(array $op): string
{
    // spec/01-rom-format.md
    // 0  u32 op1
    // 4  u32 op2
    // 8  u32 result
    // 12 u32 extended_value
    // 16 u32 lineno
    // 20 u8  opcode
    // 21 u8  op1_type
    // 22 u8  op2_type
    // 23 u8  result_type
    $bin = pack(
        'VVVVV',
        $op['op1'] & 0xFFFFFFFF,
        $op['op2'] & 0xFFFFFFFF,
        $op['result'] & 0xFFFFFFFF,
        $op['extended_value'] & 0xFFFFFFFF,
        $op['lineno'] & 0xFFFFFFFF,
    );
    $bin .= chr($op['opcode'] & 0xFF);
    $bin .= chr($op['op1_type'] & 0xFF);
    $bin .= chr($op['op2_type'] & 0xFF);
    $bin .= chr($op['result_type'] & 0xFF);
    assert(strlen($bin) === ZEND_OP_SIZE);
    return $bin;
}

function pack_zval(array $lit, int $stringOff): string
{
    // spec/01-rom-format.md
    // 0  8B value union
    // 8  4B u1.type_info (下位 1B = type ID)
    // 12 4B u2
    $type = $lit['type'];
    $value8 = "\x00\x00\x00\x00\x00\x00\x00\x00";

    switch ($type) {
        case TYPE_LONG:
            $v = $lit['value'];
            if ($v < 0) {
                $v += 1 << 16;
            }
            // little-endian 8 バイトに詰める (下位 16bit 有効)
            $value8 = pack('v', $v & 0xFFFF) . "\x00\x00\x00\x00\x00\x00";
            break;

        case TYPE_STRING:
            // 下位 16bit に zend_string へのオフセット (ops.bin 先頭から)
            $value8 = pack('v', $stringOff & 0xFFFF) . "\x00\x00\x00\x00\x00\x00";
            break;

        case TYPE_NULL:
        case TYPE_TRUE:
        case TYPE_FALSE:
        case TYPE_UNDEF:
            // value 未使用
            break;

        default:
            fail("cannot pack zval type $type");
    }

    $typeInfo = pack('V', $type & 0xFF);
    $u2       = "\x00\x00\x00\x00";

    $bin = $value8 . $typeInfo . $u2;
    assert(strlen($bin) === ZVAL_SIZE);
    return $bin;
}

function pack_zend_string(string $s): string
{
    // spec/01-rom-format.md
    // 0  4B gc.refcount    (0)
    // 4  4B gc.type_info   (0x40 = IMMUTABLE 相当)
    // 8  8B h              (hash, 0 埋め)
    // 16 8B len             (下位 16bit 有効)
    // 24 N  val[len]
    // 24+len 1 NUL terminator
    // padding to 4B alignment
    $len = strlen($s);

    $bin  = "\x00\x00\x00\x00";                       // refcount
    $bin .= pack('V', 0x40);                          // gc.type_info
    $bin .= "\x00\x00\x00\x00\x00\x00\x00\x00";       // h
    $bin .= pack('v', $len) . "\x00\x00\x00\x00\x00\x00"; // len (16bit + pad)
    assert(strlen($bin) === ZSTR_HEADER_SIZE);

    $bin .= $s . "\x00";

    // 4B アラインメント
    while (strlen($bin) % 4 !== 0) {
        $bin .= "\x00";
    }
    return $bin;
}

main($argv);
