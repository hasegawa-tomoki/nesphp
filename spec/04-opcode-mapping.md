# 04. Zend opcode → ハンドラ対応

[← README](./README.md) | [← 03-vm-dispatch](./03-vm-dispatch.md) | [→ 05-toolchain](./05-toolchain.md)

Zend opcode 番号は PHP バージョンで変動するので、**PHP 8.4 に version lock** する。正確な番号は `php-src/Zend/zend_vm_opcodes.h` (8.4 ブランチ) を見てハードコード。

## 版管理ルール

- serializer.php と VM (ca65) は、同じ定数表を参照する
- 定数表は `spec/04-opcode-mapping.md` (このファイル) が単一の真実
- PHP のマイナーバージョンが変わったら、このファイルの表を更新し、serializer/VM 両方を再ビルド
- op_array header の `php_version_major/minor` が 8.4 でなければ VM は即 halt

## MVP 対応 opcode (最小)

| Zend opcode | 番号 (PHP 8.4.6) | 実装 | nesphp での扱い |
|-------------|------------------|------|----------------|
| `ZEND_ECHO` | **136 (0x88)** | ✓ | op1 (IS_CONST) → literals → zend_string → PPU nametable に出力 |
| `ZEND_RETURN` | **62 (0x3e)** | ✓ | PPUMASK 有効化 → NMI 待ちの無限ループ |

番号は `/opt/homebrew/Cellar/php/8.4.6/include/php/Zend/zend_vm_opcodes.h` で確定。

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
