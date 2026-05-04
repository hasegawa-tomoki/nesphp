# 01. L3 ROM バイナリフォーマット

[← README](./README.md) | [← 00-overview](./00-overview.md) | [→ 02-ram-layout](./02-ram-layout.md)

このドキュメントは **シリアライザ (`serializer.php`) と 6502 VM の両方が参照する単一の真実**。仕様がブレるとビルドが壊れるので、変更時は必ずこのファイルを先に更新すること。

## 方針

Zend 内部の `zend_op` (32B) から `handler` (8B) と `lineno` (4B) を除き、各 znode_op union (4B) を VM が実際に読む下位 2B のみに圧縮した **12B 構造体** として PRG-RAM に焼く。literals は Zend の 16B `zval` レイアウトをそのまま保持。6502 VM は `ZOP_*` 定数で参照する (`vm/nesphp.s`)。

旧 24B レイアウト (Zend と同じオフセットのまま `handler` のみ除去) は ROM サイズ制約 (PRG-RAM bank 0 の 8KB) を圧迫したため、後述 §2 の通り 12B に再圧縮した。

「なぜこの形なのか」「Zend 原本からの改変点 9 項目」は [12-zend-diff](./12-zend-diff.md) を参照。本ファイルは**現行の byte レベルの厳密仕様**にフォーカスする。

参考 (上流の定義):
- [php-src Zend/zend_compile.h](https://github.com/php/php-src/blob/master/Zend/zend_compile.h) — `struct _zend_op` `union znode_op` `IS_CONST` 等
- [php-src Zend/zend_types.h](https://github.com/php/php-src/blob/master/Zend/zend_types.h) — `struct _zval_struct` `struct _zend_string`
- [php-src Zend/zend_vm_opcodes.h](https://github.com/php/php-src/blob/master/Zend/zend_vm_opcodes.h) — opcode 定数

---

## 1. op_array ヘッダ (先頭 16B)

```
offset  size  field               意味
0       2     num_opcodes         op 数
2       2     literals_off        literals 配列先頭の ROM オフセット (op_array 起点)
4       2     num_literals        literal 数
6       2     num_cvs             CV (コンパイル済みローカル) スロット数
8       2     num_tmps            TMP スロット数
10      1     php_version_major   version lock 確認用 (必ず 0x08)
11      1     php_version_minor   version lock 確認用 (必ず 0x04)
12      4     (reserved, 0 埋め)
```

6502 VM は起動時にこのヘッダを読み、`php_version_major/minor` が 8.4 でなければ即座に halt (画面にエラー表示) する。

---

## 2. zend_op (12B, NESPHP 圧縮レイアウト)

Zend `struct _zend_op` から `handler` (8B) と `lineno` (4B) を除き、各 znode_op
union (4B) を **下位 2B のみ** に圧縮した独自レイアウト。VM が 16-bit address
space に閉じてるので各 union の上位 2B は常に 0 で、保持しても意味がない:

```
offset  size  field              元 Zend での型                    備考
0       2     op1                znode_op union → 下位 2B          constant / var / num / jmp_offset
2       2     op2                znode_op union → 下位 2B
4       2     result             znode_op union → 下位 2B
6       2     extended_value     uint32_t       → 下位 2B
8       1     opcode             zend_uchar                        ★ Zend 互換番号 ([04-opcode-mapping](./04-opcode-mapping.md) 参照)
9       1     op1_type           zend_uchar                        下記 operand type 表
10      1     op2_type           zend_uchar
11      1     result_type        zend_uchar
```

オフセット定数は `vm/nesphp.s` の `ZOP_*` で集中管理。

### 旧レイアウト (24B、移行前) — 参考

PRG-RAM bank 0 が op_array + literals + STR_POOL + ARR_POOL を全部抱えていた
時代に使っていた、Zend と同じオフセットを保つ素朴な配置:

```
offset  size  field              Zend での型                       備考
0       4     op1                znode_op union                    constant / var / num / jmp_offset
4       4     op2                znode_op union
8       4     result             znode_op union
12      4     extended_value     uint32_t
16      4     lineno             uint32_t                          デバッグ用
20      1     opcode             zend_uchar
21      1     op1_type           zend_uchar
22      1     op2_type           zend_uchar
23      1     result_type        zend_uchar
```

旧 → 新の変更点:
- lineno (offset 16-19) を削除 → -4B
- 各 znode_op を 4B → 2B に圧縮 (上位 2B は常時 0 だった) → -8B
- 合計 24B → 12B (op_array サイズ半減、tetris.php で 97.8% → 52.8%)
- VM ハンドラ側は `ZOP_*` 定数でオフセットを参照するだけなので、再度
  圧縮 / 拡張する場合も定数 1 箇所の更新で完結する

### operand type (Zend `IS_CONST` 等、`Zend/zend_compile.h`)

| 値 | 名前 | 意味 |
|----|------|------|
| 0x00 | IS_UNUSED | 使用しない |
| 0x01 | IS_CONST | op*.constant がリテラル配列へのバイトオフセット |
| 0x02 | IS_TMP_VAR | op*.var が TMP スロット番号 |
| 0x04 | IS_VAR | op*.var が VAR スロット番号 |
| 0x08 | IS_CV | op*.var が CV (compiled variable) スロット番号 |

### CONST オペランドのポインタ解決

Zend 実行時は `op1.constant` が **ホストメモリ上の literals 配列へのバイトオフセット** (x64 実行環境で計算された値)。シリアライザはこれを **NES ROM 内の `literals_off` 起算のバイトオフセット** に書き換える。

- 例: Zend の `op1.constant = 0` (最初の literal) → ROM 内でも `0` (literals_off + 0 = literals[0])
- 例: Zend の `op1.constant = 16` (2 番目の literal) → ROM 内でも `16` (literals_off + 16 = literals[1])

「意味」は保たれたまま「指す先」だけ NES 向けに解決される、という思想。Zend の 16B 単位の literals 配列と 6502 VM の見方が一致するので、オフセットはそのまま使える。

### 未実装 opcode の扱い

serializer が未対応の opcode を検出した場合は compile error。VM 側では全 opcode が `handle_unimpl` (画面に opcode 番号を表示して halt) にフォールバックする。

---

## 3. literals[] (1 要素 = 16B zval)

Zend `struct _zval_struct` の 16B レイアウトをそのまま保持:

```
offset  size  field              備考
0       8     value union        IS_LONG:   lval (little-endian 8B, 下位 2B 有効)
                                 IS_STRING: str (ROM offset を下位 2B、残り 0 埋め)
                                 IS_TRUE/FALSE/NULL: 未使用
8       4     u1.type_info       下位 1B = type ID ([02-ram-layout](./02-ram-layout.md))
12      4     u2                 0 埋め (Zend ではキャッシュスロット等)
```

### type ID (Zend `zend_types.h` と互換)

| 値 | 名前 | 意味 |
|----|------|------|
| 0 | IS_UNDEF | 未定義 |
| 1 | IS_NULL | null |
| 2 | IS_FALSE | false |
| 3 | IS_TRUE | true |
| 4 | IS_LONG | 整数 (16bit に narrow) |
| 5 | IS_DOUBLE | **未対応** (serializer で compile error) |
| 6 | IS_STRING | 文字列 (ROM 内 zend_string への offset) |
| 7 | IS_ARRAY | **未対応** (同) |
| 8 | IS_OBJECT | **未対応** (同) |

---

## 4. zend_string (24B ヘッダ + content)

**注記**: この節は **L3 (host `serializer.php` 経路)** の ROM レイアウトを記述する。**L3S (on-NES コンパイラ経路、spec/13-compiler.md) では文字列リテラルは zend_string を使わず**、zval の value フィールドに (ROM offset, length) を直接埋め込む。L3S の詳細は [13-compiler](./13-compiler.md)、設計意図は [12-zend-diff](./12-zend-diff.md) 改変 10 参照。

Zend `struct _zend_string` の先頭レイアウトを保持:

```
offset  size  field              備考
0       4     gc.refcount        0 (immutable)
4       4     gc.type_info       GC_IMMUTABLE 相当 (0x40 等、定数を決め打ち)
8       8     h                  hash (0 埋めで可)
16      8     len                下位 2B のみ有効、残り 0 埋め
24      N     val[len]           ASCII 文字列本体
24+len  1     (null terminator)  Zend の C 互換のため
```

- **文字列本体は ASCII 限定**。UTF-8 やマルチバイトは serializer で compile error
- CHR-ROM のタイル配置を「タイル番号 = ASCII コード」にしているので、`val[]` のバイトはそのまま nametable に書き込める ([06-display-io](./06-display-io.md))

---

## 5. 具体 hex dump 例

入力: `<?php echo "HELLO, NES!";`

新フォーマット (12B/op):

```
Offset     Bytes                                             ASCII
---------  ------------------------------------------------  ----------------
00000000   4e 45 53 1a 04 00 10 08 00 00 09 07 00 00 00 00   NES.............   iNES ヘッダ (NES 2.0、MMC1 / mapper 1, SXROM)
00000010   [ VM 6502 asm ~16KB ... ]                                             PRG bank 0
...
                                                             ↓ op_array セクション (PRG-RAM bank 0)
00006000   02 00 28 00 02 00 00 00 00 00 08 04 00 00 00 00   ..(.............    op_array header
                                                                                  num_ops=2
                                                                                  literals_off=$0028 (= header 16B + ops 24B)
                                                                                  num_literals=2
                                                                                  num_cvs=0, num_tmps=0
                                                                                  php_version=8.4

00006010   00 00 00 00 00 00 00 00 88 01 00 00               ............        op[0] ZEND_ECHO
                                                                                   op1=$0000 (literal[0]),
                                                                                   opcode=0x88=136,
                                                                                   op1_type=CONST(1)

0000601C   10 00 00 00 00 00 00 00 3e 01 00 00               ........>...        op[1] ZEND_RETURN
                                                                                   op1=$0010 (literal[1]),
                                                                                   opcode=0x3e=62,
                                                                                   op1_type=CONST(1)

00003F40   50 3f 00 00 00 00 00 00 06 00 00 00 00 00 00 00   P?..............    literals[0] zval STRING
                                                                                  value.str → $3f50
                                                                                  u1.type = IS_STRING(6)

00003F50   01 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00   ................    literals[1] zval LONG 1
                                                                                  value.lval = 1
                                                                                  u1.type = IS_LONG(4)

00003F60   00 00 00 00 40 00 00 00 00 00 00 00 00 00 00 00   ....@...........    zend_string ヘッダ
                                                                                  refcount=0,
                                                                                  gc.type_info=IMMUTABLE
                                                                                  hash=0
00003F70   0b 00 00 00 00 00 00 00 48 45 4c 4c 4f 2c 20 4e   ........HELLO, N    len=11, "HELLO, N
00003F80   45 53 21 00                                       ES!.                "ES!\0"
...
00010010   [ PRG bank 1 ($8000-$BFFF when bank 1 mapped) ]                       CHRDATA segment
                  4 × 4KB CHR セット (起動時の bulk transfer 元)
                  set 0: 通常フォント / set 1: インバース / set 2-3: 拡張枠
00018010   [ PRG bank 2 (16KB、予約)、PRG bank 3 ($C000-$FFFF, CODE 固定) ]
```

ヘッダの `04 00 10 08 00 00 09 07` は **NES 2.0** 形式の MMC1 (mapper 1, SXROM):
PRG-ROM = 4 × 16KB = 64KB、CHR-ROM = 0 (= CHR-RAM 8KB を申告)、Flags 7 = `08`
(bit 2-3 = `10` → NES 2.0 marker)、byte 10 = `09` (PRG-RAM = 64 << 9 = 32KB
volatile)、byte 11 = `07` (CHR-RAM = 64 << 7 = 8KB volatile)。Flags 6 上位 nibble
= 1 → mapper 1。

PRG-RAM 32KB の bank 配置: bank 0 = op_array + literals、bank 1 = ARR_POOL、
bank 2 = STR_POOL、bank 3 = USER_RAM_EXT。詳細は [11-chr-banks](./11-chr-banks.md)
と [02-ram-layout § PRG-RAM](./02-ram-layout.md)。

**NES 2.0 ヘッダが必須な理由**: FCEUX は iNES 1.0 ヘッダだと PRG-RAM サイズを
8KB 固定として扱い MMC1 の bank 切替を無視する。NES 2.0 で 32KB を明示的に申告
することで bank 1-3 が物理的に独立した RAM ページとしてマップされる。

### 見どころ

- オフセット `$3F24` の `88` が `ZEND_ECHO` (Zend PHP 8.4.6 の数値 136)
- オフセット `$3F3C` の `3e` が `ZEND_RETURN` (62)
- `strings hello.nes` で `HELLO, NES!` がヒット
- literals[0] の `50 3f 00 00` が `$3f50` へのオフセット参照 (ポインタ解決済み)

---

## 6. エンディアン / アラインメント

- 全フィールド **little-endian** (6502 に合わせる)
- パディング: Zend の自然アライメントに従う (24B の `zend_op` は 4B 境界で揃う)
- zval の 8B union 値は 8B 境界に置くのが望ましいが、6502 はアライメント非対応なので必須ではない

---

## 関連ドキュメント

- [02-ram-layout](./02-ram-layout.md) — この ROM フォーマットを読み取る RAM 側の表現 (4B tagged value)
- [03-vm-dispatch](./03-vm-dispatch.md) — 6502 VM がこのレイアウトをどう読むか
- [04-opcode-mapping](./04-opcode-mapping.md) — opcode 番号一覧
- [09-verification](./09-verification.md) — この hex dump が実際に出ることの検証手段
