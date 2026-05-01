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

## 対応文法 (2026-04-19 時点、M-A' + P1 + P2 + P3 + P4 + Q1-Q4 + R1-R3 実装済)

```ebnf
program      ::= "<?php" stmt* EOF
stmt         ::= echo_stmt | call_stmt | assign_stmt | inc_stmt | while_stmt
               | if_stmt | for_stmt
echo_stmt    ::= "echo" expr ";"
call_stmt    ::= IDENT "(" args? ")" ";"
assign_stmt  ::= CV "=" expr ";"
             |   CV "[" expr "]" "=" expr ";"  (配列の index 書換)
             |   CV "[" "]" "=" expr ";"        (配列への append)
             |   CV ("++" | "--") ";"      (post-inc/dec as stmt)
inc_stmt     ::= ("++" | "--") CV ";"      (pre-inc/dec as stmt)
while_stmt   ::= "while" "(" expr ")" body
if_stmt      ::= "if" "(" expr ")" body
for_stmt     ::= "for" "(" init? ";" cond? ";" update? ")" body
init         ::= assign_stmt body (without trailing ';' consumption) | inc_stmt | …
update       ::= expr                       (side-effect: $i++, --$j, etc.)
body         ::= "{" stmt* "}" | stmt      (single stmt 許可)
expr         ::= cmp_expr (("&&" | "||") cmp_expr)*
cmp_expr     ::= add_expr (cmp_op add_expr)?
cmp_op       ::= "===" | "!==" | "==" | "!=" | "<"
add_expr     ::= primary (("+" | "-" | "&" | "|" | "<<" | ">>") primary)*
primary      ::= INT | STRING | CV | "true" | call_expr
             |   ("++" | "--") CV           (prefix inc/dec in expr)
             |   CV ("++" | "--")           (postfix inc/dec in expr)
             |   CV ("[" expr "]")+         (チェーン読取、ネスト可: $a[i][j][k])
             |   "[" (expr ("," expr)*)? "]"  (配列リテラル、ネスト可、最大 15 要素)
call_expr    ::= IDENT "(" args? ")"        (fgets(STDIN) / nes_btn() / count($a) 等)
args         ::= arg ("," arg)*
arg          ::= expr | "STDIN"
CV           ::= "$" IDENT
INT          ::= [0-9]+ | "0" ("x"|"X") [0-9a-fA-F]+ | "0" ("b"|"B") [01]+
STRING       ::= '"' (char | escape)* '"'
escape       ::= "\x" hex2                  ; 任意 byte (0x00-0xFF)
             |   "\\"                        ; リテラル `\`
             |   "\""                        ; リテラル `"`
hex2         ::= [0-9a-fA-F]{2}
char         ::= [^"\\]                      (non-ASCII byte を含む)
IDENT        ::= [a-zA-Z_] [a-zA-Z0-9_]*    (ASCII のみ)
COMMENT      ::= "//" [^\n]* "\n"
             |   "#" [^\n]* "\n"
             |   "/*" ... "*/"              (non-ASCII OK)
```

### トークン種別

| kind       | 入力 | 備考 |
|------------|------|------|
| `TK_EOF`   | (end) | |
| `TK_ECHO`  | `echo` | keyword (cln_ident が分類) |
| `TK_WHILE` | `while` | keyword |
| `TK_IF`    | `if` | keyword |
| `TK_FOR`   | `for` | keyword |
| `TK_TRUE`  | `true` | keyword、`IS_TRUE` zval として emit |
| `TK_IDENT` | `[a-zA-Z_]\w*` | キーワード以外の識別子 (関数名等) |
| `TK_STRING`| `"..."` | 内容は decoded で PRG-RAM 内の string pool ($7800-$7FFF) に置かれ、zval は pool への OPS_BASE 相対 offset を持つ。`\xHH` / `\\` / `\"` のエスケープ対応 (それ以外の `\` で compile error)、non-ASCII byte は pass-through |
| `TK_INT`   | `[0-9]+` / `0x..` / `0b..` | 10 進 / 16 進 / 2 進、16bit signed narrow |
| `TK_CV`    | `$name` | compile variable |
| `TK_SEMI` / `TK_LPAREN` / `TK_RPAREN` / `TK_COMMA` / `TK_LBRACE` / `TK_RBRACE` | `; ( ) , { }` | |
| `TK_ASSIGN` | `=` | |
| `TK_PLUS` / `TK_MINUS` | `+` `-` | 単項 - は非対応 |
| `TK_INC` / `TK_DEC` | `++` / `--` | lexer が `+`/`-` の後ろを lookahead |
| `TK_LT` | `<` | |
| `TK_EQ2` / `TK_EQ3` | `==` / `===` | lexer が `=` の後ろを lookahead |
| `TK_NEQ2` / `TK_NEQ3` | `!=` / `!==` | `!` 単独はエラー |
| `TK_AMP` / `TK_PIPE` | `&` / `\|` | bitwise AND / OR |
| `TK_AMPAMP` / `TK_PIPEPIPE` | `&&` / `\|\|` | **論理 AND / OR (短絡評価)**。両オペランドを bool に正規化して 0/1 を返す |
| `TK_SL` / `TK_SR` | `<<` / `>>` | 16bit 論理左 / 算術右シフト。単体 `>` は未対応でエラー |
| `TK_LBRACKET` / `TK_RBRACKET` | `[` / `]` | 配列リテラル / 配列要素アクセス用 |

### マイルストーン進行

| マイルストーン | 内容 | 状況 |
|---------------|------|------|
| **M-A'** | `<?php`、`echo "..."`、`;`、暗黙 return | ✅ |
| **P1** | intrinsic 呼出 (nes_cls/puts/chr_bg/chr_spr/bg_color/palette)、整数リテラル、STDIN | ✅ |
| **P2** | CV、`=` 代入、`+` `-`、echo $var、CV as intrinsic arg、**エラー画面表示** | ✅ |
| **P3 (M-C)** | `while { }`、`if { }`、比較演算 (`===` `!==` `==` `!=` `<`)、`$k = fgets(STDIN)`、`true` リテラル、backpatch stack | ✅ |
| **P4 (コメント + non-ASCII)** | `//`, `#`, `/* */`、文字列内の non-ASCII byte pass through | ✅ |
| **Q1-Q4** | 残り intrinsic (nes_put / nes_sprite (1-sprite 版、後に W1 で nes_sprite_at に拡張) / nes_attr)、16 進リテラル `0x..`、`++` / `--` (PRE/POST INC/DEC)、`for` ループ、if/while の単文 body | ✅ |
| **R1** | リアルタイム入力: `nes_vsync()` (VBlank 同期 + sprite_mode 自動有効化) | ✅ |
| **R2** | `nes_btn()` を 0 引数化。コントローラ状態 (下位 1B = bitmask) を IS_LONG で返す | ✅ |
| **R3** | ビット演算子 `&` / `\|` (`ZEND_BW_AND` / `ZEND_BW_OR`)、2 進リテラル `0b..` | ✅ |
| **S1-S4** | 論理演算 `&&` / `\|\|` (短絡評価、JMPZ/JMPNZ + QM_ASSIGN パターン)、シフト `<<` / `>>` (`ZEND_SL` / `ZEND_SR`) | ✅ |
| **T1** | 文字列リテラルに `\xHH` / `\\` / `\"` エスケープ追加。decoded bytes を PRG-RAM pool ($7800-$7FFF) に書き zval は pool 内 offset を指す。本物の PHP 互換構文で任意 byte を埋めこめる (CHR タイル index 直接指定で非 ASCII テキストを扱うため) | ✅ |
| **U1** | 整数キー配列 MVP: `[expr,...]` リテラル + `$a[idx]` 読取 + `count($a)`。IS_ARRAY=7、2KB runtime array pool ($7000-$77FF)。ZEND_INIT_ARRAY / ZEND_ADD_ARRAY_ELEMENT / ZEND_FETCH_DIM_R / ZEND_COUNT opcode | ✅ |
| **V1-V4** | 配列: **書換 `$a[i] = v`** + **append `$a[] = v`** (ZEND_ASSIGN_DIM + ZEND_OP_DATA、2-op sequence)、**ネスト読取 `$a[i][j]...`** (FETCH_DIM_R チェーン)、**ネストリテラル `[[1,2],[3,4]]`** (CMP_ARR_* を stack で退避)。連想配列/foreach は未対応 | ✅ |
| **W1** | マルチスプライト: `nes_sprite_at($idx, $x, $y, $tile)` (4 引数、$idx は runtime int 可)、`nes_sprite_attr($idx, $attr)`。NESPHP_NES_SPRITE (0xF2) の意味を「OAM[0] 固定」→「OAM[$idx]」に拡張、result スロットを 3 番目の入力 ($y) として流用。NESPHP_NES_SPRITE_ATTR (0xFC) を新設 | ✅ |
| **W2** | `nes_rand()` (戻り値 IS_LONG) / `nes_srand($seed)`。16-bit Galois LFSR (周期 65535)。あわせて `$xs[$i] = $xs[$i] + 1` パターンの ASSIGN_DIM bug を修正 (RHS パースを ASSIGN_DIM emit より先にして、間に sub-op が挟まらないようにした) | ✅ |
| **W3** | parser 拡張: `else` / `elseif` チェーン、`<=` (新 ZEND_IS_SMALLER_OR_EQUAL handler)、`>` / `>=` (operand swap で `<` / `<=` に畳み込み)、括弧式 `(expr)`。あわせて `cmp_parse_expr` 入口/出口で CMP_LHS_VAL/TYPE / CMP_INTRINSIC_ID を 6502 stack に save/restore する修正 (`1 + (2 << 3)` 等の再帰 expr で外側 binop 状態が clobber されていた潜在 bug を解消) | ✅ |
| **W4** | `nes_putint($x, $y, $value)` (NESPHP_NES_PUTINT 0xFF)。5-char 右詰め unsigned int 表示 (スコア HUD 用)、3 引数全て runtime int 可。div_tmp0_by_10 の X clobber を回避するため Y register で loop counter を持つ | ✅ |
| 次 | `foreach`、単項 `-` / `!`、`^` (BW_XOR) | 未着手 |
| 対象外 | 配列、オブジェクト、foreach、例外、double | L3 方針 |

### 数値リテラル

PHP 準拠の 3 つの表記を実装 (全て `IS_LONG`、16bit signed narrow):

| 表記 | 例 | 意味 |
|------|-----|------|
| 10 進 | `42`、`255`、`0` | `[0-9]+` |
| 16 進 | `0x0F`、`0xFF`、`0X80` | `0x` / `0X` prefix + `[0-9a-fA-F]+` |
| 2 進 | `0b1010`、`0b10000000`、`0B11` | `0b` / `0B` prefix + `[01]+` |

**範囲**: 符号付き 16bit (`-32768 .. 32767`)。範囲外は未定義 (lexer が overflow を検出しない、下位 16bit のみが残る)。

**用途別推奨**:
- **ボタン mask**: 2 進 (`0b10000000` = A) が視覚的にわかりやすい
- **NES カラーコード**: 16 進 (`0x0F` = 黒、`0x30` = 白)
- **座標・カウンタ**: 10 進

例:
```php
$b = nes_btn();
if ($b & 0b10000000) { /* A */ }
nes_bg_color(0x0F);                   // 黒
$i = 0; while ($i < 10) { $i = $i + 1; }
```

### 生成される opcode (opcode 番号は PHP 8.4 準拠、[04-opcode-mapping](./04-opcode-mapping.md))

| 構文 | 発行 opcode |
|------|-------------|
| `echo expr;` | `ZEND_ECHO` (op1 = expr result) |
| 暗黙 `return` | `ZEND_RETURN` op1 = IS_LONG(1) literal |
| `$x = expr;` | `ZEND_ASSIGN` (op1 = CV, op2 = expr result) |
| `$a + $b` / `$a - $b` | `ZEND_ADD` / `ZEND_SUB` (result = 新 TMP) |
| `$a & $b` / `$a \| $b` | `ZEND_BW_AND` / `ZEND_BW_OR` (result = 新 TMP、IS_LONG) |
| `$a << $b` / `$a >> $b` | `ZEND_SL` / `ZEND_SR` (result = 新 TMP、16bit シフト) |
| `$a && $b` / `$a \|\| $b` | JMPZ/JMPNZ + QM_ASSIGN + JMP による短絡評価。result = 新 TMP (IS_LONG 0 or 1)。5 opcode emit/演算子 |
| `$a === $b` etc. | `ZEND_IS_IDENTICAL` / `ZEND_IS_NOT_IDENTICAL` / `ZEND_IS_EQUAL` / `ZEND_IS_NOT_EQUAL` / `ZEND_IS_SMALLER` (result = 新 TMP) |
| `$x++;` / `$x--;` (stmt) | `ZEND_POST_INC` / `ZEND_POST_DEC` result_type = IS_UNUSED |
| `++$x;` / `--$x;` (stmt) | `ZEND_PRE_INC` / `ZEND_PRE_DEC` result_type = IS_UNUSED |
| `$x++` / `$x--` (expr) | `ZEND_POST_INC` / `ZEND_POST_DEC` result = 新 TMP (旧値) |
| `++$x` / `--$x` (expr) | `ZEND_PRE_INC` / `ZEND_PRE_DEC` result = 新 TMP (新値) |
| `while (c) {}` | `ZEND_JMPZ c, end` (backpatched); body; `ZEND_JMP top` |
| `if (c) {}` | `ZEND_JMPZ c, end` (backpatched); body |
| `for (init; cond; upd) body` | init; `JMPZ cond, end`; `JMP body-start`; upd; `JMP loop_top`; body; `JMP upd-start`; end (double-JMP scheme) |
| `nes_xxx(...)` (10 種) | 対応する `NESPHP_NES_*` (0xF1-0xF9) / `NESPHP_FGETS` (0xF0) |
| `fgets(STDIN)` 単独 | `NESPHP_FGETS` result_type = IS_UNUSED |
| `$k = fgets(STDIN)` | `NESPHP_FGETS` result = TMP、`ZEND_ASSIGN $k, TMP` |
| `nes_vsync();` | `NESPHP_NES_VSYNC` (戻り値なし、sprite_mode 自動有効化 → NMI 待ち) |
| `nes_btn();` 単独 | `NESPHP_NES_BTN` (0 引数、result_type = IS_UNUSED、副作用のみ = read_controller) |
| `nes_btn()` (expr) | `NESPHP_NES_BTN` result = TMP (IS_LONG = buttons bitmask)。呼び出し側で `$b & mask` 等で検査 |
| `[expr, expr, ...]` | `ZEND_INIT_ARRAY` (op1 = 要素数 raw、result = 新 TMP) + 要素ごとに `ZEND_ADD_ARRAY_ELEMENT` (op1 = array TMP、op2 = element)。結果は IS_ARRAY TMP、pool 内 ptr 保持 |
| `$a[idx]` | `ZEND_FETCH_DIM_R` (op1 = CV array, op2 = index、result = 新 TMP)。element 16B zval を 4B tagged に展開 |
| `count($a)` | `ZEND_COUNT` (op1 = array、result = 新 TMP、IS_LONG = 要素数) |
| `$a[i] = v;` | `ZEND_ASSIGN_DIM` (op1=CV array, op2=index) + `ZEND_OP_DATA` (op1=value)。ハンドラは 2-op セットで array[i] に 16B zval 書込、count = max(count, i+1) |
| `$a[] = v;` | 上と同じだが op2_type = IS_UNUSED (append)。slot = 現在 count、書込後 count++ |
| `$a[i][j]...` | `ZEND_FETCH_DIM_R` を必要なだけチェーン emit。途中 TMP を次の op1 として再利用 |
| `[[1,2],[3,4]]` | 外側 INIT_ARRAY → 内側 INIT_ARRAY + ADD × 2 → 外側 ADD → ... (再帰、CMP_ARR_* の stack 退避で対応) |

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
- `$7800-$7FFF`: 文字列 pool (STR_POOL_BASE、2KB)。cln_string が decoded bytes をここに書き、zval の IS_STRING value は pool 内アドレスを指す OPS_BASE 相対 offset (= pool_addr - $6000 = $1800+)。runtime でもそのまま読み出される (memcpy しない)
- `$7000-$77FF`: runtime では **配列 pool** (ARR_POOL_BASE、2KB) に転用される。compile 中は CMP_LIT_STAGE として zval の一時置き場、cmp_finalize の memcpy 後は未使用になり、main_loop 突入前に ARR_POOL_HEAD を ARR_POOL_BASE にリセット。配列は header 4B (count, cap) + cap × 16B zval を追記型で alloc、GC 無し
- `$6000-$6FFF`: 最終レイアウト (header + opcodes + literals)。runtime は VM_PC / VM_LITBASE 経由で参照

### TMP0/TMP1/TMP2 の共有

`TMP0`, `TMP1`, `TMP2` (各 2 バイト、ZP) はコンパイル中も runtime もスクラッチ用に使う。compile_and_emit はランタイムが走る前に終わるので、重複でも問題ない (値の受け渡しは関数内完結)。

---

## 制約・制限事項

1. **PHP ソース先頭は `<?php` 必須**。省略はできない。タグ直後に空白類 1 文字以上が無くても OK (lexer がその後の echo / IDENT で区切る)
2. **non-ASCII**: **文字列リテラル内とコメント内は透過的に pass through**。それ以外の位置で non-ASCII バイトが出ると NES lexer が compile error (ERR L/C 画面表示)。pack_src.php にチェックなし。文字列内の UTF-8 バイト (例: 「あ」= 3B) はタイル ID として `echo` / `nes_puts` がそのまま PPU に流すので、ユーザ側で CHR タイルを用意する
3. **文字列は double-quoted のみ**。エスケープは `\xHH` (任意 byte)、`\\`、`\"` の 3 種だけ (`\n` 等は compile error)。decoded 結果は PRG-RAM pool ($7800-$7FFF、2KB) に溜まる。pool overflow で compile error
4. **文字列長 ≤ 255 バイト** (現行 `CMP_TOK_LEN` が 1 バイト)。UTF-8 日本語 (1 文字 = 3B) なら ~85 文字まで
5. **コメント対応済** (P4): `//`, `#`, `/* */`。block コメント未閉は compile error
6. **ソース長上限 16382 バイト** (PRG bank 0 の 16KB − 2B ヘッダ)
7. **PRG-RAM 8KB** がコンパイル出力の上限 (opcode + literal zval、文字列は ROM 常駐)
8. **CV 最大 32 スロット**、**TMP 最大 64 スロット**、**関数引数 ≤ 4**、**関数呼出ネスト無し** (call expr は `fgets` / `nes_btn` のみ)
9. **比較式は非連鎖** (`$a < $b < $c` は compile error)
10. **`!` / 単項 `-` 未対応**、**`^` (BW_XOR) 未対応**
11. **if / while / for のボディ**: `{ ... }` または単文どちらも可
12. **ネスト深さ**: backpatch stack 8 段、6502 HW stack 256B (for ネスト 1 段で 4B 消費)、CV table 32 エントリ
13. **対応 intrinsic** (合計 16 種): `nes_cls` / `nes_put` / `nes_puts` / `nes_putint` / `nes_sprite_at` / `nes_sprite_attr` / `nes_chr_bg` / `nes_chr_spr` / `nes_bg_color` / `nes_palette` / `nes_attr` / `fgets` / `nes_vsync` / `nes_btn` / `nes_rand` / `nes_srand`
14. **整数リテラル**: 10 進 (`42`)、16 進 (`0xFF` / `0X0A`)、2 進 (`0b1010` / `0B11`)。16bit signed narrow、overflow 検出なし
15. **ビット演算**: `&` (BW_AND) / `|` (BW_OR) / `<<` (SL) / `>>` (SR、算術右シフト = 符号保持)。`^` (BW_XOR) / `~` (BW_NOT) は未対応
16. **論理演算**: `&&` / `||` は短絡評価、結果は 0 or 1 の IS_LONG。`!` (NOT) は未対応

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
