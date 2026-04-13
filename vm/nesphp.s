; =============================================================================
; nesphp VM — 6502 アセンブリ本体
;
; spec/03-vm-dispatch.md  dispatch 設計
; spec/01-rom-format.md   ROM バイナリ仕様
; spec/02-ram-layout.md   RAM マップ
; spec/06-display-io.md   PPU 表示フロー
;
; MVP: ZEND_ECHO と ZEND_RETURN の 2 命令のみ対応
; =============================================================================

; --- Zend 定数 (PHP 8.4.6) ---
ZEND_ECHO    = 136      ; 0x88
ZEND_RETURN  = 62       ; 0x3E

; --- PPU レジスタ ---
PPUCTRL      = $2000
PPUMASK      = $2001
PPUSTATUS    = $2002
PPUSCROLL    = $2005
PPUADDR      = $2006
PPUDATA      = $2007
DMC_FREQ     = $4010

; --- ROM / op_array 配置 ---
; ops.bin は PRG の先頭 ($8000) に incbin される
OPS_BASE     = $8000
; op_array header は 16 バイト: 先頭 16 バイトを読み飛ばした位置が op[0]
OPS_FIRST_OP = $8010
; op_array header のフィールド
HDR_NUM_OPS        = OPS_BASE + 0
HDR_LITERALS_OFF   = OPS_BASE + 2
HDR_NUM_LITERALS   = OPS_BASE + 4
HDR_NUM_CVS        = OPS_BASE + 6
HDR_NUM_TMPS       = OPS_BASE + 8
HDR_PHP_MAJOR      = OPS_BASE + 10
HDR_PHP_MINOR      = OPS_BASE + 11

; --- ナメテーブル書き込み開始位置: 中央付近 (row 14, col 10 = $21EA) ---
NAMETABLE_START = $21EA

; =============================================================================
; ゼロページ VM レジスタ
; =============================================================================
.segment "ZEROPAGE"

VM_PC:       .res 2   ; 現在の zend_op の ROM アドレス
VM_SP:       .res 2   ; VM データスタックトップ (MVP 未使用)
VM_LITBASE:  .res 2   ; literals 配列の ROM アドレス
PPU_CURSOR:  .res 2   ; nametable 書き込み位置 (MVP 未使用、PPU 内部アドレスで代替)
TMP0:        .res 2   ; 汎用作業
TMP1:        .res 2   ; 汎用作業

; =============================================================================
; iNES ヘッダ
; =============================================================================
.segment "HEADER"
    .byte "NES", $1A
    .byte 2          ; PRG-ROM = 2 * 16KB = 32KB (NROM-256)
    .byte 1          ; CHR-ROM = 1 * 8KB
    .byte %00000000  ; Flags 6: horizontal mirroring, mapper 0 low nibble
    .byte %00000000  ; Flags 7: mapper 0 high nibble
    .byte 0, 0, 0, 0, 0, 0, 0, 0

; =============================================================================
; OPS セグメント: serializer が出した ops.bin を貼る
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
    STX PPUCTRL            ; NMI 無効、VRAM +1 incr、BG/sprite pattern table 0
    STX PPUMASK            ; 強制 blanking
    STX DMC_FREQ           ; DMC IRQ 無効

    ; 1 回目の VBL 待ち
    BIT PPUSTATUS
:   BIT PPUSTATUS
    BPL :-

    ; WRAM クリア ($0000-$07FF)
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

    ; パレット書き込み ($3F00-$3F1F)
    BIT PPUSTATUS          ; latch reset
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

    ; ネームテーブルを ' ' で埋める (32*30 = 960 バイト + attribute 64)
    BIT PPUSTATUS
    LDA #$20
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$20               ; ASCII ' '
    LDX #4                 ; 4 * 256 = 1024 バイト
    LDY #0
clear_nt_outer:
clear_nt_inner:
    STA PPUDATA
    INY
    BNE clear_nt_inner
    DEX
    BNE clear_nt_outer

    ; op_array header の php_version を確認 (遠距離ブランチのため BEQ+JMP)
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

    ; VM_PC = OPS_FIRST_OP ($8010)
    LDA #<OPS_FIRST_OP
    STA VM_PC
    LDA #>OPS_FIRST_OP
    STA VM_PC+1

    ; VM_LITBASE = OPS_BASE + literals_off (header の 16bit 値)
    CLC
    LDA HDR_LITERALS_OFF
    ADC #<OPS_BASE
    STA VM_LITBASE
    LDA HDR_LITERALS_OFF+1
    ADC #>OPS_BASE
    STA VM_LITBASE+1

    ; PPU_CURSOR を NAMETABLE_START にセット
    LDA #<NAMETABLE_START
    STA PPU_CURSOR
    LDA #>NAMETABLE_START
    STA PPU_CURSOR+1

    ; PPUADDR を PPU_CURSOR にセット (強制 blanking 中なので自由に書ける)
    BIT PPUSTATUS          ; latch reset
    LDA PPU_CURSOR+1
    STA PPUADDR
    LDA PPU_CURSOR
    STA PPUADDR

    JMP main_loop

; -----------------------------------------------------------------------------
; VM メインループ: fetch-dispatch
; -----------------------------------------------------------------------------
main_loop:
    LDY #20                ; zend_op.opcode オフセット
    LDA (VM_PC), Y
    CMP #ZEND_ECHO
    BEQ handle_zend_echo
    CMP #ZEND_RETURN
    BEQ handle_zend_return
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; handle_zend_echo: op1 (IS_CONST) の zend_string を nametable に書く
; -----------------------------------------------------------------------------
handle_zend_echo:
    ; TMP0 = op1.constant (literals 内バイトオフセット)
    LDY #0
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1

    ; TMP0 = VM_LITBASE + TMP0 (literal zval の絶対アドレス)
    CLC
    LDA VM_LITBASE
    ADC TMP0
    STA TMP0
    LDA VM_LITBASE+1
    ADC TMP0+1
    STA TMP0+1

    ; literal zval.value.str: 下位 2 バイトが ops.bin 内の zend_string オフセット
    LDY #0
    LDA (TMP0), Y
    STA TMP1
    INY
    LDA (TMP0), Y
    STA TMP1+1

    ; TMP0 = OPS_BASE + TMP1 (zend_string の絶対アドレス)
    CLC
    LDA TMP1
    ADC #<OPS_BASE
    STA TMP0
    LDA TMP1+1
    ADC #>OPS_BASE
    STA TMP0+1

    ; len = zend_string @ offset 16 (下位 8bit)
    LDY #16
    LDA (TMP0), Y
    STA TMP1               ; len (MVP は 1 バイトで十分)

    ; val[] = zend_string @ offset 24 (TMP0 += 24)
    CLC
    LDA TMP0
    ADC #24
    STA TMP0
    LDA TMP0+1
    ADC #0
    STA TMP0+1

    ; val[i] を PPUDATA に書き出す (PPUADDR は既に PPU_CURSOR にセット済)
    LDY #0
echo_write_loop:
    CPY TMP1
    BEQ echo_write_done
    LDA (TMP0), Y
    STA PPUDATA
    INY
    BNE echo_write_loop
echo_write_done:

    ; advance VM_PC += 24
    CLC
    LDA VM_PC
    ADC #24
    STA VM_PC
    BCC :+
    INC VM_PC+1
:
    JMP main_loop

; -----------------------------------------------------------------------------
; handle_zend_return: スクロール初期化 + PPUMASK 有効化 + halt
; -----------------------------------------------------------------------------
handle_zend_return:
    ; スクロール (0, 0)
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL          ; X
    STA PPUSCROLL          ; Y

    ; PPUMASK: 背景表示 + 左端 8 ピクセルも表示 + 色通常
    LDA #%00001110
    STA PPUMASK

halt:
    JMP halt

; -----------------------------------------------------------------------------
; handle_unimpl: 未実装 opcode に当たったら halt (MVP は黒画面で停止のみ)
; -----------------------------------------------------------------------------
handle_unimpl:
    LDA #0
    STA PPUMASK
unimpl_halt:
    JMP unimpl_halt

; -----------------------------------------------------------------------------
; version_mismatch: php_version が 8.4 でなかったら赤画面 (backdrop 変更) で halt
; -----------------------------------------------------------------------------
version_mismatch:
    BIT PPUSTATUS
    LDA #$3F
    STA PPUADDR
    LDA #$00
    STA PPUADDR
    LDA #$06               ; 赤系の backdrop
    STA PPUDATA
    LDA #%00001110
    STA PPUMASK
version_halt:
    JMP version_halt

; -----------------------------------------------------------------------------
; NMI / IRQ (MVP 未使用)
; -----------------------------------------------------------------------------
nmi:
    RTI

irq:
    RTI

; -----------------------------------------------------------------------------
; パレットデータ (背景=黒, 文字=白)
; -----------------------------------------------------------------------------
palette_data:
    .byte $0F, $30, $10, $00   ; BG palette 0
    .byte $0F, $30, $10, $00   ; BG palette 1
    .byte $0F, $30, $10, $00   ; BG palette 2
    .byte $0F, $30, $10, $00   ; BG palette 3
    .byte $0F, $30, $10, $00   ; sprite palette 0
    .byte $0F, $30, $10, $00   ; sprite palette 1
    .byte $0F, $30, $10, $00   ; sprite palette 2
    .byte $0F, $30, $10, $00   ; sprite palette 3

; =============================================================================
; VECTORS セグメント: NMI / RESET / IRQ
; =============================================================================
.segment "VECTORS"
    .word nmi
    .word reset
    .word irq

; =============================================================================
; CHARS セグメント: CHR-ROM (フォント)
; =============================================================================
.segment "CHARS"
    .incbin "chr/font.chr"
