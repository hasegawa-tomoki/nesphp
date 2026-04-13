# 02. RAM レイアウトと 4B tagged value

[← README](./README.md) | [← 01-rom-format](./01-rom-format.md) | [→ 03-vm-dispatch](./03-vm-dispatch.md)

ROM 側は Zend 互換 16B zval を守る ([01-rom-format](./01-rom-format.md)) が、**RAM 側は 4B に縮退**する。2KB RAM でヒープなしの制約を守るため。

## 方針

- ROM: Zend 互換 16B zval (faithful)
- RAM: 4B tagged value (縮退、ただし type ID は Zend 互換)
- 動的アロケーションは一切しない。全スロットは固定オフセットで決め打ち
- VM は ROM から 16B zval を fetch → その場で 4B tagged に narrow → スタックに push

## WRAM マップ ($0000-$07FF, 2KB)

```
$0000-$007F  ゼロページ: VM レジスタ (PC/SP/LITBASE/CVBASE/TMP 等)
$0080-$00FF  ゼロページ: コントローラ状態, NMI 作業変数, 一時 TMP
$0100-$01FF  6502 ハードウェアスタック (256B)
$0200-$02FF  OAM シャドウ (256B, 延長ゴール用。MVP では未使用)
$0300-$03FF  VM データスタック (4B × 64 エントリ = 256B)
$0400-$04FF  CV スロット (4B × 最大 32 エントリ = 128B、残り予備)
$0500-$05FF  TMP スロット (4B × 最大 64 エントリ = 256B)
$0600-$06FF  テキスト行バッファ / CONCAT 作業領域
$0700-$07FF  予備
```

### 2KB 利用合計

- MVP ではスタック・CV・TMP すべてフルに使う必要はない。`examples/hello.php` は **VM データスタック 1 段、CV/TMP 0 個**で動く
- 延長ゴール (`while ($i < 10) { ... }`) で CV 1-2 個、TMP 2-4 個、VM stack 2-3 段程度
- 64 段 VM スタック + 32 CV + 64 TMP で合計 640B、RAM 予算の 30%

---

## ゼロページ VM レジスタ (実装済み)

ゼロページに置くと `LDA (zp),Y` の間接アドレッシングと `LDX zp` の即値が使えて、6502 で最速。ca65 `.segment "ZEROPAGE"` で `.res` 宣言し、ld65 が自動配置する。現在の配置:

| label | サイズ | 用途 |
|---|---|---|
| `VM_PC` | 2 | 現在の zend_op の ROM アドレス (fetch 元) |
| `VM_LITBASE` | 2 | literals 配列の ROM アドレス (= OPS_BASE + literals_off) |
| `VM_CVBASE` | 2 | CV スロット配列の RAM アドレス (= $0400) |
| `VM_TMPBASE` | 2 | TMP スロット配列の RAM アドレス (= $0500) |
| `PPU_CURSOR` | 2 | nametable 書き込み位置 ($2000 ベースの絶対 PPU アドレス) |
| `OP1_VAL` | 4 | resolve_op1 が書き込む 4B tagged value |
| `OP2_VAL` | 4 | resolve_op2 が書き込む 4B tagged value |
| `RESULT_VAL` | 4 | handler が write_result で書き戻す 4B tagged value |
| `TMP0` | 2 | 汎用 16bit 作業レジスタ |
| `TMP1` | 2 | 汎用 16bit 作業レジスタ |
| `TMP2` | 2 | 汎用 16bit 作業レジスタ |
| `DIV_COUNTER` | 1 | (予約、未使用) |
| `buttons` | 1 | コントローラ状態 (bit 7=A, 6=B, ..., 0=R) |
| `pi_count` | 1 | `print_int16` が出力したバイト数 (echo_long で PPU_CURSOR 更新に使用) |
| `sprite_mode_on` | 1 | `0 = forced_blanking` / `1 = sprite_mode` の状態フラグ |

合計 ~34 バイト。ZP 予算 256B のうち 13% 程度しか使っていないので、今後も余裕あり。

---

## 4B tagged value の仕様

```
byte 0: type ID    (Zend 互換)
byte 1: payload lo
byte 2: payload hi
byte 3: payload ext (STRING 時は未使用, 将来拡張用)
```

### type ID (Zend `zend_types.h` と互換)

| 値 | 名前 | payload の意味 |
|----|------|---------------|
| 0 | IS_UNDEF | 未定義 (ゼロ埋め) |
| 1 | IS_NULL | なし |
| 2 | IS_FALSE | なし |
| 3 | IS_TRUE | なし |
| 4 | IS_LONG | **16bit 符号付き整数** (lo/hi のみ有効、ext は符号拡張) |
| 5 | IS_DOUBLE | **未対応** |
| 6 | IS_STRING | ROM 内 `zend_string` への **16bit オフセット** (lo/hi) |
| 7 | IS_ARRAY | **未対応** |
| 8 | IS_OBJECT | **未対応** |

### narrow のルール

| ROM 側 (16B zval) | RAM 側 (4B tagged) |
|---|---|
| `IS_LONG` (8B lval) 範囲 -32768..32767 | そのまま 16bit に |
| `IS_LONG` 範囲外 | serializer で compile error (実行時には発生しない) |
| `IS_STRING` (8B str pointer) | 下位 16bit をそのまま (ROM offset) |
| `IS_TRUE/FALSE/NULL` | type ID だけコピー、payload 0 |

### narrow は誰がやるか

**VM 側のハンドラ**がフェッチ時に narrow する。serializer は ROM に Zend 互換の 16B zval を書くだけで、narrow を事前に行わない。これは「ROM は Zend のレイアウトそのまま」という L3 方針の帰結。

---

## データスタック ($0300-$03FF)

4B tagged value × 64 段 = 256B。VM_SP は `$0300` を底、`$03FF+1` を満杯として下向きに伸ばす (または上向きでもよい、要決定)。

**推奨**: 上向きに伸ばす。`push` = `STA ($02),Y : INY ×4`。底は `$0300`、満杯は `$0400`。

### push/pop マクロ

```asm
; push A/X/Y (型/lo/hi) into VM stack
.macro PUSH_LXH
    LDY #0
    STA (VM_SP),Y       ; type
    INY
    TXA
    STA (VM_SP),Y       ; lo
    INY
    TYA                 ; (reuse A)
    STA (VM_SP),Y       ; hi
    INY
    LDA #0
    STA (VM_SP),Y       ; ext
    LDA VM_SP
    CLC
    ADC #4
    STA VM_SP
    BCC :+
    INC VM_SP+1
:
.endmacro
```

(疑似コード、実際の実装は [03-vm-dispatch](./03-vm-dispatch.md) と合わせて調整)

---

## CV スロットと TMP スロット

- **CV** (`$0400-$04FF`): Zend の「コンパイル済みローカル変数」。PHP の `$a`, `$b` 等がスロット番号に割り当てられる。serializer は op_array header の `num_cvs` を出力、VM はそれを超えるスロット番号を検出したら panic
- **TMP** (`$0500-$05FF`): Zend の `IS_TMP_VAR` / `IS_VAR`。短寿命の中間値

### アクセス

```
CV slot n  →  $0400 + n*4  
TMP slot n →  $0500 + n*4  
```

どちらも 4B tagged value 1 個分。

---

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — ROM 側の 16B zval レイアウト
- [03-vm-dispatch](./03-vm-dispatch.md) — operand resolver がこのレイアウトをどう読むか
- [04-opcode-mapping](./04-opcode-mapping.md) — 各 opcode で使うスロット数
