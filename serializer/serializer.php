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
const ZEND_ADD         = 1;
const ZEND_SUB         = 2;
const ZEND_IS_EQUAL    = 18;
const ZEND_IS_SMALLER  = 20;
const ZEND_ASSIGN      = 22;
const ZEND_QM_ASSIGN   = 31;
const ZEND_JMP         = 42;
const ZEND_JMPZ        = 43;
const ZEND_JMPNZ       = 44;
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

// === ニーモニック → opcode 番号 ===
const OPCODE_MAP = [
    'NOP'        => ZEND_NOP,
    'ADD'        => ZEND_ADD,
    'SUB'        => ZEND_SUB,
    'IS_EQUAL'   => ZEND_IS_EQUAL,
    'IS_SMALLER' => ZEND_IS_SMALLER,
    'ASSIGN'     => ZEND_ASSIGN,
    'QM_ASSIGN'  => ZEND_QM_ASSIGN,
    'JMP'        => ZEND_JMP,
    'JMPZ'       => ZEND_JMPZ,
    'JMPNZ'      => ZEND_JMPNZ,
    'ECHO'       => ZEND_ECHO,
    'RETURN'     => ZEND_RETURN,
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
 *        ; (lines=5, args=0, vars=1, tmps=3)
 *        ; (before optimizer)
 *   0000 ASSIGN CV0($a) int(1)
 *   0001 T2 = ADD CV0($a) int(2)
 *   0002 ASSIGN CV0($a) T2
 *   0003 ECHO CV0($a)
 *   0004 RETURN int(1)
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

    // 行の構造:
    //   NNNN [Tn = ] MNEMONIC [op1 [op2]]
    // result の候補は T\d+ (IS_TMP_VAR) または V\d+ (IS_VAR)
    $lineRe = '/^(\d{4})\s+(?:([TV]\d+)\s*=\s*)?([A-Z_]+)(?:\s+(.*))?$/';

    foreach (preg_split('/\R/', $text) as $line) {
        if (preg_match('/^\s*;\s*\(lines=(\d+),\s*args=\d+,\s*vars=(\d+),\s*tmps=(\d+)\)/', $line, $m)) {
            $header['lines'] = (int)$m[1];
            $header['vars']  = (int)$m[2];
            $header['tmps']  = (int)$m[3];
            continue;
        }

        if (!preg_match($lineRe, $line, $m)) {
            continue;
        }
        $index      = (int)$m[1];
        $resultTok  = $m[2] ?? '';
        $mnemonic   = $m[3];
        $operands   = trim($m[4] ?? '');

        if (!array_key_exists($mnemonic, OPCODE_MAP)) {
            fail("unsupported Zend opcode: $mnemonic at line $index");
        }

        // result (T\d+ / V\d+ only)
        [$resultType, $resultVal] = $resultTok !== ''
            ? parse_operand($resultTok, $literals, $litIndex)
            : [IS_UNUSED, 0];

        // op1, op2 をトークナイズ (string リテラル内の空白を守るため単純 split 不可)
        $tokens = tokenize_operands($operands);
        [$op1Type, $op1Val] = $tokens[0] ?? null
            ? parse_operand($tokens[0], $literals, $litIndex)
            : [IS_UNUSED, 0];
        [$op2Type, $op2Val] = $tokens[1] ?? null
            ? parse_operand($tokens[1], $literals, $litIndex)
            : [IS_UNUSED, 0];

        if (count($tokens) > 2) {
            fail("too many operands ($mnemonic): $operands");
        }

        $ops[$index] = [
            'opcode'         => OPCODE_MAP[$mnemonic],
            'mnemonic'       => $mnemonic,
            'op1'            => $op1Val,
            'op1_type'       => $op1Type,
            'op2'            => $op2Val,
            'op2_type'       => $op2Type,
            'result'         => $resultVal,
            'result_type'    => $resultType,
            'extended_value' => 0,
            'lineno'         => 1, // MVP 段階では行番号は無視
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
 * operand 列をトークン単位に分割。string("...") / int(...) / CVn($var) / Tn / Vn を認識。
 * 空白は区切り。string 内部の空白 / カンマは尊重する。
 *
 * @return string[]
 */
function tokenize_operands(string $s): array
{
    $tokens = [];
    $rest = ltrim($s);
    // 優先度順にマッチさせる (string はエスケープ対応の最長マッチ)
    $re = '/^('
        . 'string\("(?:[^"\\\\]|\\\\.)*"\)'
        . '|int\(-?\d+\)'
        . '|bool\((?:true|false)\)'
        . '|null'
        . '|CV\d+\(\$[a-zA-Z_][a-zA-Z0-9_]*\)'
        . '|[TV]\d+'
        . '|\d+'                         // raw op_index (ジャンプ先)
        . ')/';
    while ($rest !== '') {
        if (!preg_match($re, $rest, $m)) {
            fail("cannot tokenize operand starting at: $rest");
        }
        $tokens[] = $m[1];
        $rest = ltrim(substr($rest, strlen($m[1])));
    }
    return $tokens;
}

/**
 * operand 文字列を (type, value) に変換。
 * value は zend_op の op1/op2/result field (uint32) に詰める値。
 *   IS_CONST: literals 配列のバイトオフセット (literal_index * 16)
 *   IS_CV:    CV スロット番号 * sizeof(zval) = slot * 16 (Zend 慣習に近似)
 *   IS_TMP_VAR / IS_VAR: 同上 (slot * 16)
 *
 * @return array{0:int, 1:int}
 */
function parse_operand(string $s, array &$literals, array &$litIndex): array
{
    // literal: string("...")
    if (preg_match('/^string\("((?:[^"\\\\]|\\\\.)*)"\)$/', $s, $m)) {
        $value = stripcslashes($m[1]);
        validate_ascii($value);
        $idx = intern_literal($literals, $litIndex, ['type' => TYPE_STRING, 'value' => $value], "string:$value");
        return [IS_CONST, $idx * ZVAL_SIZE];
    }
    // literal: int(N)
    if (preg_match('/^int\((-?\d+)\)$/', $s, $m)) {
        $value = (int)$m[1];
        if ($value < -32768 || $value > 32767) {
            fail("integer literal out of 16bit range: $value");
        }
        $idx = intern_literal($literals, $litIndex, ['type' => TYPE_LONG, 'value' => $value], "int:$value");
        return [IS_CONST, $idx * ZVAL_SIZE];
    }
    // literal: null
    if ($s === 'null') {
        $idx = intern_literal($literals, $litIndex, ['type' => TYPE_NULL, 'value' => null], 'null');
        return [IS_CONST, $idx * ZVAL_SIZE];
    }
    // literal: bool(true/false)
    if (preg_match('/^bool\((true|false)\)$/', $s, $m)) {
        $type = $m[1] === 'true' ? TYPE_TRUE : TYPE_FALSE;
        $idx = intern_literal($literals, $litIndex, ['type' => $type, 'value' => $m[1] === 'true'], "bool:$m[1]");
        return [IS_CONST, $idx * ZVAL_SIZE];
    }
    // CV slot: CVn($name)
    if (preg_match('/^CV(\d+)\(\$\w+\)$/', $s, $m)) {
        return [IS_CV, ((int)$m[1]) * ZVAL_SIZE];
    }
    // TMP slot: Tn
    if (preg_match('/^T(\d+)$/', $s, $m)) {
        return [IS_TMP_VAR, ((int)$m[1]) * ZVAL_SIZE];
    }
    // VAR slot: Vn
    if (preg_match('/^V(\d+)$/', $s, $m)) {
        return [IS_VAR, ((int)$m[1]) * ZVAL_SIZE];
    }
    // raw jump target: 数値 (op_index)
    if (preg_match('/^\d+$/', $s)) {
        return [IS_UNUSED, (int)$s];
    }

    fail("unsupported operand: $s");
}

function intern_literal(array &$literals, array &$litIndex, array $record, string $key): int
{
    if (!array_key_exists($key, $litIndex)) {
        $literals[] = $record;
        $litIndex[$key] = count($literals) - 1;
    }
    return $litIndex[$key];
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
