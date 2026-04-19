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

## 対応文法 (マイルストーン別)

本ドキュメントは対応文法の**現状 + 設計上の目標**を記載する。マイルストーン進行は [07-roadmap](./07-roadmap.md) 参照。

### M-A' (実装済)

```ebnf
program    ::= "<?php" echo_stmt* EOF
echo_stmt  ::= "echo" STRING ";"
STRING     ::= '"' [^"]* '"'
```

- トークン: `<?php`, `echo`, `"..."` (double-quoted、エスケープ未対応), `;`
- 空白類 (SP / TAB / LF / CR) はすべて skip
- EOF で暗黙 `ZEND_RETURN(int(1))` を emit

### M-B-slim (予定): 整数リテラル

```ebnf
echo_stmt  ::= "echo" (STRING | INT) ";"
INT        ::= [0-9]+
```

- 10 進整数、16bit signed narrowing (範囲外で compile error)
- IS_LONG zval として emit

### P1 (Presentation MVP 予定): intrinsic 呼び出し

```ebnf
stmt         ::= call_stmt | echo_stmt
call_stmt    ::= IDENT "(" args? ")" ";"
args         ::= arg ("," arg)*
arg          ::= STRING | INT | "STDIN"
IDENT        ::= [a-zA-Z_] [a-zA-Z0-9_]*
```

- intrinsic 一覧は [04-opcode-mapping](./04-opcode-mapping.md) の「nesphp カスタム opcode」節を参照
- 各 intrinsic は「関数名 + 引数数 + 引数型」をコンパイル時に検証
- 戻り値が値として使われない場合は ZEND_FREE を emit (`fgets(STDIN);` 単独文等)

### M-B / M-C / M-D (残部、順次): CV / 算術 / 制御フロー

- `$name = expr;`、`+`, `-`, `===`, `!==`, `<`, `while (cond) { ... }`, `if (cond) { ... }`
- 詳細は [07-roadmap](./07-roadmap.md) 参照

---

## WRAM 共用契約 (compile phase vs runtime phase)

2KB WRAM ($0000-$07FF) を時間的に分離して使う。compile_and_emit が戻った後、VM main_loop は既存の割当で動く。

### コンパイル中にのみ使う ZP (約 14 バイト)

| label | size | 用途 |
|-------|------|------|
| `CMP_SRC_PTR` | 2 | 現在のソース読み出し位置 (ROM $8002-$BFFF 範囲) |
| `CMP_SRC_END` | 2 | ソース終端 (one-past-last) |
| `CMP_OP_HEAD` | 2 | 次に emit する zend_op の PRG-RAM アドレス ($6010..) |
| `CMP_LIT_HEAD` | 2 | 次に emit する zval の一時 PRG-RAM アドレス ($7000..) |
| `CMP_OP_COUNT` | 2 | emit 済み opcode 数 |
| `CMP_LIT_COUNT` | 2 | emit 済み literal 数 |
| `CMP_TOK_KIND` | 1 | 現在のトークン種別 |
| `CMP_TOK_PTR` | 2 | トークン開始 ROM アドレス (STRING 時は val[] 先頭) |
| `CMP_TOK_LEN` | 1 | トークン長 (現状 255B 上限) |

これらはコンパイル終了後に未使用。VM は触らない。

### 作業エリア

- `$7000-$77FF`: コンパイル中、literal zval の一時バッファ (CMP_LIT_STAGE)。cmp_finalize で $6000 + literals_off に memcpy 後は未使用
- `$6000-$6FFF`: 最終レイアウト (header + opcodes + literals)。runtime は VM_PC / VM_LITBASE 経由で参照

### TMP0/TMP1/TMP2 の共有

`TMP0`, `TMP1`, `TMP2` (各 2 バイト、ZP) はコンパイル中も runtime もスクラッチ用に使う。compile_and_emit はランタイムが走る前に終わるので、重複でも問題ない (値の受け渡しは関数内完結)。

---

## 制約・制限事項

1. **PHP ソース先頭は `<?php` 必須**。省略はできない。タグ直後に空白類 1 文字以上が無くても OK (lexer がその後の echo / IDENT で区切る)
2. **ASCII only**。pack_src.php が non-ASCII バイトを検出したら compile error
3. **文字列は double-quoted のみ**、エスケープ (`\n` 等) 未対応
4. **文字列長 ≤ 255 バイト** (現行 `CMP_TOK_LEN` が 1 バイト)。65535 バイトまで拡張可能だが未実装
5. **コメント未対応** (将来 `//`, `#`, `/* */` を skip する lexer 拡張で対応予定)
6. **ソース長上限 16382 バイト** (PRG bank 0 の 16KB − 2B ヘッダ)
7. **PRG-RAM 8KB** がコンパイル出力の上限。現 examples は全て収まる

---

## エラー処理 (現状 = M-A')

`cmp_error` は無限ループ。M-B 以降で画面にエラー位置 (`L<line> C<col>: <code>`) を表示して halt する設計に置き換える。

**ホスト側 pre-flight lint** (将来検討): `pack_src.php` 内で簡易構文チェック (ダブルクォート未閉じ等) を行い、ROM ビルド時にエラーを早期検出する。NES 上でエラー halt することはほぼ無くなる運用にできる。

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
