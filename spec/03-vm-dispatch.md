# 03. 6502 VM fetch-dispatch 設計

[← README](./README.md) | [← 02-ram-layout](./02-ram-layout.md) | [→ 04-opcode-mapping](./04-opcode-mapping.md)

VM 本体は ca65 で書かれた 6502 アセンブリ。目標行数は ~1200 行。

## ハイレベル構成

```
リセットハンドラ (RESET)
  ├ ゼロページ & スタック初期化
  ├ PPU ウォームアップ (2 回の VBL 待ち)
  ├ パレット書き込み
  ├ nametable クリア
  ├ op_array ヘッダを読んで VM_PC/VM_LITBASE/VM_CVBASE/VM_TMPBASE 初期化
  ├ 強制 blanking 中 ($2001 = 0) で VM メインループ開始
  └ ZEND_RETURN に到達後、$2001 を有効化して無限ループ (NMI 待ち)

VM メインループ (main_loop:)
  ├ fetch:  opcode バイトを VM_PC + 20 から読む
  ├ dispatch: jump table で handler にジャンプ
  ├ handler: operand resolver + 本体処理
  └ advance: VM_PC += 24、main_loop へ

NMI ハンドラ
  └ (MVP ではほぼ空、延長ゴールで OAM DMA / nametable 差分転送)
```

## メインループ (fetch-dispatch)

```asm
main_loop:
    ; opcode を読む (zend_op のオフセット 20)
    LDY #20
    LDA (VM_PC),Y       ; A = opcode byte (例: 0x28 = ZEND_ECHO)
    ASL A               ; A *= 2 (jump table index)
    TAX

    ; jump table から handler アドレスを取得して飛ぶ
    LDA handler_lo,X
    STA jmp_target
    LDA handler_hi,X
    STA jmp_target+1
    JMP (jmp_target)    ; ゼロページ間接 JMP
```

- `jmp_target` はゼロページの 2 バイト。6502 の `JMP (zp)` トリックを使う
- 代替: self-modifying JMP 命令 (コード領域を書き換える) でも良いが ROM 配置と相性悪いので間接 JMP 推奨
- 各 handler の末尾で `JMP advance` に飛び、VM_PC を +24 して `JMP main_loop`

### advance

```asm
advance:
    LDA VM_PC
    CLC
    ADC #24
    STA VM_PC
    BCC :+
    INC VM_PC+1
:
    JMP main_loop
```

---

## jump table

256 エントリ × 2B (lo/hi) = **512B** を ROM に置く。

```asm
.segment "RODATA"
handler_lo:
    .byte <handle_zend_nop      ; 0x00
    .byte <handle_zend_add      ; 0x01
    .byte <handle_unimpl        ; 0x02 (ZEND_SUB, MVP 未実装)
    ...
    .byte <handle_zend_echo     ; 0x28 (例)
    ...
    .byte <handle_zend_return   ; 0x3e (例)
    ...
    ; 残りは handle_unimpl

handler_hi:
    .byte >handle_zend_nop
    ...
```

- 未実装 opcode は全て `handle_unimpl` (画面に opcode 番号と `UNIMPL` を表示して halt) を指す
- ca65 のマクロで `OP_ENTRY ZEND_ECHO, handle_zend_echo` のように書けると保守しやすい

### PHP 8.4 の opcode 番号ハードコード

正確な番号は [04-opcode-mapping](./04-opcode-mapping.md) を参照。MVP で必要なのは 2 個だけ (`ZEND_ECHO`, `ZEND_RETURN`)。

---

## operand resolver

各ハンドラ先頭で op1/op2 を「4B tagged value」として `OP1_VAL` / `OP2_VAL` に取り出す共通ルーチン:

```
resolve_op1:
    LDY #21             ; op1_type のオフセット
    LDA (VM_PC),Y
    CMP #0x01           ; IS_CONST
    BEQ resolve_const
    CMP #0x10           ; IS_CV
    BEQ resolve_cv
    CMP #0x02           ; IS_TMP_VAR
    BEQ resolve_tmp
    CMP #0x04           ; IS_VAR
    BEQ resolve_var
    ; IS_UNUSED: OP1_VAL に IS_UNDEF を入れて return
    ...
```

### IS_CONST の解決

```
; op1.constant は zend_op のオフセット 0-3 (4B)
; これを literals 配列内のバイトオフセットとして扱う
LDY #0
LDA (VM_PC),Y            ; A = op1.constant lo
STA TMP0
INY
LDA (VM_PC),Y            ; A = op1.constant mid
STA TMP0+1
; (hi/ext は 0 のはず、無視)

; literals[] の先頭 + TMP0 = 該当 zval の先頭
CLC
LDA VM_LITBASE
ADC TMP0
STA TMP1
LDA VM_LITBASE+1
ADC TMP0+1
STA TMP1+1

; TMP1 が指す 16B zval から 4B tagged に narrow
; (type は u1.type_info の下位 1B = オフセット 8)
LDY #8
LDA (TMP1),Y
STA OP1_VAL              ; type ID を OP1_VAL のオフセット 0 に
; IS_LONG/IS_STRING の場合は value の下位 2B を payload lo/hi に
LDY #0
LDA (TMP1),Y
STA OP1_VAL+1            ; payload lo
INY
LDA (TMP1),Y
STA OP1_VAL+2            ; payload hi
RTS
```

### IS_CV の解決

```
; op1.var は CV スロット番号 × 4 (Zend の慣習)
; スロット n の RAM アドレスは VM_CVBASE + n (スロット番号 = op1.var / 4 ではなく、
; Zend では var フィールドに直接バイトオフセットが入る実装が多い。PHP 8.4 での
; 正確な意味は 04-opcode-mapping 参照)
LDY #0
LDA (VM_PC),Y            ; op1.var lo (バイトオフセット)
CLC
ADC VM_CVBASE
STA TMP0
LDA #0
ADC VM_CVBASE+1
STA TMP0+1
; TMP0 が CV スロットの RAM アドレス (4B tagged value)
; そのまま OP1_VAL にコピー
LDY #0
LDA (TMP0),Y
STA OP1_VAL
INY
LDA (TMP0),Y
STA OP1_VAL+1
INY
LDA (TMP0),Y
STA OP1_VAL+2
INY
LDA (TMP0),Y
STA OP1_VAL+3
RTS
```

### 速度より実装量を優先

各 handler ごとに operand 種別の組み合わせを特殊化する (CONST-UNUSED, CV-CONST, CV-CV 等) と速度は出るが実装量が爆発する。MVP は **resolve_op1 / resolve_op2 を毎回呼ぶ汎用方式**で書き、ボトルネックが見えてから特殊化する。

---

## handler の例: ZEND_ECHO

```asm
handle_zend_echo:
    ; op1 を解決
    JSR resolve_op1

    ; OP1_VAL の type が IS_STRING (6) であることを確認
    LDA OP1_VAL
    CMP #6
    BNE echo_type_error

    ; OP1_VAL の payload lo/hi が zend_string への ROM オフセット
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1

    ; TMP0 を ROM ベース ($8000 等) と足して絶対アドレスに
    CLC
    LDA TMP0
    ADC #<ROM_BASE
    STA TMP0
    LDA TMP0+1
    ADC #>ROM_BASE
    STA TMP0+1

    ; zend_string のオフセット 16 から len を取る (2B 有効)
    LDY #16
    LDA (TMP0),Y
    STA TMP1             ; len lo
    INY
    LDA (TMP0),Y
    STA TMP1+1           ; len hi

    ; val[] はオフセット 24 から
    LDA TMP0
    CLC
    ADC #24
    STA TMP0
    BCC :+
    INC TMP0+1
:

    ; TMP1 バイトを PPU nametable に書く
    JSR ppu_write_string_forced_blank

    ; ZEND_ECHO は値を push しない (void)
    JMP advance
```

`ppu_write_string_forced_blank` の中身は [06-display-io](./06-display-io.md)。

---

## handler の例: ZEND_RETURN

```asm
handle_zend_return:
    ; ZEND_RETURN op1 は return 値 (MVP では無視)
    ; PPU を有効化してから halt

    LDA #%00011110       ; PPUMASK: BG + sprite on
    STA $2001

halt_loop:
    JMP halt_loop        ; NMI 待ちの無限ループ
```

延長ゴールでは NMI が動的 echo や OAM DMA を処理するため、ここは `WAI` 相当の NOP ループになる。

---

## 未実装 opcode: handle_unimpl

```asm
handle_unimpl:
    ; 画面に "UNIMPL <opcode>" を表示して halt
    LDY #20
    LDA (VM_PC),Y        ; A = opcode 番号
    PHA
    ; ... 文字列 "UNIMPL " と opcode 番号を hex で nametable に書く
    PLA

    LDA #%00011110
    STA $2001
unimpl_halt:
    JMP unimpl_halt
```

デバッグ時にどの opcode が未実装なのか一目で分かる。

---

## リセットハンドラ (概要)

```asm
reset:
    SEI                  ; 割り込み禁止
    CLD                  ; 10進数モード off
    LDX #$FF
    TXS                  ; スタックポインタ初期化
    INX
    STX $2000            ; PPUCTRL = 0
    STX $2001            ; PPUMASK = 0 (強制 blanking)
    STX $4010            ; DMC 無効化

    ; PPU ウォームアップ (2 回の VBL 待ち)
    BIT $2002
vblankwait1:
    BIT $2002
    BPL vblankwait1
vblankwait2:
    BIT $2002
    BPL vblankwait2

    ; RAM クリア ($0000-$07FF)
    JSR clear_wram

    ; パレット書き込み
    JSR load_palette

    ; nametable クリア
    JSR clear_nametable

    ; op_array ヘッダから VM 初期化
    JSR vm_init_from_op_array

    ; VM メインループへ (強制 blanking のまま)
    JMP main_loop
```

`vm_init_from_op_array`:
- ROM 先頭 (`$8000` 等) の op_array header を読む
- `num_opcodes`, `literals_off`, `num_literals`, `num_cvs`, `num_tmps`, `php_version` を取る
- `php_version` が 8.4 でなければ即 halt (エラー表示)
- VM_PC = op[0] 先頭アドレス、VM_LITBASE = 親 ROM base + literals_off、VM_SP = `$0300`、VM_CVBASE = `$0400`、VM_TMPBASE = `$0500`
- CV/TMP スロットを IS_UNDEF で初期化

---

## 関連ドキュメント

- [02-ram-layout](./02-ram-layout.md) — ゼロページの VM レジスタ割り当て
- [04-opcode-mapping](./04-opcode-mapping.md) — 各 opcode の対応状況
- [06-display-io](./06-display-io.md) — `ppu_write_string_forced_blank` の実装
