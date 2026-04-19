# 12. Zend 原本との対比: nesphp の改変点

[← README](./README.md) | [← 01-rom-format](./01-rom-format.md) | [← 10-devlog](./10-devlog.md)

この文書は「**原本 Zend の opcode / zval / zend_string / op_array の構造** と、
**nesphp がそれらをどう変更して 6502 ROM に載せたか**」の対比資料です。
byte レベルの厳密なレイアウト仕様は [01-rom-format](./01-rom-format.md) が単一
の真実で、こちらはその**背景と設計判断**を説明するアーキテクチャドキュメントと
して読んでください。

参考 (上流の定義):
- [php-src Zend/zend_compile.h](https://github.com/php/php-src/blob/master/Zend/zend_compile.h) — `struct _zend_op` `union znode_op` `IS_CONST` 等
- [php-src Zend/zend_types.h](https://github.com/php/php-src/blob/master/Zend/zend_types.h) — `struct _zval_struct` `struct _zend_string`
- [php-src Zend/zend_vm_opcodes.h](https://github.com/php/php-src/blob/master/Zend/zend_vm_opcodes.h) — opcode 定数

---

# オリジナルの Zend opcode フォーマット (PHP 8.4)

## `struct _zend_op` (32 バイト on 64bit)

`Zend/zend_compile.h` の実体:

```c
struct _zend_op {
    const void    *handler;       // 8B  ハンドラ関数への C ポインタ
    znode_op       op1;           // 4B  第 1 operand (union)
    znode_op       op2;           // 4B  第 2 operand (union)
    znode_op       result;        // 4B  結果格納先 (union)
    uint32_t       extended_value;// 4B  追加情報 (3 引数目 / flags / etc.)
    uint32_t       lineno;        // 4B  PHP ソース行番号 (デバッグ用)
    zend_uchar     opcode;        // 1B  命令番号
    zend_uchar     op1_type;      // 1B  operand 種別 (IS_CONST 等)
    zend_uchar     op2_type;      // 1B
    zend_uchar     result_type;   // 1B
};
```

### `handler` フィールドが最初にある理由

Zend は **direct-threaded / call-threaded dispatch** を使うために、opcache
コンパイル時に各 opcode の C ハンドラ関数ポインタを `handler` に焼き込みます。
実行時は

```c
for (;;) {
    ((zend_vm_handler)(opline->handler))();
    if (done) break;
}
```

のように、opcode バイトを見ずに `handler()` 呼び出しだけで dispatch します
(一部ビルド構成では GOTO / SWITCH 版も選べる)。この「ハンドラを直接呼ぶ」
モデルが PHP VM の高速化のキモなので、`handler` は構造体の **先頭** に置かれて
キャッシュヒット率が最適化されています。

### `znode_op` (4 バイトの union)

```c
typedef union _znode_op {
    uint32_t constant;   // literals 配列へのバイトオフセット
    uint32_t var;        // execute_data 内のスロット byte offset
    uint32_t num;        // 汎用数値 (arg count 等)
    uint32_t opline_num; // op_array->opcodes[] のインデックス
    uint32_t jmp_offset; // JMP の runtime byte offset
} znode_op;
```

4 バイトが文脈で意味を変える union で、どの解釈を使うかは隣の `*_type` フィー
ルドが決めます (`IS_CONST` → constant, `IS_CV` → var, `IS_UNUSED` → num /
jmp_offset)。

### operand type (`Zend/zend_compile.h`)

| 値 | 名前 |
|---|---|
| 0x00 | `IS_UNUSED` |
| 0x01 | `IS_CONST` |
| 0x02 | `IS_TMP_VAR` |
| 0x04 | `IS_VAR` |
| 0x08 | `IS_CV` |

## `struct _zval_struct` (16 バイト)

> **なぜここで zval が出てくるか**: `zend_op.op1` の `*_type` が `IS_CONST` の
> とき、その 4 バイトは「literals 配列 (= `zval` の配列) へのバイトオフセット」
> です。つまり **オペランドの意味を解釈するには literals の要素 = `zval` の
> レイアウトを知っている必要がある**。`zend_op` は単独で完結せず、次の階層
> `zval`、さらに文字列なら `zend_string` までチェーンで参照先が続きます。

`Zend/zend_types.h`:

```c
struct _zval_struct {
    zend_value    value;   // 8B union (lval/dval/str/arr/obj/...)
    union {
        uint32_t  type_info;
        struct {
            zend_uchar type;       // ← 下位 1B に type ID
            zend_uchar type_flags;
            union { uint16_t extra; } u;
        } v;
    } u1;                  // 4B
    union {
        uint32_t  next;
        uint32_t  cache_slot;
        // ... 10 種類以上の用途違い
    } u2;                  // 4B
};
```

`value` union の中身:

```c
typedef union _zend_value {
    zend_long        lval;   // 8B 符号付き整数 (64bit build なら int64)
    double           dval;   // 8B IEEE 754
    zend_string     *str;    // 8B ポインタ
    zend_array      *arr;    // 8B ポインタ
    zend_object     *obj;    // 8B ポインタ
    /* ... */
} zend_value;
```

type ID (`Zend/zend_types.h`):

| 値 | 名前 |
|---|---|
| 0 | `IS_UNDEF` |
| 1 | `IS_NULL` |
| 2 | `IS_FALSE` |
| 3 | `IS_TRUE` |
| 4 | `IS_LONG` |
| 5 | `IS_DOUBLE` |
| 6 | `IS_STRING` |
| 7 | `IS_ARRAY` |
| 8 | `IS_OBJECT` |
| ... | ... |

## `struct _zend_string` (24 バイトヘッダ + 可変長)

zval が文字列型 (`IS_STRING`) のとき、`value.str` が指す先:

```c
struct _zend_string {
    zend_refcounted_h gc;    // 8B  refcount:4 + type_info:4
    zend_ulong        h;     // 8B  DJBX33A hash
    size_t            len;   // 8B  バイト長
    char              val[1];// 可変 (flex array)、NUL 終端 + alignment
};
```

`gc.type_info` の下位ビットに `IS_STR_INTERNED` / `IS_STR_PERMANENT` 等のフラグ
が立ちます。特に **IMMUTABLE 扱いの 0x40** は「GC 対象外、refcount いじらない」
の意味。

## `struct _zend_op_array` (オリジナル: 数百バイト)

opcode 本体を包む上位コンテナ。実体は非常に大きく、抜粋するとこんな構造:

```c
struct _zend_op_array {
    /* Common fields with zend_internal_function */
    zend_uchar type;
    zend_uchar arg_flags[3];
    uint32_t fn_flags;
    zend_string *function_name;
    zend_class_entry *scope;
    zend_function *prototype;
    uint32_t num_args;
    uint32_t required_num_args;
    zend_arg_info *arg_info;
    HashTable *attributes;
    uint32_t T;
    /* op_array specific */
    uint32_t *refcount;
    uint32_t last;
    zend_op *opcodes;       // ← opcodes 配列へのポインタ
    int last_var;
    uint32_t T_liveranges;
    zend_string **vars;     // CV 変数名
    int last_literal;
    uint32_t num_dynamic_func_defs;
    zval *literals;         // ← literals 配列へのポインタ
    int cache_size;
    void **run_time_cache;
    zend_string *filename;
    uint32_t line_start;
    uint32_t line_end;
    zend_string *doc_comment;
    /* ... */
};
```

数十個のフィールド、多数のヒープポインタ、runtime cache、attributes、ライブ
ラリバージョンによって微妙にメンバーが増減。

---

# nesphp の改変点

上記を **6502 の 2KB RAM + 32KB PRG-ROM** で動かすために、以下を変更しています。
方針は **「ROM 側は可能な限り Zend 互換レイアウトを保つ、RAM 側は独自形式で
いい」** (L3 忠実度)。

## 改変 1: `handler` ポインタを削除 (32B → 24B)

```
Zend 原本           nesphp
offset  field       offset  field
  0     handler (8B)  ---   (削除)
  8     op1          0      op1
 12     op2          4      op2
 16     result       8      result
 20     extended_v  12      extended_value
 24     lineno      16      lineno
 28     opcode      20      opcode
 29     op1_type    21      op1_type
 30     op2_type    22      op2_type
 31     result_type 23      result_type
```

**理由**: `handler` は **ホスト側 (x86/ARM) C 関数へのポインタ**なので、6502
には 1 ビットも意味がない。opcache が handler をリゾルブするのはロード時だけ
で、構造上は「次の fetch で opcode バイトを見て dispatch」と等価なので、
**情報ロスなしで削れる**。

6502 VM は opcode バイト (offset 20) を読んで 16bit `JMP` 先を切り替えるだけ
の dispatch loop を持つので、「handler 呼び出しが事前に計算された NES 版」と
解釈できます。Zend が handler ポインタを**埋め込んでいた理由 (dispatch 速度)**
と、6502 が**埋め込めない理由 (16bit バスでは関数ポインタを runtime に扱い
にくい)** が対照的で、構造的な違いが面白いところです。

**フィールドオフセットを全てキープ**しているのがポイント: Zend では op1 が
offset 8、nesphp では offset 0 ですが、それ以降のフィールド間相対位置
(op1→op2=+4, op1→opcode=+20, etc.) は完全一致。VM 側のオフセット定数は
「Zend のフィールドオフセット - 8」で機械的に算出可能です。

## 改変 2: `IS_LONG` を 16 bit に narrow

| | Zend 原本 | nesphp |
|---|---|---|
| `value.lval` | int64 (64bit build) | 下位 16 bit のみ使用、符号拡張 |
| 範囲 | `-9.2×10^18 .. +9.2×10^18` | `-32768 .. +32767` |
| 範囲外時 | そのまま動く | **serializer が compile error** |

**理由**: 6502 で 64bit 演算は 1 操作で 8 バイト × 多数命令 → ROM 数百バイト
の乗算・除算ルーチン。16bit に絞れば ADD/SUB は 6-8 命令で済む。

zval の物理レイアウトは **16B のまま変えていない**ので、`value` union の
下位 2 バイトだけを nesphp は見る。上位 6 バイトは ROM に残りますが VM は
無視します (Zend 互換を維持するための「空白」)。

## 改変 3: `IS_DOUBLE` / `IS_ARRAY` / `IS_OBJECT` を未対応化

serializer がこれらの literal を検出したら即 compile error。

| type | ROM 側に出たら | 理由 |
|---|---|---|
| `IS_DOUBLE` | compile error | softfloat ルーチン 1-2KB は重すぎ |
| `IS_ARRAY` | compile error | `HashTable` 56B + bucket 36B が 2KB RAM に入らない |
| `IS_OBJECT` | compile error | 同上、`HashTable` を内包 |

`zval` の type ID 番号は Zend と同じ値を使うので、「将来やりたくなったら番号の
衝突なく足せる」穴は残しています。

## 改変 4: `value.str` の意味を「ポインタ」→「ROM オフセット」に

Zend 原本:
```
zval.value.str = zend_string * (ホストアドレス空間内の 64bit ポインタ)
```

nesphp:
```
zval.value.str = uint16 のバイトオフセット (ops.bin 先頭起点)
```

8 バイトの `value` 欄のうち **下位 2 バイト**だけを使い、残り 6 バイトは 0。
VM 側は `LDA value.str; ADC #<OPS_BASE` で絶対アドレスに復元します。

**理由**: 6502 には 64bit ポインタはおろか 32bit アドレス空間もない。uint16
で ROM 先頭からのオフセット持てば十分。`zval` の 16B レイアウトは変えずに、
値の**意味**だけ差し替えています。

## 改変 5: `zend_string.hash` を 0 固定

Zend 原本: `DJBX33A` で計算した 64bit ハッシュを `h` フィールドに埋める。
nesphp: 常に 0。

**理由**: nesphp は HashTable を持たないので、hash が読まれる文脈がない
(配列キーでも、string interning でも使わない)。計算コストゼロ、ROM 領域
そのままで 8 バイトのゴミが残るだけ。Zend 互換を優先してフィールドは残して
います。

## 改変 6: `gc.refcount` を 0 固定、`type_info` を `IMMUTABLE` (0x40)

全ての `zend_string` は **ROM 上のイミュータブル**なので、refcount 操作は
意味がない。Zend 原本でも `IS_STR_PERMANENT` や `IMMUTABLE` の文字列は
refcount を触らないので、この扱いは「Zend における CONST 文字列」と同じ動作
です。

## 改変 7: `op_array` ヘッダの完全置換

Zend 原本の `zend_op_array` は数百バイトの巨大構造体 (filename, function_name,
scope, arg_info, run_time_cache, attributes, ...)。これを 6502 にそのまま持ち
込むのは非現実的なので、**16 バイトの独自ヘッダに置き換え**ました:

```
offset  size  field
  0     2     num_opcodes
  2     2     literals_off
  4     2     num_literals
  6     2     num_cvs
  8     2     num_tmps
 10     1     php_version_major
 11     1     php_version_minor
 12     4     reserved
```

Zend 互換性は **zend_op 本体と zval / zend_string まで**で切り、コンテナ
(op_array) は独自。この線引きが nesphp が自称する「L3」の本当の境界線です
(L4 だと op_array も Zend 互換にしたくなるが、不可能)。

**`php_version_major/minor` だけは独自追加**: PHP マイナー版で opcode 番号が
動くので、VM 起動時に 8.4 でなければ halt する version-lock 用のガード値。
Zend 原本には**対応物がない** (実行時の PHP は自分のバージョンを知っているので
不要) けれど、nesphp では ROM と VM がビルド時点でロックされるので必須。

## 改変 8: RAM 上の zval 表現を 16B → 4B tagged value に

これは ROM レイアウトの話ではなく **runtime 側の改変**ですが、重要なので
書きます。

Zend 原本は execute_data の CV / TMP / VAR スロットを 16B zval のまま持ちます。
nesphp は 2KB RAM 制約のため、**4 バイトの tagged value** に圧縮:

```
byte 0: type ID (TYPE_LONG / TYPE_STRING / TYPE_TRUE / ...)
byte 1-2: payload 下位 16 bit (IS_LONG 値 or zend_string ROM offset)
byte 3: extra (未使用)
```

VM の `resolve_op1` / `resolve_op2` ルーチンが、Zend レイアウトの ROM から
読んで 4B 版に正規化する変換層になっています。結果として:

- **ROM (ops.bin)**: Zend の 16B zval レイアウトのまま
- **RAM (`$0400`-`$05FF`)**: 4B tagged value の独自形式

「ROM を見れば Zend、RAM を見れば nesphp」の二面性。[02-ram-layout](./02-ram-layout.md)
で RAM 側の詳細、[10-devlog](./10-devlog.md)「各フェーズ横断の学び」に経緯が
あります。

## 改変 9: カスタム opcode 帯の追加 (0xF0-0xF6)

これは「改変」というより「拡張」。Zend が使っていない 0xE0-0xFF 帯に nesphp
独自命令 7 個を詰めて、serializer が `fgets()` / `nes_*()` の関数呼び出し
パターンを畳み込む先としています (`NESPHP_FGETS=0xF0` 等)。

構造体レイアウトには触らず、`opcode` バイトの番号を増やしているだけ。VM 側
の dispatch は「標準 Zend opcode もカスタムも同じ main_loop の `CMP` 連鎖で
分岐」という統一扱いです。番号の一覧は [04-opcode-mapping](./04-opcode-mapping.md)
参照。

## 改変 10: `zend_string` 構造体の省略 (L3S 限定)

**この改変は on-NES コンパイラ経路 (L3S) のみ**に適用される。ホスト
`serializer.php` 経路 (L3) は従来通り `zend_string` 24B ヘッダを ROM に焼く。

L3S では文字列リテラルを表現する `zend_string` 構造体を持たず、zval の
`value` フィールドに (ROM offset, length) を直接埋め込みます:

```
L3 (host):
  zval.value.str (8B) → ROM 内 zend_string (24B header + val[] + null)
                        └─ offset 16 に len
                        └─ offset 24 から val[]

L3S (on-NES):
  zval.value bytes 0-1 → ROM 内 val[] 先頭 (OPS_BASE 相対 16bit offset)
  zval.value bytes 2-3 → length (16bit)
  zend_string ヘッダは存在しない
```

**理由**: L3S は PHP ソースを生の ASCII で ROM に焼くので、文字列リテラルの
val[] は**既にソース中の `"..."` の内側として ROM 上に存在する**。追加で 24B
ヘッダを焼いても、そのヘッダ内の `len` と `val[]` 本体は PHP ソース文字列
バイトの複製になるだけ。`strings hello.nes` で "HELLO, NES!" が 2 回見える
状態になり、「ROM = PHP ソースそのもの」というロマン軸を損ねていた。

省略による具体的効果:

| 観点 | L3 | L3S |
|------|-----|-----|
| `strings` 出現回数 | ソース 1 回 + プール 1 回 = 2 回 | ソース 1 回 |
| ROM 使用 | PHP ソース + 24B header × 文字列数 + 本体複製 | PHP ソース のみ |
| VM `echo_string` | zend_string ヘッダ navigate (LDY #16 / ADC #24) | 4B tagged 直読み (simpler) |
| L3 忠実度 | 完全 | 部分逸脱 (zend_string 非使用) |
| zval 16B レイアウト | 維持 | 維持 (value 共用体の**意味**だけ変更) |

4B tagged value (RAM) も変わります: byte 3 が L3 では未使用、L3S では
**IS_STRING 時の length** に意味が付く ([02-ram-layout](./02-ram-layout.md))。

`vm/nesphp.s` の文字列関連ハンドラ (`echo_string` / `vec_string` /
`handle_nesphp_nes_put` / `handle_nesphp_nes_puts`) は L3S に合わせて
書き換えられました。L3 (host 経路) も同じバイナリを読めるかは、serializer 側で
16B zval の bytes 2-3 に length を書く変更が必要 (host 経路の今後の保守方針
は未決、[13-compiler](./13-compiler.md) と `serializer.php` の同期は M-E 完了時
に判断)。

spec の単一の真実は [13-compiler](./13-compiler.md)、byte-level の厳密仕様は
そちらを参照。

---

# まとめ: 何が残って何が変わったか

| 対象 | 原本 Zend | nesphp | 互換度 |
|---|---|---|---|
| `zend_op` のサイズ | 32B | 24B | 先頭 8B (handler) だけ除去、残り**完全オフセット互換** |
| `zend_op` の各フィールド意味 | そのまま | そのまま | ✅ byte-for-byte |
| `zval` サイズ | 16B | 16B | ✅ |
| `zval.value` の解釈 | 8 バイト分の union | 下位 2 バイトのみ使用 | 下位使用、上位は 0 埋め |
| `IS_LONG` 精度 | 64bit | 16bit narrow | 意味縮小 |
| `IS_DOUBLE` / `IS_ARRAY` / `IS_OBJECT` | サポート | compile error | 削除 |
| `zend_string` ヘッダ | 24B | L3: 24B / **L3S: 省略** | L3 レイアウト互換 / L3S は zval に直接 (offset, length) |
| `zend_string.hash` | 計算 | L3: 0 固定 / L3S: — | L3 レイアウト互換、値は無意味 |
| `zend_string.val[]` | UTF-8 等 | ASCII のみ | 文字コード制限 |
| `zend_op_array` ヘッダ | 数百バイト | 16B 独自 | ❌ **完全置換** |
| CV / TMP slot (RAM) | 16B zval | 4B tagged value | ❌ 別形式 |
| 4B tagged value byte 3 | — | L3: 未使用 / **L3S: IS_STRING 時 length** | L3S 専用の意味付け |
| 独自 opcode | — | 0xF0-0xF9 追加 | Zend 未使用帯を借用 |

結局、nesphp が Zend 互換を主張できる**核心**は:

1. `zend_op` の **24B 構造** (`handler` 除去版) が Zend と同じフィールド
   オフセットで ROM に並んでいる
2. `zval` 16B レイアウトが保たれている (中身の使い方は縮退)
3. `zend_string` ヘッダの 24B レイアウトが保たれている
4. opcode 番号 (`0x88 = ZEND_ECHO` 等) が PHP 8.4 と一致

この 4 点のおかげで:

- `xxd -g 1 build/hello.nes | grep '88 01 00 00'` で ZEND_ECHO の byte 列が
  見える
- `strings build/hello.nes | grep HELLO` で文字列本体がそのままヒット
- PHP 8.4 の `zend_vm_opcodes.h` を直接見れば nesphp の命令番号が分かる

というロマンが成立している、という構図です。逆に、op_array 上位コンテナや
RAM 上の zval は実装都合で割り切って置き換えている、というのが nesphp の
リアルな設計線引きです。

---

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — この対比表の「nesphp 側」の厳密な byte レベル仕様
- [02-ram-layout](./02-ram-layout.md) — 改変 8 の 4B tagged value 詳細 (L3S の byte 3 も記載)
- [04-opcode-mapping](./04-opcode-mapping.md) — Zend opcode 番号 + nesphp カスタム opcode の一覧
- [10-devlog](./10-devlog.md) — L1 / L3 / L4 の忠実度選択や各フェーズの設計判断の経緯
- [11-chr-banks](./11-chr-banks.md) — CNROM マッパー昇格 (ROM レイアウトとは別軸の改変)
- [13-compiler](./13-compiler.md) — L3S (on-NES コンパイラ) の単一の真実、改変 10 の詳細
