# 04. Zend opcode → ハンドラ対応

[← README](./README.md) | [← 03-vm-dispatch](./03-vm-dispatch.md) | [→ 05-toolchain](./05-toolchain.md)

Zend opcode 番号は PHP バージョンで変動するので、**PHP 8.4 に version lock** する。正確な番号は `php-src/Zend/zend_vm_opcodes.h` (8.4 ブランチ) を見てハードコード。

## 版管理ルール

- serializer.php と VM (ca65) は、同じ定数表を参照する
- 定数表は `spec/04-opcode-mapping.md` (このファイル) が単一の真実
- PHP のマイナーバージョンが変わったら、このファイルの表を更新し、serializer/VM 両方を再ビルド
- op_array header の `php_version_major/minor` が 8.4 でなければ VM は即 halt

## 対応 Zend opcode (実装済み)

「emit (host)」列は host-compile 経路 (serializer.php) で生成されることを示す。
「emit (L3S)」列は on-NES コンパイラ (vm/compiler.s) で生成されるものを示す ([13-compiler](./13-compiler.md))。

| Zend opcode | 番号 | emit (host) | emit (L3S) | nesphp での扱い |
|-------------|------|:---:|:---:|----------------|
| `ZEND_NOP` | **0 (0x00)** | ✓ | — | 何もせず PC を進める (intrinsic 畳み込みのプレースホルダ) |
| `ZEND_ADD` | **1 (0x01)** | ✓ | ✓ (P2) | op1+op2 (IS_LONG 前提) → result。16bit 符号付き加算 |
| `ZEND_SUB` | **2 (0x02)** | ✓ | ✓ (P2) | op1-op2 → result。16bit 符号付き減算 |
| `ZEND_SL` | **6 (0x06)** | ✓ | ✓ (S1) | op1 << op2 → result。16bit 論理左シフト |
| `ZEND_SR` | **7 (0x07)** | ✓ | ✓ (S1) | op1 >> op2 → result。16bit 算術右シフト (符号保持) |
| `ZEND_BW_OR` | **9 (0x09)** | ✓ | ✓ (R3) | op1 \| op2 → result。16bit bitwise OR (IS_LONG) |
| `ZEND_BW_AND` | **10 (0x0A)** | ✓ | ✓ (R3) | op1 & op2 → result。16bit bitwise AND (IS_LONG) |
| `ZEND_IS_IDENTICAL` | **16 (0x10)** | ✓ | ✓ (P3) | 同じ型 + 同じ値。文字列は `values_equal_content` で len + val[] content 比較 |
| `ZEND_IS_NOT_IDENTICAL` | **17 (0x11)** | ✓ | ✓ (P3) | 否定版 |
| `ZEND_IS_EQUAL` | **18 (0x12)** | ✓ | ✓ (P3) | `IS_IDENTICAL` と同じ実装を共用 (PHP の type juggling は未対応) |
| `ZEND_IS_NOT_EQUAL` | **19 (0x13)** | ✓ | ✓ (P3) | 否定版 |
| `ZEND_IS_SMALLER` | **20 (0x14)** | ✓ | ✓ (P3) | op1 < op2 (IS_LONG 符号付き 16bit)。`BVC + EOR #$80 + BMI` の標準イディオム |
| `ZEND_ASSIGN` | **22 (0x16)** | ✓ | ✓ (P2) | op1 (IS_CV) ← op2 の値。4B tagged value をそのままコピー |
| `ZEND_QM_ASSIGN` | **31 (0x1F)** | ✓ | — | op1 → result。値コピー |
| `ZEND_PRE_INC` | **34 (0x22)** | ✓ | ✓ (Q3) | `++$x`。op1 (IS_CV) を +1 し result に新値 |
| `ZEND_PRE_DEC` | **35 (0x23)** | ✓ | ✓ (Q3) | `--$x`。op1 を −1 し result に新値 |
| `ZEND_POST_INC` | **36 (0x24)** | ✓ | ✓ (Q3) | `$x++`。op1 を +1、result に旧値 |
| `ZEND_POST_DEC` | **37 (0x25)** | ✓ | ✓ (Q3) | `$x--`。op1 を −1、result に旧値 |
| `ZEND_INIT_ARRAY` | **71 (0x47)** | ✓ | ✓ (U1) | op1 = capacity (raw u16)、result に新 array の TYPE_ARRAY zval。2KB pool ($7000-$77FF) から alloc |
| `ZEND_ADD_ARRAY_ELEMENT` | **72 (0x48)** | ✓ | ✓ (U1) | op1 = array TMP、op2 = 要素。array の count 位置に 16B zval として append、count++ |
| `ZEND_FETCH_DIM_R` | **81 (0x51)** | ✓ | ✓ (U1) | op1 = array、op2 = index (IS_LONG)、result = 読取要素を 4B tagged に展開 |
| `ZEND_COUNT` | **90 (0x5A)** | ✓ | ✓ (U1) | op1 = array、result = IS_LONG(count) |
| `ZEND_OP_DATA` | **138 (0x8A)** | ✓ | ✓ (V1) | 単独実行は no-op。ASSIGN_DIM 等が value を次 op の op1 から読むための payload |
| `ZEND_ASSIGN_DIM` | **147 (0x93)** | ✓ | ✓ (V1) | op1 = array、op2 = key (IS_UNUSED で append)。value は次の ZEND_OP_DATA の op1 から取得。VM_PC +48 で 2-op sequence を消費。count = max(count, slot+1) 更新 |
| `ZEND_JMP` | **42 (0x2A)** | ✓ | ✓ (P3) | op1.num (op_index) に無条件分岐 |
| `ZEND_JMPZ` | **43 (0x2B)** | ✓ | ✓ (P3) | op1 が falsy のとき op2.num に分岐 |
| `ZEND_JMPNZ` | **44 (0x2C)** | ✓ | — | op1 が truthy のとき op2.num に分岐 |
| `ZEND_RETURN` | **62 (0x3E)** | ✓ | ✓ (M-A') | PPUMASK 有効化 → 無限ループ |
| `ZEND_ECHO` | **136 (0x88)** | ✓ | ✓ (M-A') | op1 を PPU nametable に出力 |

L3S で emit 対象の nesphp カスタム opcode (intrinsic 畳み込み):

| Custom opcode | 番号 | emit (L3S) |
|---|---|:---:|
| `NESPHP_FGETS` | 0xF0 | ✓ (P1) |
| `NESPHP_NES_PUT` | 0xF1 | ✓ (Q1) |
| `NESPHP_NES_SPRITE` | 0xF2 | ✓ (Q1) — `nes_sprite_at($idx, $x, $y, $tile)` で OAM[$idx] (0-63) を更新 |
| `NESPHP_NES_PUTS` | 0xF3 | ✓ (P1) |
| `NESPHP_NES_CLS` | 0xF4 | ✓ (P1) |
| `NESPHP_NES_CHR_SPR` | 0xF5 | ✓ (P1) |
| `NESPHP_NES_CHR_BG` | 0xF6 | ✓ (P1) |
| `NESPHP_NES_BG_COLOR` | 0xF7 | ✓ (P1) |
| `NESPHP_NES_PALETTE` | 0xF8 | ✓ (P1) |
| `NESPHP_NES_ATTR` | 0xF9 | ✓ (Q1) |
| `NESPHP_NES_VSYNC` | 0xFA | ✓ (R1) — 次 VBlank まで spin、sprite_mode 自動有効化 |
| `NESPHP_NES_BTN` | 0xFB | ✓ (R2) — **0 引数**、コントローラ状態を IS_LONG (下位 1B = bitmask) で返す。呼び出し側で `$b & 0x80` 等でビット演算 |
| `NESPHP_NES_SPRITE_ATTR` | 0xFC | ✓ (S1) — `nes_sprite_attr($idx, $attr)`。OAM[$idx*4+2] を更新 |

Q2: 16 進リテラル `0x..` 対応 (lexer)。Q3: `ZEND_PRE_INC` (34) / `ZEND_PRE_DEC` (35) / `ZEND_POST_INC` (36) / `ZEND_POST_DEC` (37) を L3S で emit 可能 (`++$x` / `$x++` / `--$x` / `$x--`)。Q4: `for (init; cond; update) body` を double-JMP で展開して emit。
| `ZEND_RETURN` | **62 (0x3E)** | MVP | PPUMASK 有効化 (forced_blanking 時) → 無限ループ |
| `ZEND_ECHO` | **136 (0x88)** | MVP / 延長1 | op1 (IS_STRING / IS_LONG) を PPU nametable に出力。IS_LONG は `print_int16` で decimal ASCII に変換 |

## nesphp カスタム opcode (0xE0-0xFF 帯)

Zend は 0-209 までを使っているので、`0xE0-0xFF` を nesphp 独自領域として確保。すべて serializer のパターン畳み込みで生成される。

| opcode | 番号 | 役割 |
|---|---|---|
| `NESPHP_FGETS` | **0xF0** | コントローラ待ち → 押されたボタンの `button_str_X` を IS_STRING で result へ |
| `NESPHP_NES_PUT` | **0xF1** | nametable の (x, y) に 1 文字書く。forced_blanking 前提 |
| `NESPHP_NES_SPRITE` | **0xF2** | OAM[$idx] (0-63) の y / tile / x を更新。$idx は runtime int 可、$tile はリテラル必須。attr バイトは触らない (`NESPHP_NES_SPRITE_ATTR` で別途)。初回呼び出しで sprite_mode に遷移 |
| `NESPHP_NES_PUTS` | **0xF3** | nametable の (x, y) に文字列リテラルを書く。forced_blanking 前提、行折り返しなし |
| `NESPHP_NES_CLS` | **0xF4** | nametable 0 ($2000-$23FF) を空白で埋めて `PPU_CURSOR` を既定位置に戻す。forced_blanking 前提 |
| `NESPHP_NES_CHR_SPR` | **0xF5** | sprite 用 4KB CHR bank 切替 (0-7)。MMC1 CHR bank 1 register ($C000) に書く → PPU $1000。詳細は [11-chr-banks](./11-chr-banks.md) |
| `NESPHP_NES_CHR_BG` | **0xF6** | BG 用 4KB CHR bank 切替 (0-7)。MMC1 CHR bank 0 register ($A000) に書く → PPU $0000 |
| `NESPHP_NES_BG_COLOR` | **0xF7** | 背景色 ($3F00) を NES カラーコード (0x00-0x3F) で設定。全パレット共通 |
| `NESPHP_NES_PALETTE` | **0xF8** | パレットの色 1-3 を設定。4 引数 (id, c1, c2, c3) で op1/op2/result/extended_value を全て使用 |
| `NESPHP_NES_ATTR` | **0xF9** | attribute table の 2×2 タイルブロックにパレット番号 (0-3) を設定。64B RAM shadow 経由で read-modify-write |
| `NESPHP_NES_SPRITE_ATTR` | **0xFC** | OAM[$idx] (0-63) の attribute byte を設定。bit 0-1=palette / bit 5=priority / bit 6=hflip / bit 7=vflip。両引数とも runtime int 可 |

### serializer のパターン畳み込み

以下の Zend opcode シーケンスを単一 custom opcode に畳み込む。`NOP` 置換で op_index は変わらないので後続 JMP ターゲットは壊れない。

**`fgets(STDIN)` → `NESPHP_FGETS`**
```
INIT_FCALL ... "fgets"          →  ZEND_NOP
FETCH_CONSTANT "STDIN"          →  ZEND_NOP
SEND_VAL T? ...                 →  ZEND_NOP
DO_ICALL                        →  NESPHP_FGETS (result スロット継承)
```

**`nes_put($x, $y, "X")` / `nes_puts($x, $y, "str")` → `NESPHP_NES_PUT` / `NESPHP_NES_PUTS`**
```
INIT_FCALL_BY_NAME ... "nes_put" →  ZEND_NOP
SEND_VAR_EX CV0 ... 1            →  ZEND_NOP  (引数を pendingArgs に記録)
SEND_VAR_EX CV1 ... 2            →  ZEND_NOP
SEND_VAL_EX string("X") ... 3    →  ZEND_NOP
DO_FCALL_BY_NAME                 →  NESPHP_NES_PUT
                                    op1 = $x, op2 = $y, extended_value = char literal
```

第 3 引数 (char / string) は **コンパイル時リテラル必須**。非リテラルで呼び出すと serializer がエラー。`nes_puts` は第 3 引数が `TYPE_STRING` リテラルで、VM が `zend_string.len + val[]` を PPUDATA へ流し込む。

**`nes_sprite_at($idx, $x, $y, $tile)` → `NESPHP_NES_SPRITE`**
```
INIT_FCALL_BY_NAME 4 "nes_sprite_at" →  ZEND_NOP
SEND_VAL_EX $idx 1                  →  ZEND_NOP
SEND_VAL_EX $x 2                    →  ZEND_NOP
SEND_VAL_EX $y 3                    →  ZEND_NOP
SEND_VAL_EX int($tile) 4            →  ZEND_NOP
DO_FCALL_BY_NAME                     →  NESPHP_NES_SPRITE
                                        op1 = $idx, op2 = $x,
                                        result = $y, extended_value = $tile
```

`nes_palette` と同じく 4 引数 intrinsic で、result フィールドを「3 番目の入力」として再利用する。`$idx` / `$x` / `$y` は runtime int 可 (CV/TMP/CONST)、`$tile` のみリテラル必須。`$idx` は VM 側で `& 0x3F` クランプして OAM offset に変換する。

**`nes_sprite_attr($idx, $attr)` → `NESPHP_NES_SPRITE_ATTR`**
```
INIT_FCALL_BY_NAME 2 "nes_sprite_attr" →  ZEND_NOP
SEND_VAL_EX $idx 1                    →  ZEND_NOP
SEND_VAL_EX $attr 2                   →  ZEND_NOP
DO_FCALL_BY_NAME                       →  NESPHP_NES_SPRITE_ATTR
                                          op1 = $idx, op2 = $attr
```

両引数とも runtime int 可。OAM[$idx*4+2] に attribute byte を直接書き込む (palette / flip / priority)。

**`nes_cls()` → `NESPHP_NES_CLS`**
```
INIT_FCALL_BY_NAME 0 "nes_cls"   →  ZEND_NOP
DO_FCALL_BY_NAME                 →  NESPHP_NES_CLS  (引数 0)
```

**`nes_chr_bg(N)` / `nes_chr_spr(N)` → `NESPHP_NES_CHR_BG` / `NESPHP_NES_CHR_SPR`**
```
INIT_FCALL_BY_NAME 1 "nes_chr_bg"   →  ZEND_NOP
SEND_VAL_EX int(N) 1                →  ZEND_NOP
DO_FCALL_BY_NAME                    →  NESPHP_NES_CHR_BG
                                       op1 = int literal (IS_CONST)
```

引数はコンパイル時の整数リテラル (4KB bank 番号 0-7) 必須。BG と sprite を独立に切替可能 (MMC1 の 4KB CHR banking)。

**`nes_bg_color($c)` → `NESPHP_NES_BG_COLOR`**
```
INIT_FCALL_BY_NAME 1 "nes_bg_color"  →  ZEND_NOP
SEND_VAL_EX int($c) 1               →  ZEND_NOP
DO_FCALL_BY_NAME                     →  NESPHP_NES_BG_COLOR
                                        op1 = int literal (IS_CONST), NES color code 0x00-0x3F
```

引数はコンパイル時の整数リテラル (NES カラーコード $00-$3F) 必須。PPU $3F00 (universal background color) を設定する。

**`nes_palette($id, $c1, $c2, $c3)` → `NESPHP_NES_PALETTE`**
```
INIT_FCALL_BY_NAME 4 "nes_palette"   →  ZEND_NOP
SEND_VAL_EX int($id) 1              →  ZEND_NOP  (pendingArgs[0])
SEND_VAL_EX int($c1) 2              →  ZEND_NOP  (pendingArgs[1])
SEND_VAL_EX int($c2) 3              →  ZEND_NOP  (pendingArgs[2])
SEND_VAL_EX int($c3) 4              →  ZEND_NOP  (pendingArgs[3])
DO_FCALL_BY_NAME                     →  NESPHP_NES_PALETTE
                                        op1 = $id, op2 = $c1,
                                        result = $c2, extended_value = $c3
```

**nesphp 初の 4 引数 intrinsic**。zend_op の 4 つのフィールド (op1, op2, result, extended_value) を全て入力として使用する。result フィールドを「出力」ではなく「入力」として流用するのは Zend の慣習から逸脱するが、4 引数を 1 命令に畳む唯一の方法。引数は全てコンパイル時の整数リテラル必須。id 0-3 = BG パレット、4-7 = sprite パレット。

**`nes_attr($x, $y, $pal)` → `NESPHP_NES_ATTR`**
```
INIT_FCALL_BY_NAME 3 "nes_attr"     →  ZEND_NOP
SEND_VAL_EX int($x) 1              →  ZEND_NOP
SEND_VAL_EX int($y) 2              →  ZEND_NOP
SEND_VAL_EX int($pal) 3            →  ZEND_NOP
DO_FCALL_BY_NAME                    →  NESPHP_NES_ATTR
                                       op1 = $x, op2 = $y,
                                       extended_value = $pal (パレット番号 0-3)
```

引数は全てコンパイル時の整数リテラル必須。x, y は 2×2 タイル (16×16 ピクセル) ブロック単位の座標 (x: 0-15, y: 0-14)。VM は 64B の RAM shadow (ATTR_SHADOW = $0608) を read-modify-write して attribute table に反映する。

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
