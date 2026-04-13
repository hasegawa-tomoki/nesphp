; =============================================================================
; nesphp VM — 6502 アセンブリ本体
;
; spec/03-vm-dispatch.md  dispatch 設計
; spec/01-rom-format.md   ROM バイナリ仕様
; spec/02-ram-layout.md   RAM マップ
; spec/06-display-io.md   PPU 表示フロー
;
; 対応 Zend opcode:
;   ZEND_ECHO       (136)  IS_STRING / IS_LONG を PPU nametable へ
;   ZEND_RETURN     (62)   PPUMASK 有効化 → halt
;   ZEND_ASSIGN     (22)   op2 の値を op1 (CV) に代入
;   ZEND_ADD        (1)    op1+op2 (IS_LONG 16bit) → result
;   ZEND_SUB        (2)    op1-op2 (IS_LONG 16bit) → result
;   ZEND_QM_ASSIGN  (31)   op1 → result
; =============================================================================

; --- Zend opcode 番号 (PHP 8.4.6 Zend/zend_vm_opcodes.h) ---
ZEND_NOP        = 0
ZEND_ADD        = 1
ZEND_SUB        = 2
ZEND_IS_EQUAL   = 18
ZEND_IS_SMALLER = 20
ZEND_ASSIGN     = 22
ZEND_QM_ASSIGN  = 31
ZEND_JMP        = 42
ZEND_JMPZ       = 43
ZEND_JMPNZ      = 44
ZEND_RETURN     = 62
ZEND_ECHO       = 136

; --- nesphp カスタム opcode (0xE0-0xFF は Zend 未使用領域) ---
NESPHP_FGETS    = $F0

; --- Operand type (Zend/zend_compile.h) ---
IS_UNUSED       = 0
IS_CONST        = 1
IS_TMP_VAR      = 2
IS_VAR          = 4
IS_CV           = 8

; --- zval type IDs (Zend/zend_types.h) ---
TYPE_UNDEF      = 0
TYPE_NULL       = 1
TYPE_FALSE      = 2
TYPE_TRUE       = 3
TYPE_LONG       = 4
TYPE_STRING     = 6

; --- PPU レジスタ ---
PPUCTRL      = $2000
PPUMASK      = $2001
PPUSTATUS    = $2002
PPUSCROLL    = $2005
PPUADDR      = $2006
PPUDATA      = $2007
DMC_FREQ     = $4010

; --- ROM / op_array 配置 ---
OPS_BASE     = $8000
OPS_FIRST_OP = $8010

; op_array ヘッダ (spec/01-rom-format.md)
HDR_NUM_OPS        = OPS_BASE + 0
HDR_LITERALS_OFF   = OPS_BASE + 2
HDR_NUM_LITERALS   = OPS_BASE + 4
HDR_NUM_CVS        = OPS_BASE + 6
HDR_NUM_TMPS       = OPS_BASE + 8
HDR_PHP_MAJOR      = OPS_BASE + 10
HDR_PHP_MINOR      = OPS_BASE + 11

; --- ナメテーブル書き込み開始位置 ---
NAMETABLE_START = $21EA          ; row 14, col 10

; --- CV / TMP スロット RAM ベース (spec/02-ram-layout.md) ---
CV_BASE_ADDR    = $0400
TMP_BASE_ADDR   = $0500

; =============================================================================
; ゼロページ VM レジスタ
; =============================================================================
.segment "ZEROPAGE"

VM_PC:       .res 2    ; 現在の zend_op の ROM アドレス
VM_LITBASE:  .res 2    ; literals 配列の ROM アドレス
VM_CVBASE:   .res 2    ; CV 配列の RAM アドレス (= $0400)
VM_TMPBASE:  .res 2    ; TMP 配列の RAM アドレス (= $0500)
PPU_CURSOR:  .res 2    ; 現在 nametable 書き込み位置

; operand resolver 出力 (4 バイト tagged value)
OP1_VAL:     .res 4
OP2_VAL:     .res 4
RESULT_VAL:  .res 4

; 汎用作業
TMP0:        .res 2
TMP1:        .res 2
TMP2:        .res 2
DIV_COUNTER: .res 1    ; int16→ASCII 用

; コントローラ入力
buttons:     .res 1    ; 現在のボタン状態 (bit 7=A, 6=B, 5=Sel, 4=Start, 3=U, 2=D, 1=L, 0=R)
pi_count:    .res 1    ; print_int16 が書いたバイト数

; =============================================================================
; iNES ヘッダ
; =============================================================================
.segment "HEADER"
    .byte "NES", $1A
    .byte 2                ; PRG-ROM = 2 * 16KB = 32KB (NROM-256)
    .byte 1                ; CHR-ROM = 1 * 8KB
    .byte %00000000        ; Flags 6
    .byte %00000000        ; Flags 7
    .byte 0, 0, 0, 0, 0, 0, 0, 0

; =============================================================================
; OPS セグメント: serializer が出した ops.bin
; =============================================================================
.segment "OPS"
    .incbin "build/ops.bin"

; =============================================================================
; CODE セグメント: VM 本体
; =============================================================================
.segment "CODE"

; -----------------------------------------------------------------------------
; RESET ハンドラ
; -----------------------------------------------------------------------------
reset:
    SEI
    CLD
    LDX #$FF
    TXS
    INX                    ; X = 0
    STX PPUCTRL
    STX PPUMASK            ; 強制 blanking
    STX DMC_FREQ

    ; 1 回目の VBL 待ち
    BIT PPUSTATUS
:   BIT PPUSTATUS
    BPL :-

    ; WRAM クリア
    LDA #0
    TAX
clear_wram_loop:
    STA $0000, X
    STA $0100, X
    STA $0200, X
    STA $0300, X
    STA $0400, X
    STA $0500, X
    STA $0600, X
    STA $0700, X
    INX
    BNE clear_wram_loop

    ; 2 回目の VBL 待ち
:   BIT PPUSTATUS
    BPL :-

    ; パレット書き込み
    BIT PPUSTATUS
    LDA #$3F
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDX #0
load_palette_loop:
    LDA palette_data, X
    STA PPUDATA
    INX
    CPX #32
    BNE load_palette_loop

    ; ネームテーブルをスペースで埋める
    BIT PPUSTATUS
    LDA #$20
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$20
    LDX #4
    LDY #0
clear_nt_outer:
clear_nt_inner:
    STA PPUDATA
    INY
    BNE clear_nt_inner
    DEX
    BNE clear_nt_outer

    ; php_version を確認
    LDA HDR_PHP_MAJOR
    CMP #8
    BEQ :+
    JMP version_mismatch
:
    LDA HDR_PHP_MINOR
    CMP #4
    BEQ :+
    JMP version_mismatch
:

    ; VM_PC = OPS_FIRST_OP
    LDA #<OPS_FIRST_OP
    STA VM_PC
    LDA #>OPS_FIRST_OP
    STA VM_PC+1

    ; VM_LITBASE = OPS_BASE + literals_off
    CLC
    LDA HDR_LITERALS_OFF
    ADC #<OPS_BASE
    STA VM_LITBASE
    LDA HDR_LITERALS_OFF+1
    ADC #>OPS_BASE
    STA VM_LITBASE+1

    ; VM_CVBASE = $0400
    LDA #<CV_BASE_ADDR
    STA VM_CVBASE
    LDA #>CV_BASE_ADDR
    STA VM_CVBASE+1

    ; VM_TMPBASE = $0500
    LDA #<TMP_BASE_ADDR
    STA VM_TMPBASE
    LDA #>TMP_BASE_ADDR
    STA VM_TMPBASE+1

    ; PPU_CURSOR 初期化
    LDA #<NAMETABLE_START
    STA PPU_CURSOR
    LDA #>NAMETABLE_START
    STA PPU_CURSOR+1

    ; PPUADDR を PPU_CURSOR にセット (強制 blanking 中)
    BIT PPUSTATUS
    LDA PPU_CURSOR+1
    STA PPUADDR
    LDA PPU_CURSOR
    STA PPUADDR

    JMP main_loop

; -----------------------------------------------------------------------------
; メインループ: fetch → dispatch
; -----------------------------------------------------------------------------
main_loop:
    LDY #20                ; zend_op.opcode オフセット
    LDA (VM_PC), Y

    CMP #ZEND_NOP
    BNE :+
    JMP advance            ; NOP: そのまま次命令へ
:
    CMP #NESPHP_FGETS
    BNE :+
    JMP handle_nesphp_fgets
:
    CMP #ZEND_ECHO
    BNE :+
    JMP handle_zend_echo
:
    CMP #ZEND_RETURN
    BNE :+
    JMP handle_zend_return
:
    CMP #ZEND_ASSIGN
    BNE :+
    JMP handle_zend_assign
:
    CMP #ZEND_ADD
    BNE :+
    JMP handle_zend_add
:
    CMP #ZEND_SUB
    BNE :+
    JMP handle_zend_sub
:
    CMP #ZEND_QM_ASSIGN
    BNE :+
    JMP handle_zend_qm_assign
:
    CMP #ZEND_JMP
    BNE :+
    JMP handle_zend_jmp
:
    CMP #ZEND_JMPZ
    BNE :+
    JMP handle_zend_jmpz
:
    CMP #ZEND_JMPNZ
    BNE :+
    JMP handle_zend_jmpnz
:
    CMP #ZEND_IS_SMALLER
    BNE :+
    JMP handle_zend_is_smaller
:
    CMP #ZEND_IS_EQUAL
    BNE :+
    JMP handle_zend_is_equal
:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; advance: VM_PC += 24, 次の命令へ
; -----------------------------------------------------------------------------
advance:
    CLC
    LDA VM_PC
    ADC #24
    STA VM_PC
    BCC :+
    INC VM_PC+1
:
    JMP main_loop

; =============================================================================
; operand resolver
;
; resolve_op1 / resolve_op2 : op1/op2 を 4B tagged value として OP1_VAL/OP2_VAL に
;   byte 0 = type ID (TYPE_LONG など)
;   byte 1 = payload lo
;   byte 2 = payload hi
;   byte 3 = payload ext (未使用)
;
; 対応 operand type: IS_CONST / IS_CV / IS_TMP_VAR / IS_VAR
; =============================================================================

resolve_op1:
    LDY #21                ; op1_type
    LDA (VM_PC), Y
    ; dispatch
    CMP #IS_CONST
    BNE :+
    LDY #0                 ; op1.constant
    JMP res_const
:
    CMP #IS_CV
    BNE :+
    LDY #0                 ; op1.var
    JMP res_cv
:
    CMP #IS_TMP_VAR
    BNE :+
    LDY #0
    JMP res_tmp
:
    CMP #IS_VAR
    BNE :+
    LDY #0
    JMP res_tmp
:
    ; IS_UNUSED
    LDA #0
    STA OP1_VAL
    STA OP1_VAL+1
    STA OP1_VAL+2
    STA OP1_VAL+3
    RTS

resolve_op2:
    LDY #22                ; op2_type
    LDA (VM_PC), Y
    CMP #IS_CONST
    BNE :+
    LDY #4                 ; op2.constant
    JMP res_const_to_op2
:
    CMP #IS_CV
    BNE :+
    LDY #4
    JMP res_cv_to_op2
:
    CMP #IS_TMP_VAR
    BNE :+
    LDY #4
    JMP res_tmp_to_op2
:
    CMP #IS_VAR
    BNE :+
    LDY #4
    JMP res_tmp_to_op2
:
    LDA #0
    STA OP2_VAL
    STA OP2_VAL+1
    STA OP2_VAL+2
    STA OP2_VAL+3
    RTS

; ---- resolver 実装: OP1_VAL 行き ----

; Y は op*.constant のフィールド先頭オフセット (0 or 4)
res_const:
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    ; TMP0 = literal pool バイトオフセット
    CLC
    LDA VM_LITBASE
    ADC TMP0
    STA TMP0
    LDA VM_LITBASE+1
    ADC TMP0+1
    STA TMP0+1
    ; TMP0 = 16B zval の ROM アドレス
    LDY #8                 ; zval.u1.type_info (下位 1B = type)
    LDA (TMP0), Y
    STA OP1_VAL
    LDY #0
    LDA (TMP0), Y
    STA OP1_VAL+1
    LDY #1
    LDA (TMP0), Y
    STA OP1_VAL+2
    LDA #0
    STA OP1_VAL+3
    RTS

res_cv:
    LDA (VM_PC), Y         ; op1.var lo (= slot * 16)
    LSR A                  ; slot * 8
    LSR A                  ; slot * 4
    CLC
    ADC VM_CVBASE
    STA TMP0
    LDA VM_CVBASE+1
    ADC #0
    STA TMP0+1
    LDY #0
    LDA (TMP0), Y
    STA OP1_VAL
    INY
    LDA (TMP0), Y
    STA OP1_VAL+1
    INY
    LDA (TMP0), Y
    STA OP1_VAL+2
    INY
    LDA (TMP0), Y
    STA OP1_VAL+3
    RTS

res_tmp:
    LDA (VM_PC), Y         ; op1.var lo
    LSR A
    LSR A
    CLC
    ADC VM_TMPBASE
    STA TMP0
    LDA VM_TMPBASE+1
    ADC #0
    STA TMP0+1
    LDY #0
    LDA (TMP0), Y
    STA OP1_VAL
    INY
    LDA (TMP0), Y
    STA OP1_VAL+1
    INY
    LDA (TMP0), Y
    STA OP1_VAL+2
    INY
    LDA (TMP0), Y
    STA OP1_VAL+3
    RTS

; ---- resolver 実装: OP2_VAL 行き ----

res_const_to_op2:
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    CLC
    LDA VM_LITBASE
    ADC TMP0
    STA TMP0
    LDA VM_LITBASE+1
    ADC TMP0+1
    STA TMP0+1
    LDY #8
    LDA (TMP0), Y
    STA OP2_VAL
    LDY #0
    LDA (TMP0), Y
    STA OP2_VAL+1
    LDY #1
    LDA (TMP0), Y
    STA OP2_VAL+2
    LDA #0
    STA OP2_VAL+3
    RTS

res_cv_to_op2:
    LDA (VM_PC), Y         ; op2.var lo
    LSR A
    LSR A
    CLC
    ADC VM_CVBASE
    STA TMP0
    LDA VM_CVBASE+1
    ADC #0
    STA TMP0+1
    LDY #0
    LDA (TMP0), Y
    STA OP2_VAL
    INY
    LDA (TMP0), Y
    STA OP2_VAL+1
    INY
    LDA (TMP0), Y
    STA OP2_VAL+2
    INY
    LDA (TMP0), Y
    STA OP2_VAL+3
    RTS

res_tmp_to_op2:
    LDA (VM_PC), Y
    LSR A
    LSR A
    CLC
    ADC VM_TMPBASE
    STA TMP0
    LDA VM_TMPBASE+1
    ADC #0
    STA TMP0+1
    LDY #0
    LDA (TMP0), Y
    STA OP2_VAL
    INY
    LDA (TMP0), Y
    STA OP2_VAL+1
    INY
    LDA (TMP0), Y
    STA OP2_VAL+2
    INY
    LDA (TMP0), Y
    STA OP2_VAL+3
    RTS

; =============================================================================
; result writer: RESULT_VAL を result スロット (IS_TMP_VAR / IS_VAR / IS_CV) に書く
; =============================================================================
write_result:
    LDY #23                ; result_type
    LDA (VM_PC), Y
    CMP #IS_TMP_VAR
    BEQ wr_tmp
    CMP #IS_VAR
    BEQ wr_tmp
    CMP #IS_CV
    BEQ wr_cv
    ; IS_UNUSED 他: 何もしない
    RTS

wr_tmp:
    LDY #8                 ; result.var lo
    LDA (VM_PC), Y
    LSR A
    LSR A
    CLC
    ADC VM_TMPBASE
    STA TMP0
    LDA VM_TMPBASE+1
    ADC #0
    STA TMP0+1
    JMP wr_store

wr_cv:
    LDY #8
    LDA (VM_PC), Y
    LSR A
    LSR A
    CLC
    ADC VM_CVBASE
    STA TMP0
    LDA VM_CVBASE+1
    ADC #0
    STA TMP0+1
    ; fall through

wr_store:
    LDY #0
    LDA RESULT_VAL
    STA (TMP0), Y
    INY
    LDA RESULT_VAL+1
    STA (TMP0), Y
    INY
    LDA RESULT_VAL+2
    STA (TMP0), Y
    INY
    LDA RESULT_VAL+3
    STA (TMP0), Y
    RTS

; =============================================================================
; ハンドラ
; =============================================================================

; -----------------------------------------------------------------------------
; ZEND_ECHO: op1 (IS_STRING / IS_LONG) を PPU nametable へ
;
; 毎回 PPUADDR = PPU_CURSOR をセットし直す (fgets で rendering を ON/OFF する際
; に PPU 内部 latch 状態が壊れるため)。書き終わったら PPU_CURSOR を書いたバイト
; 数だけ進める。PPUMASK=0 (強制 blanking) 中にのみ呼ぶこと。
; -----------------------------------------------------------------------------
handle_zend_echo:
    JSR resolve_op1

    ; PPUADDR = PPU_CURSOR
    BIT PPUSTATUS
    LDA PPU_CURSOR+1
    STA PPUADDR
    LDA PPU_CURSOR
    STA PPUADDR

    LDA OP1_VAL            ; type
    CMP #TYPE_STRING
    BEQ echo_string
    CMP #TYPE_LONG
    BEQ echo_long
    JMP handle_unimpl

echo_string:
    ; OP1_VAL+1/+2 = ops.bin 内の zend_string へのオフセット
    CLC
    LDA OP1_VAL+1
    ADC #<OPS_BASE
    STA TMP0
    LDA OP1_VAL+2
    ADC #>OPS_BASE
    STA TMP0+1
    ; len @ zend_string + 16 (下位 1B)
    LDY #16
    LDA (TMP0), Y
    STA TMP1
    ; val @ zend_string + 24
    CLC
    LDA TMP0
    ADC #24
    STA TMP0
    LDA TMP0+1
    ADC #0
    STA TMP0+1
    ; TMP1 バイトを PPUDATA に書く
    LDY #0
echo_str_loop:
    CPY TMP1
    BEQ echo_str_done
    LDA (TMP0), Y
    STA PPUDATA
    INY
    BNE echo_str_loop
echo_str_done:
    ; PPU_CURSOR += TMP1
    CLC
    LDA PPU_CURSOR
    ADC TMP1
    STA PPU_CURSOR
    LDA PPU_CURSOR+1
    ADC #0
    STA PPU_CURSOR+1
    JMP advance

echo_long:
    ; OP1_VAL+1/+2 = 16bit signed int
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1
    JSR print_int16
    ; pi_count = 書いたバイト数
    CLC
    LDA PPU_CURSOR
    ADC pi_count
    STA PPU_CURSOR
    LDA PPU_CURSOR+1
    ADC #0
    STA PPU_CURSOR+1
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_RETURN: PPUMASK 有効化 → halt
; -----------------------------------------------------------------------------
handle_zend_return:
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL
    LDA #%00001110
    STA PPUMASK
halt:
    JMP halt

; -----------------------------------------------------------------------------
; ZEND_ASSIGN: op1 (IS_CV) <- op2 の値
; -----------------------------------------------------------------------------
handle_zend_assign:
    JSR resolve_op2
    ; op1 の CV スロットに OP2_VAL を書く
    LDY #21
    LDA (VM_PC), Y         ; op1_type
    CMP #IS_CV
    BEQ assign_to_cv
    JMP handle_unimpl

assign_to_cv:
    LDY #0
    LDA (VM_PC), Y         ; op1.var lo
    LSR A
    LSR A
    CLC
    ADC VM_CVBASE
    STA TMP0
    LDA VM_CVBASE+1
    ADC #0
    STA TMP0+1
    LDY #0
    LDA OP2_VAL
    STA (TMP0), Y
    INY
    LDA OP2_VAL+1
    STA (TMP0), Y
    INY
    LDA OP2_VAL+2
    STA (TMP0), Y
    INY
    LDA OP2_VAL+3
    STA (TMP0), Y
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_ADD: result = op1 + op2 (16bit 整数)
; -----------------------------------------------------------------------------
handle_zend_add:
    JSR resolve_op1
    JSR resolve_op2
    ; 両方 IS_LONG 前提
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE add_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE add_type_err
    CLC
    LDA OP1_VAL+1
    ADC OP2_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    ADC OP2_VAL+2
    STA RESULT_VAL+2
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
add_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_SUB: result = op1 - op2
; -----------------------------------------------------------------------------
handle_zend_sub:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE sub_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE sub_type_err
    SEC
    LDA OP1_VAL+1
    SBC OP2_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    SBC OP2_VAL+2
    STA RESULT_VAL+2
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
sub_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_QM_ASSIGN: result = op1 (値コピー)
; -----------------------------------------------------------------------------
handle_zend_qm_assign:
    JSR resolve_op1
    LDA OP1_VAL
    STA RESULT_VAL
    LDA OP1_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    STA RESULT_VAL+2
    LDA OP1_VAL+3
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_JMP: op1.num に格納された op_index に無条件分岐
; -----------------------------------------------------------------------------
handle_zend_jmp:
    LDY #0
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    JSR jmp_compute_pc
    JMP main_loop

; -----------------------------------------------------------------------------
; ZEND_JMPZ: op1 が falsy のとき op2.num の op_index に分岐
; -----------------------------------------------------------------------------
handle_zend_jmpz:
    JSR resolve_op1
    JSR is_truthy
    BEQ jmpz_take
    JMP advance
jmpz_take:
    LDY #4
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    JSR jmp_compute_pc
    JMP main_loop

; -----------------------------------------------------------------------------
; ZEND_JMPNZ: op1 が truthy のとき op2.num の op_index に分岐
; -----------------------------------------------------------------------------
handle_zend_jmpnz:
    JSR resolve_op1
    JSR is_truthy
    BNE jmpnz_take
    JMP advance
jmpnz_take:
    LDY #4
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    JSR jmp_compute_pc
    JMP main_loop

; -----------------------------------------------------------------------------
; ZEND_IS_SMALLER: result = (op1 < op2) ? TYPE_TRUE : TYPE_FALSE (16bit 符号付き)
; -----------------------------------------------------------------------------
handle_zend_is_smaller:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE is_smaller_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE is_smaller_err
    ; 16bit 符号付き比較: op1 - op2 を計算して符号判定
    SEC
    LDA OP1_VAL+1
    SBC OP2_VAL+1
    LDA OP1_VAL+2
    SBC OP2_VAL+2
    BVC is_smaller_no_ov
    EOR #$80                ; オーバーフロー時は符号反転
is_smaller_no_ov:
    BMI is_smaller_true
    ; false
    LDA #TYPE_FALSE
    JMP is_smaller_store
is_smaller_true:
    LDA #TYPE_TRUE
is_smaller_store:
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
is_smaller_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_IS_EQUAL: 同じ型 + 同じ payload なら TYPE_TRUE、それ以外 TYPE_FALSE
; -----------------------------------------------------------------------------
handle_zend_is_equal:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP OP2_VAL
    BNE is_equal_false
    LDA OP1_VAL+1
    CMP OP2_VAL+1
    BNE is_equal_false
    LDA OP1_VAL+2
    CMP OP2_VAL+2
    BNE is_equal_false
    LDA #TYPE_TRUE
    JMP is_equal_store
is_equal_false:
    LDA #TYPE_FALSE
is_equal_store:
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; is_truthy: OP1_VAL の真偽を A に返す (truthy=1 / falsy=0)
; 末尾の LDA が Z フラグをセットするので、呼び出し側は BEQ / BNE を使える
; -----------------------------------------------------------------------------
is_truthy:
    LDA OP1_VAL              ; type
    CMP #TYPE_TRUE
    BEQ is_truthy_yes
    CMP #TYPE_STRING
    BEQ is_truthy_yes        ; 文字列は常に truthy とみなす (簡略化)
    CMP #TYPE_LONG
    BEQ is_truthy_long
    ; NULL / FALSE / UNDEF / その他 → falsy
    LDA #0
    RTS
is_truthy_long:
    LDA OP1_VAL+1
    ORA OP1_VAL+2
    BEQ is_truthy_no         ; lval == 0 → falsy
    LDA #1
    RTS
is_truthy_yes:
    LDA #1
    RTS
is_truthy_no:
    LDA #0
    RTS

; -----------------------------------------------------------------------------
; jmp_compute_pc: TMP0 (op_index) から VM_PC = OPS_FIRST_OP + op_index * 24 を計算
; -----------------------------------------------------------------------------
jmp_compute_pc:
    ; TMP0 を TMP2 に保存
    LDA TMP0
    STA TMP2
    LDA TMP0+1
    STA TMP2+1
    ; TMP0 <<= 3 (= op_index * 8)
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ; TMP1 = TMP0 (= op_index * 8)
    LDA TMP0
    STA TMP1
    LDA TMP0+1
    STA TMP1+1
    ; TMP0 <<= 1 (= op_index * 16)
    ASL TMP0
    ROL TMP0+1
    ; TMP0 += TMP1 (= op_index * 24)
    CLC
    LDA TMP0
    ADC TMP1
    STA TMP0
    LDA TMP0+1
    ADC TMP1+1
    STA TMP0+1
    ; VM_PC = OPS_FIRST_OP + TMP0
    CLC
    LDA TMP0
    ADC #<OPS_FIRST_OP
    STA VM_PC
    LDA TMP0+1
    ADC #>OPS_FIRST_OP
    STA VM_PC+1
    RTS

; -----------------------------------------------------------------------------
; handle_unimpl / version_mismatch
; -----------------------------------------------------------------------------
handle_unimpl:
    BIT PPUSTATUS
    LDA #$3F
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$16                ; エラー時の backdrop (暗い紫)
    STA PPUDATA
    LDA #%00001110
    STA PPUMASK
unimpl_halt:
    JMP unimpl_halt

version_mismatch:
    BIT PPUSTATUS
    LDA #$3F
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$06                ; 赤 backdrop
    STA PPUDATA
    LDA #%00001110
    STA PPUMASK
version_halt:
    JMP version_halt

; =============================================================================
; print_int16: TMP0 (16bit signed) を decimal ASCII に変換して PPUDATA に書く
;
; 書いたバイト数を pi_count に返す (echo_long から PPU_CURSOR 更新に使用)
; 注意: この関数は PPUMASK=0 (強制 blanking) 中にのみ呼んでよい
; =============================================================================
print_int16:
    LDA #0
    STA pi_count
    ; 符号判定
    LDA TMP0+1
    BPL pi_positive
    ; 負: '-' を出して絶対値化
    LDA #'-'
    STA PPUDATA
    INC pi_count
    SEC
    LDA #0
    SBC TMP0
    STA TMP0
    LDA #0
    SBC TMP0+1
    STA TMP0+1

pi_positive:
    LDY #0                 ; 桁数カウンタ
pi_div_loop:
    JSR div_tmp0_by_10     ; A = 余り, TMP0 = 商
    PHA
    INY
    LDA TMP0
    ORA TMP0+1
    BNE pi_div_loop

    ; Y = 桁数を pi_count に加算
    TYA
    CLC
    ADC pi_count
    STA pi_count

    ; スタックを逆順に pop して '0'+digit を PPUDATA へ
pi_pop_loop:
    PLA
    CLC
    ADC #'0'
    STA PPUDATA
    DEY
    BNE pi_pop_loop
    RTS

; -----------------------------------------------------------------------------
; div_tmp0_by_10: TMP0 (unsigned 16bit) を 10 で割る
;   出力: TMP0 = 商, A = 余り (0-9)
;   shift-and-subtract unsigned divide。X は破壊される。
; -----------------------------------------------------------------------------
div_tmp0_by_10:
    LDA #0                 ; 余り
    LDX #16
div10_loop:
    ASL TMP0
    ROL TMP0+1
    ROL A
    CMP #10
    BCC div10_skip
    SBC #10
    INC TMP0               ; 商の bit 0 を立てる
div10_skip:
    DEX
    BNE div10_loop
    RTS

; =============================================================================
; NESPHP_FGETS: fgets(STDIN) 相当 → コントローラ読み取り
;
; 動作:
;   1. rendering を有効化 (プレーヤーが画面を見られるように)
;   2. 全ボタンが離されるまで待機 (直前の押下が残っていたら取り直し)
;   3. いずれかのボタンが押されるまで待機
;   4. 優先度順 (A > B > Select > Start > U > D > L > R) で 1 ボタンを決定
;   5. rendering を無効化 (続く echo が強制 blanking 中に書けるように)
;   6. 対応する button_str_X の ROM オフセットを RESULT_VAL (IS_STRING) に入れ、
;      write_result で result スロットに書き戻す
; =============================================================================
handle_nesphp_fgets:
    JSR enable_rendering

    ; Wait all buttons released
fgets_wait_release:
    JSR read_controller
    LDA buttons
    BNE fgets_wait_release

    ; Wait for a press
fgets_wait_press:
    JSR read_controller
    LDA buttons
    BEQ fgets_wait_press

    ; Map pressed button to button_str_X (優先度順)
    LDA buttons
    AND #$80
    BEQ :+
    LDA #<(button_str_a - OPS_BASE)
    LDX #>(button_str_a - OPS_BASE)
    JMP fgets_got_str
:
    LDA buttons
    AND #$40
    BEQ :+
    LDA #<(button_str_b - OPS_BASE)
    LDX #>(button_str_b - OPS_BASE)
    JMP fgets_got_str
:
    LDA buttons
    AND #$20
    BEQ :+
    LDA #<(button_str_sel - OPS_BASE)
    LDX #>(button_str_sel - OPS_BASE)
    JMP fgets_got_str
:
    LDA buttons
    AND #$10
    BEQ :+
    LDA #<(button_str_start - OPS_BASE)
    LDX #>(button_str_start - OPS_BASE)
    JMP fgets_got_str
:
    LDA buttons
    AND #$08
    BEQ :+
    LDA #<(button_str_u - OPS_BASE)
    LDX #>(button_str_u - OPS_BASE)
    JMP fgets_got_str
:
    LDA buttons
    AND #$04
    BEQ :+
    LDA #<(button_str_d - OPS_BASE)
    LDX #>(button_str_d - OPS_BASE)
    JMP fgets_got_str
:
    LDA buttons
    AND #$02
    BEQ :+
    LDA #<(button_str_l - OPS_BASE)
    LDX #>(button_str_l - OPS_BASE)
    JMP fgets_got_str
:
    LDA #<(button_str_r - OPS_BASE)
    LDX #>(button_str_r - OPS_BASE)
    ; fall through

fgets_got_str:
    STA RESULT_VAL+1
    STX RESULT_VAL+2
    LDA #TYPE_STRING
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3

    JSR disable_rendering_restore
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; read_controller: 1 コントローラの状態を buttons に読み込む
;   buttons = bit7..bit0 = A B Select Start Up Down Left Right
; -----------------------------------------------------------------------------
read_controller:
    LDA #$01
    STA $4016
    LDA #$00
    STA $4016
    LDX #8
read_ctrl_loop:
    LDA $4016
    LSR A                  ; bit 0 → C
    ROL buttons            ; C → buttons bit 0
    DEX
    BNE read_ctrl_loop
    RTS

; -----------------------------------------------------------------------------
; enable_rendering / disable_rendering_restore
;
; enable_rendering: PPUSCROLL を (0,0) にして PPUMASK を有効化
; disable_rendering_restore: PPUMASK=0 にして PPUADDR を PPU_CURSOR に戻す
; -----------------------------------------------------------------------------
enable_rendering:
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL
    LDA #%00001110
    STA PPUMASK
    RTS

disable_rendering_restore:
    LDA #0
    STA PPUMASK
    BIT PPUSTATUS
    LDA PPU_CURSOR+1
    STA PPUADDR
    LDA PPU_CURSOR
    STA PPUADDR
    RTS

; =============================================================================
; Pre-baked 1 文字 zend_string (ボタン対応)
;
; 各ブロックは spec/01-rom-format.md の zend_string 24B ヘッダ + content + null
; のレイアウトに準拠 (fgets が返す IS_STRING の参照先として)。
; =============================================================================
.macro ONE_CHAR_ZSTR ch
    .byte 0, 0, 0, 0                       ; gc.refcount
    .byte $40, 0, 0, 0                     ; gc.type_info (IMMUTABLE)
    .byte 0, 0, 0, 0, 0, 0, 0, 0           ; hash
    .byte 1, 0, 0, 0, 0, 0, 0, 0           ; len = 1
    .byte ch, 0                            ; val + null
    .byte 0, 0                             ; 4B アラインのパディング
.endmacro

button_str_a:     ONE_CHAR_ZSTR 'A'
button_str_b:     ONE_CHAR_ZSTR 'B'
button_str_sel:   ONE_CHAR_ZSTR 'S'
button_str_start: ONE_CHAR_ZSTR 'T'
button_str_u:     ONE_CHAR_ZSTR 'U'
button_str_d:     ONE_CHAR_ZSTR 'D'
button_str_l:     ONE_CHAR_ZSTR 'L'
button_str_r:     ONE_CHAR_ZSTR 'R'

; -----------------------------------------------------------------------------
; NMI / IRQ (MVP 未使用)
; -----------------------------------------------------------------------------
nmi:
    RTI

irq:
    RTI

; -----------------------------------------------------------------------------
; パレットデータ
; -----------------------------------------------------------------------------
palette_data:
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00

; =============================================================================
; VECTORS
; =============================================================================
.segment "VECTORS"
    .word nmi
    .word reset
    .word irq

; =============================================================================
; CHARS
; =============================================================================
.segment "CHARS"
    .incbin "chr/font.chr"
