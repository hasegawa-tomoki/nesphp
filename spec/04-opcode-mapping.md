# 04. Zend opcode → ハンドラ対応

[← README](./README.md) | [← 03-vm-dispatch](./03-vm-dispatch.md) | [→ 05-toolchain](./05-toolchain.md)

Zend opcode 番号は PHP バージョンで変動するので、**PHP 8.4 に version lock** する。正確な番号は `php-src/Zend/zend_vm_opcodes.h` (8.4 ブランチ) を見てハードコード。

## 版管理ルール

- serializer.php と VM (ca65) は、同じ定数表を参照する
- 定数表は `spec/04-opcode-mapping.md` (このファイル) が単一の真実
- PHP のマイナーバージョンが変わったら、このファイルの表を更新し、serializer/VM 両方を再ビルド
- op_array header の `php_version_major/minor` が 8.4 でなければ VM は即 halt

## 対応 Zend opcode (実装済み)

| Zend opcode | 番号 | 段階 | nesphp での扱い |
|-------------|------|------|----------------|
| `ZEND_NOP` | **0 (0x00)** | 延長4 | 何もせず PC を進める (intrinsic 畳み込みのプレースホルダ) |
| `ZEND_ADD` | **1 (0x01)** | 延長1 | op1+op2 (IS_LONG 前提) → result。16bit 符号付き加算 |
| `ZEND_SUB` | **2 (0x02)** | 延長1 | op1-op2 → result。16bit 符号付き減算 |
| `ZEND_IS_IDENTICAL` | **16 (0x10)** | 延長5A | 同じ型 + 同じ値。文字列は `values_equal_content` で len + val[] content 比較 |
| `ZEND_IS_NOT_IDENTICAL` | **17 (0x11)** | 延長5A | 否定版 |
| `ZEND_IS_EQUAL` | **18 (0x12)** | 延長2 | `IS_IDENTICAL` と同じ実装を共用 (PHP の type juggling は未対応) |
| `ZEND_IS_NOT_EQUAL` | **19 (0x13)** | 延長5A | 否定版 |
| `ZEND_IS_SMALLER` | **20 (0x14)** | 延長2 | op1 < op2 (IS_LONG 符号付き 16bit)。`BVC + EOR #$80 + BMI` の標準イディオム |
| `ZEND_ASSIGN` | **22 (0x16)** | 延長1 | op1 (IS_CV) ← op2 の値。4B tagged value をそのままコピー |
| `ZEND_QM_ASSIGN` | **31 (0x1F)** | 延長1 | op1 → result。値コピー |
| `ZEND_JMP` | **42 (0x2A)** | 延長2 | op1.num (op_index) に無条件分岐 |
| `ZEND_JMPZ` | **43 (0x2B)** | 延長2 | op1 が falsy のとき op2.num に分岐 |
| `ZEND_JMPNZ` | **44 (0x2C)** | 延長2 | op1 が truthy のとき op2.num に分岐 |
| `ZEND_RETURN` | **62 (0x3E)** | MVP | PPUMASK 有効化 (forced_blanking 時) → 無限ループ |
| `ZEND_ECHO` | **136 (0x88)** | MVP / 延長1 | op1 (IS_STRING / IS_LONG) を PPU nametable に出力。IS_LONG は `print_int16` で decimal ASCII に変換 |

## nesphp カスタム opcode (0xE0-0xFF 帯)

Zend は 0-209 までを使っているので、`0xE0-0xFF` を nesphp 独自領域として確保。すべて serializer のパターン畳み込みで生成される。

| opcode | 番号 | 役割 |
|---|---|---|
| `NESPHP_FGETS` | **0xF0** | コントローラ待ち → 押されたボタンの `button_str_X` を IS_STRING で result へ |
| `NESPHP_NES_PUT` | **0xF1** | nametable の (x, y) に 1 文字書く。forced_blanking 前提 |
| `NESPHP_NES_SPRITE` | **0xF2** | sprite 0 の OAM shadow を更新。初回呼び出しで sprite_mode に遷移 |

### serializer のパターン畳み込み

以下の Zend opcode シーケンスを単一 custom opcode に畳み込む。`NOP` 置換で op_index は変わらないので後続 JMP ターゲットは壊れない。

**`fgets(STDIN)` → `NESPHP_FGETS`**
```
INIT_FCALL ... "fgets"          →  ZEND_NOP
FETCH_CONSTANT "STDIN"          →  ZEND_NOP
SEND_VAL T? ...                 →  ZEND_NOP
DO_ICALL                        →  NESPHP_FGETS (result スロット継承)
```

**`nes_put($x, $y, "X")` / `nes_sprite($x, $y, 65)` → `NESPHP_NES_PUT` / `NESPHP_NES_SPRITE`**
```
INIT_FCALL_BY_NAME ... "nes_put" →  ZEND_NOP
SEND_VAR_EX CV0 ... 1            →  ZEND_NOP  (引数を pendingArgs に記録)
SEND_VAR_EX CV1 ... 2            →  ZEND_NOP
SEND_VAL_EX string("X") ... 3    →  ZEND_NOP
DO_FCALL_BY_NAME                 →  NESPHP_NES_PUT
                                    op1 = $x, op2 = $y, extended_value = char literal
```

第 3 引数 (char / tile) は **コンパイル時リテラル必須**。非リテラルで呼び出すと serializer がエラー。

### ジャンプ先のエンコード

opcache dump では jump target は `JMP 0005` / `JMPNZ T4 0002` のように **4 桁の raw op_index** で表示される。serializer はこれを対応する operand フィールド (`op1` for JMP, `op2` for JMPZ/JMPNZ) の下位 2 バイトに uint16 として埋め込み、operand type は `IS_UNUSED` (0x00) にする。VM は `op_index * 24 + OPS_FIRST_OP` で絶対 ROM アドレスに変換して `VM_PC` にセットする。

### truthy / falsy の判定 (JMPZ/JMPNZ 用)

| zval type | 判定 |
|---|---|
| `IS_NULL` / `IS_FALSE` / `IS_UNDEF` | falsy |
| `IS_TRUE` | truthy |
| `IS_LONG` | 値 ≠ 0 なら truthy |
| `IS_STRING` | 常に truthy (簡略化、PHP の `""` / `"0"` は falsy なのだが未対応) |

番号は `/opt/homebrew/Cellar/php/8.4.6/include/php/Zend/zend_vm_opcodes.h` で確定。

### operand slot 番号の表現

CV / TMP_VAR / VAR の `op.var` フィールドには **slot 番号 × 16** を入れる (Zend の runtime byte-offset 慣習に近似、ただし `sizeof(zend_execute_data)` オフセットは除去する)。VM 側は `LSR / LSR` で 4 倍にしてから `VM_CVBASE` / `VM_TMPBASE` に加算、4B tagged value スロットにアクセスする。

serializer は opcache ダンプの `CV0($a)` / `T2` / `V1` をそれぞれ `IS_CV/0*16`, `IS_TMP_VAR/2*16`, `IS_VAR/1*16` に変換する。

## operand type (`zend_compile.h` より確定値)

| 値 | 名前 | 意味 |
|----|------|------|
| 0x00 | IS_UNUSED | 未使用 |
| 0x01 | IS_CONST | op*.constant がリテラル配列へのバイトオフセット |
| 0x02 | IS_TMP_VAR | op*.var が TMP スロット番号 |
| 0x04 | IS_VAR | op*.var が VAR スロット番号 |
| 0x08 | IS_CV | op*.var が CV (compiled variable) スロット番号 |

> **注**: spec の以前の版には IS_CV=16, IS_UNUSED=8 という誤った値が載っていた (Zend の別のフラグ定数と混同した)。正しい値は上記。

## 延長ゴール対応 opcode

### 整数演算・比較

| Zend opcode | 役割 |
|-------------|------|
| `ZEND_ADD` | 加算。OP1+OP2 (どちらも IS_LONG 前提)、結果 RESULT に書き戻し |
| `ZEND_SUB` | 減算 |
| `ZEND_MUL` | 乗算 (6502 で 16x16→16bit ルーチン ~50 行) |
| `ZEND_DIV` | 除算 (未対応候補、除算ルーチンが重い) |
| `ZEND_MOD` | 剰余 (同) |
| `ZEND_IS_EQUAL` | 等価比較 → IS_TRUE/FALSE |
| `ZEND_IS_NOT_EQUAL` | 非等価比較 |
| `ZEND_IS_SMALLER` | `<` 比較 |
| `ZEND_IS_SMALLER_OR_EQUAL` | `<=` 比較 |

### 制御フロー

| Zend opcode | 役割 |
|-------------|------|
| `ZEND_JMP` | 無条件分岐。op1.jmp_offset は ROM 内の op index に解決済 |
| `ZEND_JMPZ` | OP1 が偽なら分岐 |
| `ZEND_JMPNZ` | OP1 が真なら分岐 |
| `ZEND_JMPZNZ` | 多分岐 (未対応候補) |

**jmp_offset の解決**: Zend 実行時は `op1.jmp_offset` に `zend_op*` 差分が入っているが、serializer で **NES ROM 内の op index (0-based uint16)** に書き換える。VM はこの index に 24 を掛けて `VM_PC` を `VM_ROMBASE + 16 + index*24` に設定する。

### 変数操作

| Zend opcode | 役割 |
|-------------|------|
| `ZEND_ASSIGN` | CV[op1] に op2 を代入 |
| `ZEND_QM_ASSIGN` | TMP[result] に op1 をコピー (三項演算子等) |
| `ZEND_FETCH_CONSTANT` | PHP 定数取得 (MVP では未対応、`true`/`false`/`null` だけ特殊化可) |

### 文字列

| Zend opcode | 役割 |
|-------------|------|
| `ZEND_CONCAT` | OP1 と OP2 を連結。RAM 固定バッファ 1 本方式 ([06-display-io](./06-display-io.md) の CONCAT バッファ参照) |
| `ZEND_CAST` | 型変換 (int → string 等、MVP では未対応) |

### 関数呼び出し (組み込み特殊化)

| Zend opcode | 役割 |
|-------------|------|
| `ZEND_INIT_FCALL` | 関数呼び出し準備。op2.constant に関数名 literal オフセット |
| `ZEND_SEND_VAL` | 引数 push |
| `ZEND_SEND_VAR` | 引数 push (変数) |
| `ZEND_DO_FCALL` | 関数実行 |

### 組み込み関数のパターン畳み込み

PHP 側で `fgets(STDIN)` や `nes_sprite_set(...)` を呼ぶと、Zend は

```
INIT_FCALL N "fname"
SEND_VAL/SEND_VAR ...
...
DO_FCALL
```

の **3〜6 命令シーケンス**を出す。serializer は `INIT_FCALL` の関数名 literal を見て、以下の特殊組み込み ID に畳み込む:

| 関数名 | 畳み込み先 |
|--------|----------|
| `fgets` (with `STDIN` arg) | `BUILTIN_READ_INPUT` |
| `nes_sprite_set` | `BUILTIN_SPRITE_SET` |
| `nes_sprite_move` | `BUILTIN_SPRITE_MOVE` |

VM 側は `ZEND_DO_FCALL` handler で、組み込み ID (op_array 内のテーブルで解決) に応じてコントローラ読み取り / OAM シャドウ書き込みを実行する。詳細は [06-display-io](./06-display-io.md)。

---

## 未対応 opcode の扱い

上記以外の Zend opcode は全て **未対応**として `handle_unimpl` (画面に `UNIMPL <hex>` を表示して halt) にフォールバック。serializer は未対応 opcode を検出したら **compile error** で abort する (ユーザに「この PHP 構文は nesphp で未対応」と知らせる)。

代表的な未対応:

- `ZEND_NEW` / `ZEND_CLONE` (オブジェクト)
- `ZEND_INIT_ARRAY` / `ZEND_ADD_ARRAY_ELEMENT` (配列)
- `ZEND_FE_RESET_R` / `ZEND_FE_FETCH_R` (foreach)
- `ZEND_CATCH` / `ZEND_THROW` (例外)
- `ZEND_GENERATOR_*` (generator)
- `ZEND_FETCH_OBJ_R` / `ZEND_ASSIGN_OBJ` (オブジェクトプロパティ)

---

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — opcode バイトが格納される zend_op レイアウト
- [03-vm-dispatch](./03-vm-dispatch.md) — jump table と handler の呼ばれ方
- [05-toolchain](./05-toolchain.md) — opcode 番号の確定方法
- [06-display-io](./06-display-io.md) — 組み込み関数の畳み込み実装
