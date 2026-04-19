# 13. on-NES コンパイラ (self-hosted, L3S)

[← README](./README.md) | [← 12-zend-diff](./12-zend-diff.md)

この文書は **PHP ソースを NES 起動時に 6502 がコンパイルする**構成 (自己ホスト版) の単一の真実。`vm/compiler.s` と host 側 `tools/pack_src.php`、および VM 本体 (`vm/nesphp.s`) のうち文字列リテラル処理に関わる箇所はこの spec を参照する。

## 位置付け: 忠実度 L3S

[00-overview](./00-overview.md) の忠実度表に次の段を追加:

| 段階 | 内容 |
|------|------|
| L3  | ホスト側 `serializer.php` が Zend 互換の `zend_op 24B` / `zval 16B` / `zend_string 24B` を ROM に焼く。NES VM は Zend のフィールドオフセットを直読み |
| **L3S** | **PHP ソースを ROM に焼き、起動時に 6502 コンパイラが PRG-RAM に `zend_op 24B` / `zval 16B` を emit する。zend_string 構造体は持たず、`value` フィールドに (ROM offset, length) を直接埋め込む** |

L3S は L3 から「`zend_string` を使わない」という 1 点だけ意図的に逸脱する。[12-zend-diff](./12-zend-diff.md) 改変 10 参照。

## ロマン軸

> 「実 php コマンドが吐いた opcode」という L3 のロマンは `make build/X.host.nes` で残す。L3S の**新しいロマン**は「**PHP ソースが ROM に焼かれ、電源 ON で 6502 自身が lex/parse/codegen して実行する**」。ホスト側 `pack_src.php` は「ファイル長を前置して ASCII チェックするだけ」まで縮退させ、**PHP 構文の知識は NES 側のみに存在する**ことを担保する。

---

## 全体フロー

```
[ホスト]
  examples/NAME.php
    │
    ▼ tools/pack_src.php (15 行)
    │   - <?php タグは剥がさない
    │   - ASCII チェックのみ
    │   - u16 src_len を前置
    │
  build/NAME.src.bin
    │
    ▼ ca65 + ld65
    │   - src.bin は .segment "PHPSRC" に焼かれる
    │   - VM + compiler.s は .segment "CODE"
    │
  build/NAME.nes


[NES 起動時]
  reset → PPU init → JSR compile_and_emit
    │
    ▼ compile_and_emit (vm/compiler.s)
    │   - cmp_init:          ZP 状態初期化
    │   - cmp_skip_php_tag:  先頭 `<?php` を消費
    │   - cmp_parse_program: 文法規則に従い opcode と zval を emit
    │   - cmp_finalize:      literals を最終位置に memcpy、header を書く
    │
  PRG-RAM $6000-$7FFF に op_array 完成
    │
    ▼ 既存 VM init / main_loop
  PHP プログラム実行
```

---

## ROM レイアウト ($8000 起点)

pack_src.php が出力する src.bin のバイトレイアウト:

```
offset   size  意味
0        2     src_len (u16, little-endian)。$8002 以降の ASCII バイト数
2        N     PHP ソース (生 ASCII、<?php タグ含む、src_len バイト)
```

N の上限は PRG bank 0 の残容量 = 16384 − 2 = 16382 バイト。それ以上は `pack_src.php` が compile error。

**何が入っていないか**:
- ❌ zend_string プール (旧試作版にはあったが撤廃)
- ❌ 関数名テーブル / 識別子インターン表
- ❌ lineno テーブル
- ❌ 任意のホスト側 pre-digest データ

---

## 16B zval の nesphp 独自解釈 (L3S)

`_zval_struct` の 16B フィールドオフセットは [01-rom-format](./01-rom-format.md) と完全一致。**意味**だけ L3S で変更:

| offset | size | L3 (host serializer) | L3S (NES コンパイラ) |
|--------|------|---------------------|----------------------|
| 0-1    | 2    | IS_STRING 時: ROM 内 `zend_string` への offset | **IS_STRING 時: ROM 内 val[] への OPS_BASE 相対 offset** |
| 2-3    | 2    | 未使用 (0 埋め) | **IS_STRING 時: 文字列長 (unsigned 16bit)** |
| 4-7    | 4    | 未使用 (0 埋め) | 未使用 (0 埋め) |
| 8      | 1    | u1.type_info 下位 1B = type ID | 同じ |
| 9-15   | 7    | 0 埋め | 0 埋め |

IS_LONG など他の type は L3 と同じ。

### value フィールドの意味 (IS_STRING 時)

```
L3 (host):  value.str → zend_string (24B ヘッダ) → offset 16 に len, offset 24 から val[]
L3S:        value 下位 2B → ROM 上の val[] 先頭 (OPS_BASE 相対)
            value 次の 2B → length
            (zend_string 構造体は存在しない)
```

VM はこの offset+length を読めば済むので、header/hash/refcount を辿るサイクルが消え、`echo_string` や `vec_string` が劇的に短くなる ([12-zend-diff](./12-zend-diff.md) 改変 10)。

---

## 4B tagged value (runtime) の拡張

[02-ram-layout](./02-ram-layout.md) の 4B tagged value は L3S で **byte 3 の意味**が変わる:

```
byte 0: type ID              (Zend 互換)
byte 1: payload lo
byte 2: payload hi
byte 3: IS_STRING 時 → length lo  ← L3S での新用途
        その他の type → 0 のまま
```

resolve_op1 / resolve_op2 の IS_CONST パスは、16B zval の offset 2 を読んで OP1_VAL+3 に格納する。IS_LONG 等では zval の offset 2 は 0 固定なので、byte 3 も 0 のまま。

CV / TMP スロット間の代入 (`ZEND_ASSIGN` / `ZEND_QM_ASSIGN`) は 4 バイト丸ごとコピーなので、length 情報はスロット経由で自動的に伝搬する。

---

## 対応文法 (2026-04-19 時点、M-A' + P1 + P2 + P3 実装済)

```ebnf
program      ::= "<?php" stmt* EOF
stmt         ::= echo_stmt | call_stmt | assign_stmt | while_stmt | if_stmt
echo_stmt    ::= "echo" expr ";"
call_stmt    ::= IDENT "(" args? ")" ";"
assign_stmt  ::= CV "=" expr ";"
while_stmt   ::= "while" "(" expr ")" "{" stmt* "}"
if_stmt      ::= "if" "(" expr ")" "{" stmt* "}"
expr         ::= add_expr (cmp_op add_expr)?
cmp_op       ::= "===" | "!==" | "==" | "!=" | "<"
add_expr     ::= primary (("+" | "-") primary)*
primary      ::= INT | STRING | CV | "true" | call_expr
call_expr    ::= IDENT "(" args? ")"       (現状 fgets(STDIN) のみ、戻り値 TMP)
args         ::= arg ("," arg)*
arg          ::= expr | "STDIN"
CV           ::= "$" IDENT
INT          ::= [0-9]+
STRING       ::= '"' [^"]* '"'             (エスケープ未対応)
IDENT        ::= [a-zA-Z_] [a-zA-Z0-9_]*
```

### トークン種別

| kind       | 入力 | 備考 |
|------------|------|------|
| `TK_EOF`   | (end) | |
| `TK_ECHO`  | `echo` | keyword (cln_ident が分類) |
| `TK_WHILE` | `while` | keyword |
| `TK_IF`    | `if` | keyword |
| `TK_TRUE`  | `true` | keyword、`IS_TRUE` zval として emit |
| `TK_IDENT` | `[a-zA-Z_]\w*` | キーワード以外の識別子 (関数名等) |
| `TK_STRING`| `"..."` | val[] は ROM 内に残る |
| `TK_INT`   | `[0-9]+` | 10 進、16bit signed narrow |
| `TK_CV`    | `$name` | compile variable |
| `TK_SEMI` / `TK_LPAREN` / `TK_RPAREN` / `TK_COMMA` / `TK_LBRACE` / `TK_RBRACE` | `; ( ) , { }` | |
| `TK_ASSIGN` | `=` | |
| `TK_PLUS` / `TK_MINUS` | `+` `-` | |
| `TK_LT` | `<` | |
| `TK_EQ2` / `TK_EQ3` | `==` / `===` | lexer が `=` の後ろを lookahead |
| `TK_NEQ2` / `TK_NEQ3` | `!=` / `!==` | `!` 単独はエラー |

### マイルストーン進行

| マイルストーン | 内容 | 状況 |
|---------------|------|------|
| **M-A'** | `<?php`、`echo "..."`、`;`、暗黙 return | ✅ |
| **P1** | intrinsic 呼出 (nes_cls/puts/chr_bg/chr_spr/bg_color/palette)、整数リテラル、STDIN | ✅ |
| **P2** | CV、`=` 代入、`+` `-`、echo $var、CV as intrinsic arg、**エラー画面表示** | ✅ |
| **P3 (M-C)** | `while { }`、`if { }`、比較演算 (`===` `!==` `==` `!=` `<`)、`$k = fgets(STDIN)`、`true` リテラル、backpatch stack | ✅ |
| 次 | `else` / `elseif`、`<=` / `>` / `>=`、`&&` / `||` / `!`、コメント、PRE_INC | 未着手 |
| 対象外 | 配列、オブジェクト、foreach、例外、double | L3 方針 |

### 生成される opcode (opcode 番号は PHP 8.4 準拠、[04-opcode-mapping](./04-opcode-mapping.md))

| 構文 | 発行 opcode |
|------|-------------|
| `echo expr;` | `ZEND_ECHO` (op1 = expr result) |
| 暗黙 `return` | `ZEND_RETURN` op1 = IS_LONG(1) literal |
| `$x = expr;` | `ZEND_ASSIGN` (op1 = CV, op2 = expr result) |
| `$a + $b` / `$a - $b` | `ZEND_ADD` / `ZEND_SUB` (result = 新 TMP) |
| `$a === $b` etc. | `ZEND_IS_IDENTICAL` / `ZEND_IS_NOT_IDENTICAL` / `ZEND_IS_EQUAL` / `ZEND_IS_NOT_EQUAL` / `ZEND_IS_SMALLER` (result = 新 TMP) |
| `while (c) {}` | `ZEND_JMPZ c, end` (backpatched); body; `ZEND_JMP top` |
| `if (c) {}` | `ZEND_JMPZ c, end` (backpatched); body |
| `nes_xxx(...)` | 対応する `NESPHP_NES_*` (0xF1-0xF9) |
| `fgets(STDIN)` 単独 | `NESPHP_FGETS` result_type = IS_UNUSED |
| `$k = fgets(STDIN)` | `NESPHP_FGETS` result = TMP、`ZEND_ASSIGN $k, TMP` |

### 比較式の精度

`expr` は左結合の 2 階建てで、**比較は非連鎖** (`$a < $b < $c` は許容しない、コンパイル時エラー)。優先順位は `+ -` > `== === != !== <`。比較結果は `ZEND_IS_*` が `IS_TRUE` / `IS_FALSE` を TMP に書き、`if` / `while` がその TMP を JMPZ の op1 にする。

### while / if のコード生成

backpatch スタック (ZP 16B = 最大 8 段ネスト) に「後で埋めるべき op2 フィールドの PRG-RAM 絶対アドレス」を push する。ブロック終端で `cmp_bp_pop_patch` が現在の `CMP_OP_COUNT` をその位置に 16bit で書き込む。

```
while (cond) { body }                if (cond) { body }
                                     
LOOP_TOP:    (op_count を退避)       JMPZ cond, END   (backpatch push)
  JMPZ cond, END  (backpatch push)   body
  body                               END:   (backpatch pop + CMP_OP_COUNT を書く)
  JMP LOOP_TOP    (退避値を埋める)
END:   (backpatch pop)
```

`while` の `LOOP_TOP` は 6502 ハードウェアスタックに PHA × 2 で退避 (ネスト対応)。`JMP` は op1 に op_index を 16bit で直接持つ (op1_type = IS_UNUSED)。

---

## WRAM 共用契約 (compile phase vs runtime phase)

2KB WRAM ($0000-$07FF) を時間的に分離して使う。compile_and_emit が戻った後、VM main_loop は既存の割当で動く。

### コンパイル中にのみ使う ZP (P3 時点で ~55 バイト)

| label | size | 用途 |
|-------|------|------|
| `CMP_SRC_PTR` | 2 | 現在のソース読み出し位置 (ROM $8002-$BFFF 範囲) |
| `CMP_SRC_END` | 2 | ソース終端 (one-past-last) |
| `CMP_LINE` / `CMP_COL` | 各 2 | 行/列 (エラー表示用、1-origin) |
| `CMP_OP_HEAD` | 2 | 次に emit する zend_op の PRG-RAM アドレス ($6010..) |
| `CMP_LIT_HEAD` | 2 | 次に emit する zval の一時 PRG-RAM アドレス ($7000..) |
| `CMP_OP_COUNT` / `CMP_LIT_COUNT` | 各 2 | emit 済みカウント |
| `CMP_TMP_COUNT` | 1 | 発行済 TMP スロット数 (算術 / 比較 / fgets result) |
| `CMP_CV_COUNT` | 1 | 発行済 CV スロット数 |
| `CMP_TOK_KIND` | 1 | 現在のトークン種別 |
| `CMP_TOK_PTR` | 2 | トークン開始 ROM アドレス (STRING/IDENT/CV) |
| `CMP_TOK_LEN` | 1 | トークン長 (1B、255 上限) |
| `CMP_TOK_VALUE` | 2 | TK_INT: パース結果の 16bit 値 |
| `CMP_INTRINSIC_ID` | 1 | intrinsic 番号 (流用: 二項演算の opcode 退避にも使う) |
| `CMP_ARG_COUNT` | 1 | 関数呼出の引数数 |
| `CMP_ARG_LITS` | 8 | 4 引数 × 2B、各 arg の operand 値 |
| `CMP_ARG_TYPES` | 4 | 各 arg の operand 型 |
| `CMP_ASSIGN_SLOT` | 1 | assign 中の LHS CV slot |
| `CMP_EXPR_TYPE` / `CMP_EXPR_VAL` | 1 / 2 | parse_expr の戻り operand |
| `CMP_LHS_TYPE` / `CMP_LHS_VAL` | 1 / 2 | 二項演算 LHS 退避 |
| `CMP_BP_TOP` | 1 | backpatch stack pointer |
| `CMP_BP_STACK` | 16 | 8 エントリ × 2B = patch 対象 PRG-RAM アドレス |

これらはコンパイル終了後に未使用。VM は触らない。

### CV シンボル表 (WRAM $0700-)

- エントリ 4B: `[len, name_ptr_lo, name_ptr_hi, pad]`
- `cmp_cv_intern` が線形探索 + 新規 alloc
- 最大 32 スロット (VM 側 CV 領域の予算と一致)
- ランタイムでは `$0700-$07FF` は予備なので aliasing 無し

### 作業エリア

- `$7000-$77FF`: コンパイル中、literal zval の一時バッファ (CMP_LIT_STAGE)。cmp_finalize で $6000 + literals_off に memcpy 後は未使用
- `$6000-$6FFF`: 最終レイアウト (header + opcodes + literals)。runtime は VM_PC / VM_LITBASE 経由で参照

### TMP0/TMP1/TMP2 の共有

`TMP0`, `TMP1`, `TMP2` (各 2 バイト、ZP) はコンパイル中も runtime もスクラッチ用に使う。compile_and_emit はランタイムが走る前に終わるので、重複でも問題ない (値の受け渡しは関数内完結)。

---

## 制約・制限事項

1. **PHP ソース先頭は `<?php` 必須**。省略はできない。タグ直後に空白類 1 文字以上が無くても OK (lexer がその後の echo / IDENT で区切る)
2. **non-ASCII**: **文字列リテラル内とコメント内は透過的に pass through**。それ以外の位置で non-ASCII バイトが出ると NES lexer が compile error (ERR L/C 画面表示)。pack_src.php にチェックなし。文字列内の UTF-8 バイト (例: 「あ」= 3B) はタイル ID として `echo` / `nes_puts` がそのまま PPU に流すので、ユーザ側で CHR タイルを用意する
3. **文字列は double-quoted のみ**、エスケープ (`\n` 等) 未対応
4. **文字列長 ≤ 255 バイト** (現行 `CMP_TOK_LEN` が 1 バイト)。UTF-8 日本語 (1 文字 = 3B) なら ~85 文字まで
5. **コメント対応済** (P3 以降): `//`, `#`, `/* */`。block コメント未閉は compile error
6. **ソース長上限 16382 バイト** (PRG bank 0 の 16KB − 2B ヘッダ)
7. **PRG-RAM 8KB** がコンパイル出力の上限 (opcode + literal zval、文字列は ROM 常駐)
8. **CV 最大 32 スロット**、**TMP 最大 64 スロット**、**関数引数 ≤ 4**、**関数呼出ネスト無し** (call expr は fgets のみ)
9. **比較式は非連鎖** (`$a < $b < $c` は compile error)
10. **`else` / `elseif` 未対応**、**`&&` `||` `!` 未対応**、**`<=` `>` `>=` 未対応**
11. **if / while のボディはブロック必須** (`{ }` 無しの単文ボディは未対応)
12. **ネスト深さ**: backpatch stack 8 段、6502 HW stack 256B、CV table 32 エントリ

---

## エラー処理 (P2 以降、実装済)

コンパイル失敗時は `show_compile_error` が nametable `$2160` (row 11, col 0) に

```
ERR L<line> C<col>
```

を書き、`PPUMASK` に BG 有効化ビットを立てて画面表示してから halt。`CMP_LINE` / `CMP_COL` は `cmp_advance1` が `LF` を検出するたびに `line++` / `col=1`、それ以外で `col++`。`cmp_advance_n` (5 文字の `<?php` skip 等) は `col += A` の近似更新 (LF を含まない前提)。

実装: `vm/compiler.s` の `show_compile_error`。既存の `print_int16` (`vm/nesphp.s:1521`) を再利用して数値を ASCII 化し `PPUDATA` にストリーム書き込み。

エラーメッセージの**種類分け (エラーコード)** は現状無し (単一のメッセージ)。将来、文法違反の種別ごとに短いエラーコードを追加する余地あり。

**ホスト側 pre-flight lint** (将来): `pack_src.php` 内で簡易構文チェック (ダブルクォート未閉じ等) を行い、ROM ビルド時にエラーを早期検出する選択肢。NES 上のエラー halt は保険として残す。

---

## コンパイル速度の目安

6502 @ 1.79MHz での推定値 (1KB PHP ソース):

- cmp_lex_next: 1 トークンあたり ~200 cycle
- 文字列 scan: 1 バイトあたり ~15 cycle
- emit_op24 / emit_zval: 1 回あたり ~500 cycle

1KB ソースで合計 ~80ms、4KB で ~250ms。電源 ON から VM main_loop 開始までのラグは体感で「一瞬の点滅」程度。

---

## 関連ドキュメント

- [00-overview](./00-overview.md) — 3 層アーキテクチャと忠実度 (L3S 追記予定)
- [01-rom-format](./01-rom-format.md) — ROM バイナリレイアウト (§4 に「L3S では zend_string 省略」を注記)
- [02-ram-layout](./02-ram-layout.md) — 4B tagged value (byte 3 = IS_STRING 時 length を追記)
- [04-opcode-mapping](./04-opcode-mapping.md) — intrinsic 一覧 (P1 で実装対象)
- [07-roadmap](./07-roadmap.md) — マイルストーン進行
- [12-zend-diff](./12-zend-diff.md) — Zend との対比 (改変 10: zend_string 省略を追記)
- `vm/compiler.s` — コンパイラ実装
- `tools/pack_src.php` — ソースパッカー
