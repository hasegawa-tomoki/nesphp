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
ZEND_NOP              = 0
ZEND_ADD              = 1
ZEND_SUB              = 2
ZEND_IS_IDENTICAL     = 16
ZEND_IS_NOT_IDENTICAL = 17
ZEND_IS_EQUAL         = 18
ZEND_IS_NOT_EQUAL     = 19
ZEND_IS_SMALLER       = 20
ZEND_ASSIGN           = 22
ZEND_QM_ASSIGN        = 31
ZEND_JMP              = 42
ZEND_JMPZ             = 43
ZEND_JMPNZ            = 44
ZEND_RETURN           = 62
ZEND_ECHO             = 136

; --- nesphp カスタム opcode (0xE0-0xFF は Zend 未使用領域) ---
NESPHP_FGETS        = $F0
NESPHP_NES_PUT      = $F1
NESPHP_NES_SPRITE   = $F2
NESPHP_NES_PUTS     = $F3
NESPHP_NES_CLS      = $F4
NESPHP_NES_CHR_SPR  = $F5   ; MMC1 CHR bank 1 ($1000, sprite 用 4KB bank)
NESPHP_NES_CHR_BG   = $F6   ; MMC1 CHR bank 0 ($0000, BG 用 4KB bank)

; --- OAM DMA レジスタ ---
OAM_DMA           = $4014
OAM_SHADOW        = $0200

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

; --- MMC1 シリアル書き込みマクロ ---
; MMC1 のレジスタは 5bit シリアルで書く: bit 0 から順に STA × 5 回。
; 5 回目の STA アドレスでレジスタが決まる ($8000=Control, $A000=CHR0,
; $C000=CHR1, $E000=PRG)。全 5 回を同じアドレスに書けば OK。
.macro MMC1_WRITE addr
    STA addr
    LSR A
    STA addr
    LSR A
    STA addr
    LSR A
    STA addr
    LSR A
    STA addr
.endmacro

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

; --- NMI PPU 書き込みキュー (Phase 3: NMI 同期書き込み) ---
; 256 バイト、length-prefix 形式で sprite_mode 中の nametable 書き込みを溜める。
; フォーマット: [addr_hi addr_lo len data[len]] の繰り返し。
NMI_QUEUE_ADDR    = $0300

; --- print_int16 用の digit バッファ (最長 "-32768" = 6 文字) ---
INT_PRINT_BUFFER  = $0600

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
buttons:        .res 1    ; 現在のボタン状態 (bit 7=A, 6=B, 5=Sel, 4=Start, 3=U, 2=D, 1=L, 0=R)
pi_count:       .res 1    ; print_int16 が書いたバイト数

; スプライトモード (0 = forced blanking, 1 = rendering + NMI on)
; 初回 nes_sprite で 1 に遷移。
; Phase 3 (NMI 同期書き込み) により、sprite_mode 中でも echo / nes_put /
; nes_puts は動く (NMI キュー経由)。nes_cls だけは依然として forced_blanking
; 専用 (1024B を 1 VBlank 予算 ~2273 cycle に収められないため)。
sprite_mode_on: .res 1

; PPUCTRL シャドウ (書き込み専用レジスタなので直前値を RAM に保持する)
;   bit 7 = NMI enable、bit 4 = BG pattern table ($0000 / $1000)、bit 3 = sprite PT
ppu_ctrl_shadow: .res 1

; NMI 書き込みキューの head (Phase 3)
;   nmi_queue_write: main CPU が append するオフセット (producer)
;   nmi_queue_read:  NMI が次に読むオフセット (consumer)
;   write == read で empty。両方 0 に戻ったらバッファ先頭から再利用できる。
nmi_queue_write: .res 1
nmi_queue_read:  .res 1

; =============================================================================
; iNES ヘッダ  (MMC1 / mapper 1, SNROM 構成)
;
; PRG-ROM 32KB (2 × 16KB), CHR-ROM 32KB (8 × 4KB), PRG-RAM 8KB (WRAM $6000)
; MMC1 により: PRG 16KB 切替 + CHR 4KB × 2 独立切替 + 8KB WRAM
; =============================================================================
.segment "HEADER"
    .byte "NES", $1A
    .byte 2                ; PRG-ROM = 2 * 16KB = 32KB
    .byte 4                ; CHR-ROM = 4 * 8KB = 32KB (MMC1 4KB mode で 8 bank)
    .byte %00010000        ; Flags 6: mapper LSB = 1 (上位 nibble), mirroring = horizontal(0)
    .byte %00000000        ; Flags 7: mapper MSB = 0
    .byte 1                ; PRG-RAM = 1 * 8KB (WRAM $6000-$7FFF)
    .byte 0, 0, 0, 0, 0, 0, 0

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
    ; PPUCTRL 初期値: bit 3 = 1 (sprite は $1000 = CHR bank 1 レジスタから取る)
    ; BG は $0000 (bit 4 = 0 = CHR bank 0 レジスタから取る)
    ; これで nes_chr_bg / nes_chr_spr が独立して動く
    LDA #%00001000
    STA PPUCTRL
    STA ppu_ctrl_shadow
    STX PPUMASK            ; 強制 blanking
    STX DMC_FREQ

    ; --- MMC1 初期化 ---
    ; まずシフトレジスタをリセット (bit 7 セットで書くと即リセット)
    LDA #$80
    STA $8000

    ; Control ($8000): CHR 4KB mode (bit4=1), PRG fix-last mode (bit3-2=11),
    ;                  horizontal mirroring (bit1-0=10)
    ;   %11110 = $1E
    LDA #$1E
    MMC1_WRITE $8000

    ; CHR bank 0 ($A000): $0000-$0FFF に 4KB bank 0 (通常フォント)
    LDA #0
    MMC1_WRITE $A000

    ; CHR bank 1 ($C000): $1000-$1FFF に 4KB bank 1 (インバースフォント)
    LDA #1
    MMC1_WRITE $C000

    ; PRG bank ($E000): $8000-$BFFF に PRG bank 0 (ops.bin), WRAM 有効 (bit4=0)
    LDA #0
    MMC1_WRITE $E000

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

    ; OAM shadow ($0200-$02FF) の y を全て $FF にして全スプライトを画面外に隠す
    ; 1 スプライト 4 バイト × 64 個 = 256B、X は y オフセットだけをたどる
    LDX #0
    LDA #$FF
hide_oam_loop:
    STA OAM_SHADOW, X
    INX
    INX
    INX
    INX
    BNE hide_oam_loop

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
    CMP #NESPHP_NES_PUT
    BNE :+
    JMP handle_nesphp_nes_put
:
    CMP #NESPHP_NES_SPRITE
    BNE :+
    JMP handle_nesphp_nes_sprite
:
    CMP #NESPHP_NES_PUTS
    BNE :+
    JMP handle_nesphp_nes_puts
:
    CMP #NESPHP_NES_CLS
    BNE :+
    JMP handle_nesphp_nes_cls
:
    CMP #NESPHP_NES_CHR_SPR
    BNE :+
    JMP handle_nesphp_nes_chr_spr
:
    CMP #NESPHP_NES_CHR_BG
    BNE :+
    JMP handle_nesphp_nes_chr_bg
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
    CMP #ZEND_IS_IDENTICAL
    BNE :+
    JMP handle_zend_is_equal       ; 簡略化: === と == を同じ実装で
:
    CMP #ZEND_IS_NOT_EQUAL
    BNE :+
    JMP handle_zend_is_not_equal
:
    CMP #ZEND_IS_NOT_IDENTICAL
    BNE :+
    JMP handle_zend_is_not_equal
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
; Phase 3 以降:
;   sprite_mode_on = 0: forced_blanking 中の直接書き込み (従来動作)
;   sprite_mode_on = 1: NMI キューに積む → 次 VBlank で反映
;
; どちらのパスも ppu_write_bytes ヘルパに集約。エントリ時の入力:
;   TMP0  = PPU 書き込みアドレス (TMP0 = lo, TMP0+1 = hi)
;   TMP1  = 6502 側ソースポインタ
;   TMP2  = バイト長
; を揃えて JSR する。
; -----------------------------------------------------------------------------
handle_zend_echo:
    JSR resolve_op1

    LDA OP1_VAL            ; type
    CMP #TYPE_STRING
    BEQ echo_string
    CMP #TYPE_LONG
    BEQ echo_long
    JMP handle_unimpl

echo_string:
    ; OP1_VAL+1/+2 = ops.bin 内 zend_string へのオフセット
    ; TMP1 を zend_string 絶対アドレスにセット
    CLC
    LDA OP1_VAL+1
    ADC #<OPS_BASE
    STA TMP1
    LDA OP1_VAL+2
    ADC #>OPS_BASE
    STA TMP1+1
    ; len @ zend_string + 16 (下位 1B) → TMP2
    LDY #16
    LDA (TMP1), Y
    STA TMP2
    ; TMP1 += 24 で val[] 先頭へ進める
    CLC
    LDA TMP1
    ADC #24
    STA TMP1
    LDA TMP1+1
    ADC #0
    STA TMP1+1
    JMP echo_write

echo_long:
    ; OP1_VAL+1/+2 = 16bit signed int を print_int16 でバッファに展開
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1
    JSR print_int16
    ; TMP1 = INT_PRINT_BUFFER, TMP2 = pi_count
    LDA #<INT_PRINT_BUFFER
    STA TMP1
    LDA #>INT_PRINT_BUFFER
    STA TMP1+1
    LDA pi_count
    STA TMP2
    ; fall through

echo_write:
    ; TMP0 を PPU_CURSOR (書き込み先アドレス) にセット
    LDA PPU_CURSOR
    STA TMP0
    LDA PPU_CURSOR+1
    STA TMP0+1
    JSR ppu_write_bytes
    ; PPU_CURSOR += TMP2
    CLC
    LDA PPU_CURSOR
    ADC TMP2
    STA PPU_CURSOR
    LDA PPU_CURSOR+1
    ADC #0
    STA PPU_CURSOR+1
    JMP advance

; -----------------------------------------------------------------------------
; ppu_write_bytes: TMP0 (addr) / TMP1 (src ptr) / TMP2 (len) を PPU に書く
;
; sprite_mode_on = 0: PPUADDR/PPUDATA 直書き (forced_blanking 想定)
; sprite_mode_on = 1: enqueue_ppu_nt で NMI キューに積む
;
; 使用レジスタ: A / X / Y 破壊 (RTS で戻る)
; TMP0-2 の内容は保持する (enqueue 経由時は enqueue_ppu_nt が TMP0 を保持)
; -----------------------------------------------------------------------------
ppu_write_bytes:
    LDA sprite_mode_on
    BEQ pwb_direct
    JMP enqueue_ppu_nt     ; tail call (RTS で上位に戻る)
pwb_direct:
    BIT PPUSTATUS
    LDA TMP0+1
    STA PPUADDR
    LDA TMP0
    STA PPUADDR
    LDY #0
pwb_loop:
    CPY TMP2
    BEQ pwb_done
    LDA (TMP1), Y
    STA PPUDATA
    INY
    BNE pwb_loop
pwb_done:
    RTS

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
; ZEND_IS_EQUAL / ZEND_IS_IDENTICAL: 同じ型 + 同じ値なら TYPE_TRUE。文字列は
; zend_string の content 比較 (len + val[] のバイト比較) を行う。
; =, === の違い (PHP の type juggling) は未対応。
; -----------------------------------------------------------------------------
handle_zend_is_equal:
    JSR resolve_op1
    JSR resolve_op2
    JSR values_equal_content
    BEQ iseq_false
    LDA #TYPE_TRUE
    JMP iseq_store
iseq_false:
    LDA #TYPE_FALSE
iseq_store:
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_IS_NOT_EQUAL / ZEND_IS_NOT_IDENTICAL
; -----------------------------------------------------------------------------
handle_zend_is_not_equal:
    JSR resolve_op1
    JSR resolve_op2
    JSR values_equal_content
    BNE isne_false
    LDA #TYPE_TRUE
    JMP isne_store
isne_false:
    LDA #TYPE_FALSE
isne_store:
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; values_equal_content: OP1_VAL と OP2_VAL を比較
;   出力: A = 1 (equal) / 0 (not equal)、Z フラグも同期
;   - 型が違えば不一致
;   - TYPE_STRING なら zend_string の len + val[] を比較
;   - それ以外は payload バイト (1-2) を比較
; -----------------------------------------------------------------------------
values_equal_content:
    LDA OP1_VAL
    CMP OP2_VAL
    BEQ vec_type_ok
    LDA #0                 ; 型違い
    RTS
vec_type_ok:
    CMP #TYPE_STRING
    BEQ vec_string
    ; 非文字列: payload lo/hi を比較
    LDA OP1_VAL+1
    CMP OP2_VAL+1
    BNE vec_false
    LDA OP1_VAL+2
    CMP OP2_VAL+2
    BNE vec_false
    LDA #1
    RTS
vec_false:
    LDA #0
    RTS

vec_string:
    ; 両方の zend_string の絶対アドレスを TMP0 / TMP1 に
    CLC
    LDA OP1_VAL+1
    ADC #<OPS_BASE
    STA TMP0
    LDA OP1_VAL+2
    ADC #>OPS_BASE
    STA TMP0+1
    CLC
    LDA OP2_VAL+1
    ADC #<OPS_BASE
    STA TMP1
    LDA OP2_VAL+2
    ADC #>OPS_BASE
    STA TMP1+1
    ; 長さ比較 (offset 16 の 1 バイトだけ見る。MVP は短い文字列のみ)
    LDY #16
    LDA (TMP0), Y
    CMP (TMP1), Y
    BNE vec_false
    TAX                    ; X = 残りバイト数
    BEQ vec_eq             ; 長さ 0 → 等しい
    LDY #24                ; val[] 先頭
vec_loop:
    LDA (TMP0), Y
    CMP (TMP1), Y
    BNE vec_false
    INY
    DEX
    BNE vec_loop
vec_eq:
    LDA #1
    RTS

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
; print_int16: TMP0 (16bit signed) を decimal ASCII に変換して
;              INT_PRINT_BUFFER ($0600-) に書き出す
;
; 出力バイト数を pi_count に返す (呼び出し元が PPU 直書き or NMI キューに
; 流し込む)。最長 6 バイト ("-32768")。Phase 3 以前はここで直接 PPUDATA を
; 叩いていたが、sprite_mode でも使えるようにバッファ出力に切り替えた。
; =============================================================================
print_int16:
    LDA #0
    STA pi_count
    LDX #0                 ; X = INT_PRINT_BUFFER 内のオフセット
    ; 符号判定
    LDA TMP0+1
    BPL pi_positive
    ; 負: '-' を先頭に出して絶対値化
    LDA #'-'
    STA INT_PRINT_BUFFER, X
    INX
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

    ; スタックを逆順に pop して '0'+digit を INT_PRINT_BUFFER へ
pi_pop_loop:
    PLA
    CLC
    ADC #'0'
    STA INT_PRINT_BUFFER, X
    INX
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
    ; sprite_mode_on == 0 のときだけ rendering を一時 ON にする
    LDA sprite_mode_on
    BNE fgets_skip_enable
    JSR enable_rendering
fgets_skip_enable:

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

    ; sprite_mode_on なら rendering を維持 (スプライト表示継続)
    LDA sprite_mode_on
    BNE fgets_skip_disable
    JSR disable_rendering_restore
fgets_skip_disable:
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
; NESPHP_NES_PUT: nametable (x, y) に 1 文字を書く
;
; op1 = x (IS_CV / IS_CONST, IS_LONG 値)
; op2 = y (IS_CV / IS_CONST, IS_LONG 値)
; extended_value = 文字 literal のバイトオフセット (IS_CONST, TYPE_STRING or TYPE_LONG)
;
; 前提: PPUMASK = 0 (強制 blanking) 中に呼ぶこと。fgets 以外は常に forced blanking
; なので OK。PPU 内部アドレスは書き換わるので、次の echo が再 set する想定。
; =============================================================================
handle_nesphp_nes_put:
    JSR resolve_op1        ; OP1_VAL = x
    JSR resolve_op2        ; OP2_VAL = y

    ; extended_value (offset 12) → zval アドレスを TMP0 に
    LDY #12
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
    LDY #8                 ; u1.type_info
    LDA (TMP0), Y
    CMP #TYPE_STRING
    BEQ np_from_string
    CMP #TYPE_LONG
    BEQ np_from_long
    JMP handle_unimpl

np_from_string:
    ; value.str = zend_string への offset (TMP1 に展開)
    LDY #0
    LDA (TMP0), Y
    STA TMP1
    INY
    LDA (TMP0), Y
    STA TMP1+1
    CLC
    LDA TMP1
    ADC #<OPS_BASE
    STA TMP1
    LDA TMP1+1
    ADC #>OPS_BASE
    STA TMP1+1
    ; val[0] @ offset 24 を INT_PRINT_BUFFER[0] に保存
    LDY #24
    LDA (TMP1), Y
    STA INT_PRINT_BUFFER
    JMP np_addr

np_from_long:
    ; value.lval 下位 1 バイト = 文字コード
    LDY #0
    LDA (TMP0), Y
    STA INT_PRINT_BUFFER

np_addr:
    ; nametable アドレス = $2000 + y*32 + x → TMP0
    LDA OP2_VAL+1
    STA TMP0
    LDA #0
    STA TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    CLC
    LDA OP1_VAL+1
    ADC TMP0
    STA TMP0
    LDA #0
    ADC TMP0+1
    STA TMP0+1
    CLC
    LDA TMP0
    ADC #$00
    STA TMP0
    LDA TMP0+1
    ADC #$20
    STA TMP0+1

    ; TMP1 = INT_PRINT_BUFFER, TMP2 = 1 で ppu_write_bytes に委譲
    LDA #<INT_PRINT_BUFFER
    STA TMP1
    LDA #>INT_PRINT_BUFFER
    STA TMP1+1
    LDA #1
    STA TMP2
    JSR ppu_write_bytes
    JMP advance

; =============================================================================
; NESPHP_NES_PUTS: nametable (x, y) から文字列リテラルを書く
;
; op1 = x (IS_CV / IS_CONST, IS_LONG 値)
; op2 = y (IS_CV / IS_CONST, IS_LONG 値)
; extended_value = 文字列 literal のバイトオフセット (IS_CONST, TYPE_STRING)
;
; 前提: nes_put と同様、PPUMASK = 0 (強制 blanking) 中に呼ぶこと。
; 行折り返しは行わず、呼び出し側で (x, y) を与える。len は 8bit 有効 (max 255)。
; =============================================================================
handle_nesphp_nes_puts:
    JSR resolve_op1        ; OP1_VAL = x
    JSR resolve_op2        ; OP2_VAL = y

    ; extended_value (offset 12) = zval (16B) のバイトオフセット
    LDY #12
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
    ; TMP0 = zval アドレス
    LDY #8                 ; u1.type_info
    LDA (TMP0), Y
    CMP #TYPE_STRING
    BNE nps_type_err

    ; value.str (bytes 0-1) = ops.bin 内 zend_string への offset
    LDY #0
    LDA (TMP0), Y
    STA TMP1
    INY
    LDA (TMP0), Y
    STA TMP1+1
    ; TMP1 += OPS_BASE
    CLC
    LDA TMP1
    ADC #<OPS_BASE
    STA TMP1
    LDA TMP1+1
    ADC #>OPS_BASE
    STA TMP1+1
    ; len @ zend_string + 16 (下位 1B)
    LDY #16
    LDA (TMP1), Y
    STA TMP2               ; TMP2 = 書き込みバイト数 (8bit)
    ; val @ zend_string + 24
    CLC
    LDA TMP1
    ADC #24
    STA TMP1
    LDA TMP1+1
    ADC #0
    STA TMP1+1

    ; nametable addr = $2000 + y*32 + x, store in TMP0
    LDA OP2_VAL+1
    STA TMP0
    LDA #0
    STA TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ; + x
    CLC
    LDA OP1_VAL+1
    ADC TMP0
    STA TMP0
    LDA #0
    ADC TMP0+1
    STA TMP0+1
    ; + $2000
    LDA TMP0+1
    CLC
    ADC #$20
    STA TMP0+1

    ; TMP0=addr, TMP1=src ptr, TMP2=len で ppu_write_bytes に委譲
    ; (forced_blanking は直書き、sprite_mode は NMI キューに積む)
    JSR ppu_write_bytes
    JMP advance

nps_type_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_CLS: nametable 0 ($2000-$23FF) を空白 ($20) で埋める
;
; 引数なし。PPU_CURSOR を NAMETABLE_START に戻す。
;
; sprite_mode_on == 0 (forced_blanking):
;   PPUMASK は既に 0 なのでそのまま PPUADDR / PPUDATA で 1024 バイト直書き
;
; sprite_mode_on == 1 (Phase 3.1: brief force-blanking):
;   1 回だけ rendering を OFF にして clear、次 VBlank で rendering を再 ON。
;   1024 バイト (~5000 cycle) は 1 VBlank (~2273 cycle) 予算を超えるため、
;   NMI 同期キューではなく「一時的に画面を消して強制 blanking 化」する方式。
;   可視効果は 1-2 フレームの黒フラッシュ (スライド遷移の自然なトランジション)。
;
;   clear 中に NMI が発火して flush_nmi_queue が PPUADDR を上書きすると困る
;   ので、PPUCTRL bit 7 を一時クリアして NMI を無効化。終わったら元に戻す。
;   無効化期間中に OAM DMA が止まるので、復帰直前に手動で 1 回補う。
; =============================================================================
handle_nesphp_nes_cls:
    LDA sprite_mode_on
    BNE cls_sprite_mode    ; sprite_mode → brief force-blanking パス

; --- forced_blanking パス (従来どおり) ---
    BIT PPUSTATUS
    LDA #$20
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$20               ; space タイル
    LDX #4                 ; 4 ページ × 256B = 1024B ($2000-$23FF 全域)
    LDY #0
cls_outer:
cls_inner:
    STA PPUDATA
    INY
    BNE cls_inner
    DEX
    BNE cls_outer

    ; PPU_CURSOR を既定位置に戻す
    LDA #<NAMETABLE_START
    STA PPU_CURSOR
    LDA #>NAMETABLE_START
    STA PPU_CURSOR+1
    JMP advance

; --- sprite_mode パス: brief force-blanking (Phase 3.1) ---
cls_sprite_mode:
    ; 1. ppu_ctrl_shadow を 6502 スタックに退避 (後で bit 7 を復元するため)
    LDA ppu_ctrl_shadow
    PHA

    ; 2. NMI 無効化: bit 7 クリアして PPUCTRL と shadow を更新
    AND #$7F
    STA ppu_ctrl_shadow
    STA PPUCTRL

    ; 3. rendering 無効化 (PPU を強制 blanking 状態に)
    LDA #0
    STA PPUMASK

    ; 4. 1024 バイトの clear ループ (forced_blanking パスと同じ)
    BIT PPUSTATUS
    LDA #$20
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$20
    LDX #4
    LDY #0
cls_sb_outer:
cls_sb_inner:
    STA PPUDATA
    INY
    BNE cls_sb_inner
    DEX
    BNE cls_sb_outer

    ; 5. 次 VBlank 開始を待つ (NMI 無効化済みなので VBlank flag が勝手に
    ;    クリアされない)
    BIT PPUSTATUS          ; まず latch & flag を一度読んで捨てる
cls_wait_vb:
    BIT PPUSTATUS
    BPL cls_wait_vb        ; bit 7 が立つまでループ

    ; 6. OAM DMA を手動実行 (NMI 無効化中の OAM 更新を補う)
    LDA #>OAM_SHADOW
    STA OAM_DMA

    ; 7. scroll をリセット
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL

    ; 8. rendering 再有効化 (BG + sprite)
    LDA #%00011110
    STA PPUMASK

    ; 9. ppu_ctrl_shadow を復元、PPUCTRL に書き戻す (bit 7 復帰で NMI 再有効)
    PLA
    STA ppu_ctrl_shadow
    STA PPUCTRL

    ; 10. PPU_CURSOR を既定位置に戻す
    LDA #<NAMETABLE_START
    STA PPU_CURSOR
    LDA #>NAMETABLE_START
    STA PPU_CURSOR+1
    JMP advance

; =============================================================================
; NESPHP_NES_CHR_SPR (0xF5): sprite 用 4KB CHR bank を切り替える
;
; 引数: op1 = 4KB bank 番号 (int literal 0-7, IS_CONST)
;
; MMC1 CHR bank 1 register ($C000) に書く → PPU $1000-$1FFF にマッピング。
; PPUCTRL bit 3 = 1 (reset で設定済み) なので sprite はここを参照する。
; BG 側 (CHR bank 0, $0000) には影響しない。
; =============================================================================
handle_nesphp_nes_chr_spr:
    JSR resolve_op1
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE chr_spr_err
    LDA OP1_VAL+1
    AND #$07               ; 0-7 にクランプ (32KB / 4KB = 8 banks)
    MMC1_WRITE $C000
    JMP advance

chr_spr_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_CHR_BG (0xF6): BG 用 4KB CHR bank を切り替える
;
; 引数: op1 = 4KB bank 番号 (int literal 0-7, IS_CONST)
;
; MMC1 CHR bank 0 register ($A000) に書く → PPU $0000-$0FFF にマッピング。
; PPUCTRL bit 4 = 0 (reset で設定済み) なので BG はここを参照する。
; sprite 側 (CHR bank 1, $1000) には影響しない。
;
; 旧 CNROM 時代は PPUCTRL bit 4 のトグルだったが、MMC1 昇格により
; CHR bank レジスタ直接操作に変更。より細かい粒度 (4KB 単位、0-7) で
; 任意の bank を指定できるようになった。
; =============================================================================
handle_nesphp_nes_chr_bg:
    JSR resolve_op1
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE chr_bg_err
    LDA OP1_VAL+1
    AND #$07               ; 0-7 にクランプ
    MMC1_WRITE $A000
    JMP advance

chr_bg_err:
    JMP handle_unimpl

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

; =============================================================================
; NESPHP_NES_SPRITE: sprite 0 の OAM shadow を更新
;
; op1            = x (IS_CV / IS_CONST、IS_LONG 値)
; op2            = y (IS_CV / IS_CONST、IS_LONG 値)
; extended_value = tile literal の byte offset (IS_CONST、IS_LONG 想定)
;
; 初回呼び出し時に rendering + NMI を有効化し、以降は OAM shadow 書き込みだけ。
; NMI ハンドラが毎 VBlank で OAM DMA を実行するので、書き換えは即座に反映される。
; =============================================================================
handle_nesphp_nes_sprite:
    LDA sprite_mode_on
    BNE nss_mode_ready
    JSR enable_sprite_mode
nss_mode_ready:
    JSR resolve_op1        ; OP1_VAL = x
    JSR resolve_op2        ; OP2_VAL = y

    ; extended_value から tile を decode
    LDY #12
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
    ; TMP0 = zval 絶対アドレス
    LDY #8
    LDA (TMP0), Y          ; type
    CMP #TYPE_LONG
    BNE nss_type_err       ; tile は IS_LONG (整数リテラル) 前提
    LDY #0
    LDA (TMP0), Y
    STA TMP2               ; TMP2 = tile

    ; OAM shadow (sprite 0) を更新
    ;   $0200 = y, $0201 = tile, $0202 = attr=0, $0203 = x
    LDA OP2_VAL+1
    STA OAM_SHADOW + 0     ; y
    LDA TMP2
    STA OAM_SHADOW + 1     ; tile
    LDA #0
    STA OAM_SHADOW + 2     ; attr (palette 0, front, no flip)
    LDA OP1_VAL+1
    STA OAM_SHADOW + 3     ; x

    JMP advance

nss_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; enable_sprite_mode: 初回 nes_sprite から呼ばれる遷移処理
;
;   1. VBlank 待ち
;   2. 初回 OAM DMA (非表示スプライト 64 個を反映)
;   3. PPUSCROLL をリセット
;   4. PPUCTRL 経由で NMI を enable
;   5. PPUMASK で BG + sprite レンダリング
;   6. sprite_mode_on = 1
; -----------------------------------------------------------------------------
enable_sprite_mode:
    ; VBlank 待ち
    BIT PPUSTATUS
:   BIT PPUSTATUS
    BPL :-

    ; 初回 OAM DMA
    LDA #>OAM_SHADOW       ; $02
    STA OAM_DMA

    ; scroll (0, 0)
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL

    ; PPUCTRL: NMI enable。BG pattern table bit は shadow の現在値を継承する
    LDA ppu_ctrl_shadow
    ORA #%10000000
    STA ppu_ctrl_shadow
    STA PPUCTRL

    ; PPUMASK: BG + sprite 有効、左端 8 ピクセルも表示
    LDA #%00011110
    STA PPUMASK

    LDA #1
    STA sprite_mode_on
    RTS

; =============================================================================
; NMI ハンドラ: OAM DMA + NMI キュー flush + スクロールリセット
;
; Phase 3 で `flush_nmi_queue` が追加され、sprite_mode 中の nametable 書き込み
; がここで実行されるようになった。メインループは「キューに積む → 何もしない」
; で済み、実際の PPU 書き込みは次の VBlank まで遅延される。
;
; TMP0-TMP2 は flush_nmi_queue が使うので save/restore する。
; =============================================================================
nmi:
    PHA
    TXA
    PHA
    TYA
    PHA
    LDA TMP0
    PHA
    LDA TMP0+1
    PHA
    LDA TMP1
    PHA
    LDA TMP1+1
    PHA
    LDA TMP2
    PHA

    ; OAM DMA: $0200-$02FF → PPU OAM
    LDA #>OAM_SHADOW
    STA OAM_DMA

    ; sprite_mode 中に積まれた nametable 書き込みを VBlank 中に反映
    JSR flush_nmi_queue

    ; scroll をリセット (PPUADDR 書き込みで v レジスタが汚染される可能性への対策)
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL

    PLA
    STA TMP2
    PLA
    STA TMP1+1
    PLA
    STA TMP1
    PLA
    STA TMP0+1
    PLA
    STA TMP0
    PLA
    TAY
    PLA
    TAX
    PLA
    RTI

; =============================================================================
; flush_nmi_queue: NMI_QUEUE に積まれた nametable 書き込みを PPU に流し込む
;
; キューフォーマット (byte stream):
;   [addr_hi] [addr_lo] [len] [data_0 ... data_{len-1}]  ← 1 エントリ
;   ... 次のエントリ ...
;
; read/write は uint8 でモノトニックに増加 (256 の自然 wrap)。read == write で
; 空。read は NMI が、write は main CPU が排他的に更新し、リセットは行わない。
; NMI_QUEUE_ADDR = $0300 のページ境界整列で X レジスタの wrap と一致するので、
; エントリがバッファ終端をまたいでも透過的に参照できる。
;
; この関数は NMI ハンドラ内から呼ばれる前提。flush 中は main は suspended で
; あり race はない。VBlank 予算 (~2273 cycles) を超えないよう、1 エントリは
; 最大 3 + 253 = 256 バイトまで (= キュー全体)。
; =============================================================================
flush_nmi_queue:
    LDX nmi_queue_read
    CPX nmi_queue_write
    BEQ fnq_done                 ; 空
fnq_loop:
    BIT PPUSTATUS
    LDA NMI_QUEUE_ADDR, X        ; addr_hi
    STA PPUADDR
    INX
    LDA NMI_QUEUE_ADDR, X        ; addr_lo
    STA PPUADDR
    INX
    LDA NMI_QUEUE_ADDR, X        ; len
    STA TMP0
    INX
    LDY #0
fnq_inner:
    CPY TMP0
    BEQ fnq_entry_done
    LDA NMI_QUEUE_ADDR, X
    STA PPUDATA
    INX
    INY
    BNE fnq_inner
fnq_entry_done:
    CPX nmi_queue_write
    BNE fnq_loop                 ; まだエントリがある (== なら空)
fnq_done:
    STX nmi_queue_read           ; read を write に追いつかせる
    RTS

; =============================================================================
; enqueue_ppu_nt: NMI キューに nametable 書き込みエントリを追加する
;
; 入力:
;   TMP0 / TMP0+1 = PPU アドレス (TMP0 = lo, TMP0+1 = hi)
;   TMP1 / TMP1+1 = 6502 側ソースデータへのポインタ
;   TMP2          = データ長 (1-253)
;
; リングバッファ (256B、モノトニック head)。空き容量 = (read - write - 1) & 255。
; 必要容量 (3 + TMP2) 未満なら NMI drain を busy-wait。
;
; 呼び出し側は sprite_mode_on = 1 であること (さもないと NMI が走らず busy wait
; が無限ループになる)。
;
; ## race-free 設計
;
; - main CPU (producer) は write のみ、NMI (consumer) は read のみ更新
; - 両方とも uint8 でモノトニック増加、256 で自然 wrap
; - main の「空き容量チェック」時に NMI が read を増やしても、free が
;   過小評価されるだけで書き込みは安全側 (不必要な wait は発生し得るが
;   バッファ破壊はない)
; - append 中に NMI が fire しても、NMI は commit 前の write を見るので
;   新エントリには触れない。main は X を cache 済みなので wrap なしで継続
; =============================================================================
enqueue_ppu_nt:
epn_check:
    ; 空き容量 = (read - write - 1) mod 256
    SEC
    LDA nmi_queue_read
    SBC nmi_queue_write
    SEC
    SBC #1
    ; A = free
    CMP TMP2
    BCC epn_wait                 ; free < len → 待つ
    SEC
    SBC TMP2
    CMP #3
    BCC epn_wait                 ; free - len < 3 → ヘッダ入らない
    ; fits: append
    LDX nmi_queue_write
    LDA TMP0+1                   ; addr_hi
    STA NMI_QUEUE_ADDR, X
    INX
    LDA TMP0                     ; addr_lo
    STA NMI_QUEUE_ADDR, X
    INX
    LDA TMP2                     ; len
    STA NMI_QUEUE_ADDR, X
    INX
    LDY #0
epn_copy:
    CPY TMP2
    BEQ epn_commit
    LDA (TMP1), Y
    STA NMI_QUEUE_ADDR, X
    INX
    INY
    BNE epn_copy
epn_commit:
    STX nmi_queue_write          ; 原子的 commit (この 1 STA まで NMI は古い write を見る)
    RTS

epn_wait:
    ; NMI が flush_nmi_queue で read を進めてくれるのを待つ
    JMP epn_check

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
