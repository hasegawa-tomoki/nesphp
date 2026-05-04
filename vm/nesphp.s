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
ZEND_MUL              = 3
ZEND_DIV              = 4
ZEND_MOD              = 5
ZEND_SL               = 6
ZEND_SR               = 7
ZEND_BW_OR            = 9
ZEND_BW_AND           = 10
ZEND_IS_IDENTICAL     = 16
ZEND_IS_NOT_IDENTICAL = 17
ZEND_IS_EQUAL         = 18
ZEND_IS_NOT_EQUAL     = 19
ZEND_IS_SMALLER       = 20
ZEND_IS_SMALLER_OR_EQUAL = 21
ZEND_ASSIGN           = 22
ZEND_QM_ASSIGN        = 31
ZEND_PRE_INC          = 34
ZEND_PRE_DEC          = 35
ZEND_POST_INC         = 36
ZEND_POST_DEC         = 37
ZEND_JMP              = 42
ZEND_JMPZ             = 43
ZEND_JMPNZ            = 44
ZEND_INIT_ARRAY       = 71
ZEND_ADD_ARRAY_ELEMENT = 72
ZEND_FETCH_DIM_R      = 81
ZEND_COUNT            = 90
ZEND_OP_DATA          = 138
ZEND_ASSIGN_DIM       = 147
ZEND_RETURN           = 62
ZEND_ECHO             = 136

; --- nesphp カスタム opcode (0xE0-0xFF は Zend 未使用領域) ---
NESPHP_NES_PEEK_EXT     = $E8   ; PRG-RAM bank 2 ($6000+offset) から 1 byte 読出
NESPHP_NES_PEEK16_EXT   = $E9   ; PRG-RAM bank 2 から 2 byte LE 読出
NESPHP_NES_POKE_EXT     = $EA   ; PRG-RAM bank 2 に 1 byte 書込
NESPHP_NES_POKESTR_EXT  = $EB   ; PRG-RAM bank 2 に文字列の生バイトを bulk copy
NESPHP_NES_PEEK     = $EC   ; user RAM ($0700+offset) から 1 byte 読出、IS_LONG 返す
NESPHP_NES_PEEK16   = $ED   ; user RAM[$ofs] | (user RAM[$ofs+1] << 8) を IS_LONG 返却
NESPHP_NES_POKE     = $EE   ; user RAM ($0700+offset) に 1 byte 書込
NESPHP_NES_POKESTR  = $EF   ; user RAM ($0700+offset) に文字列の生バイトを bulk copy
NESPHP_FGETS        = $F0
NESPHP_NES_PUT      = $F1
NESPHP_NES_SPRITE   = $F2
NESPHP_NES_PUTS     = $F3
NESPHP_NES_CLS      = $F4
NESPHP_NES_CHR_SPR  = $F5   ; MMC1 CHR bank 1 ($1000, sprite 用 4KB bank)
NESPHP_NES_CHR_BG   = $F6   ; MMC1 CHR bank 0 ($0000, BG 用 4KB bank)
NESPHP_NES_BG_COLOR = $F7   ; PPU $3F00 背景色
NESPHP_NES_PALETTE  = $F8   ; パレット設定 (id, c1, c2, c3)
NESPHP_NES_ATTR     = $F9   ; attribute table 設定 (x, y, pal)
NESPHP_NES_VSYNC    = $FA   ; 次 VBlank まで spin (sprite_mode 未設定時は自動 enable)
NESPHP_NES_BTN      = $FB   ; コントローラ状態を IS_LONG (下位 1B = buttons bitmask) で返す
NESPHP_NES_SPRITE_ATTR = $FC ; OAM[$idx*4+2] = attr (palette / flip / 優先度)
NESPHP_NES_RAND     = $FD   ; 16-bit Galois LFSR を 1 step 進めて IS_LONG で返す
NESPHP_NES_SRAND    = $FE   ; LFSR 状態を $seed に設定 ($seed = 0 は内部で 1 に置換)
NESPHP_NES_PUTINT   = $FF   ; nametable (x, y) に 5-char 右詰め unsigned int を書く

; --- User RAM (peek/poke 用) ---
; CV symbol table と同じ位置 ($0700-$07FF) を再利用。コンパイル完了後は
; CV symbol table は不要なので、runtime phase で 256B の汎用 byte 領域として
; 使う。生バイト単位で読み書きできる (zval オーバーヘッドなし)。
USER_RAM_BASE       = $0700
USER_RAM_SIZE       = $0100      ; 256 bytes

; --- User RAM Extended (peek/poke_ext 用) ---
; PRG-RAM bank 3 の全 8KB を汎用 byte 領域として確保。bank 切替で使う。
; bank 3 へのアクセスは nes_*_ext 系 intrinsic に閉じ込め、入口で BANK3、
; 出口で BANK0 に戻す。ARR_POOL (bank 1) / STR_POOL (bank 2) / op_array (bank 0)
; には影響しない。
USER_RAM_EXT_BASE   = $6000      ; bank 3 が見えてるときの先頭
USER_RAM_EXT_SIZE   = $2000      ; 8192 bytes

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
TYPE_ARRAY      = 7

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

; --- PRG-RAM bank 切替マクロ (SXROM) ---
; $A000 reg の bit 2-3 = PRG-RAM bank (CHR-RAM 環境では bit 0-1 は no-op)。
; bank 1 の値 = %00000100 (bit 2 set)、bank 0 の値 = %00000000。
; ARR_POOL を触る handler が入口で BANK1、出口で BANK0 を呼ぶ。
; A レジスタを clobber する。両マクロは ~30 cycles (LDA + 5 STA + 4 LSR)。
.macro PRG_RAM_BANK1
    LDA #%00000100
    MMC1_WRITE $A000
.endmacro

.macro PRG_RAM_BANK2
    LDA #%00001000
    MMC1_WRITE $A000
.endmacro

.macro PRG_RAM_BANK3
    LDA #%00001100
    MMC1_WRITE $A000
.endmacro

.macro PRG_RAM_BANK0
    LDA #0
    MMC1_WRITE $A000
.endmacro

; --- op_array 配置 ---
; OPS_BASE は VM が実行時に読み出す op_array の先頭アドレス = PRG-RAM 先頭。
; reset で compile_and_emit が PHP ソースをコンパイルしてここに emit する。
OPS_BASE     = $6000
OPS_FIRST_OP = $6010

; PHP ソースのカートリッジ上の位置 (MMC1 PRG bank 0, $8000-$BFFF)。
; pack_src.php が出した src.bin のレイアウト:
;   $8000  u16 src_len
;   $8002+ ASCII src body (生 PHP ソース、<?php タグ含む)
;
; 文字列リテラルは PHP ソース内の `"..."` バイト列をそのまま val[] として使う
; (zend_string 構造体は持たない)。コンパイラは 16B zval の value bytes 0-1 に
; OPS_BASE 相対 16bit offset、bytes 2-3 に length を書く。VM は
; `ADC #<OPS_BASE` で復元した ROM アドレスから len バイト読む。
PHP_SRC_LEN  = $8000
PHP_SRC_BODY = $8002

; 一時的な literal バッファ (コンパイル中のみ使用、後に OPS_BASE + literals_off へ memcpy)
; $7D00 に置くと op_array は $6010-$7CFF (≒ 7408 byte ≒ 308 ops) まで使える。
; literal dedux (cmp_emit_zval_long_value) で同値を再利用するので、staging
; capacity は ($7F80-$7D00)/16 = 40 zval で典型的なゲームには足りる。
CMP_LIT_STAGE    = $7D00

; 文字列リテラル用プール: cln_string が `\xHH` エスケープを解釈して decoded bytes を
; ここへ書き、zval は OPS_BASE 相対でこの領域を指す。staging area $7C80-$7F7F
; (zval 48 entries 分) とは衝突しない $7F80-$7FFF (128B) を使う。
STR_POOL_BASE    = $7F80
STR_POOL_END     = $8000

; Array runtime プール: PRG-RAM bank 1 ($6000-$7FFF when bank 1 mapped) を専有。
; 全 8KB が ARR_POOL に使える (旧 720B → 11x 拡大、tetris 等でメモリ圧改善)。
; 各配列は header 4B (count, capacity) + 要素 (capacity × 16B zval)。
; ARR_POOL_HEAD は init_array_pool で ARR_POOL_BASE にセットされ、追記型で成長、
; ARR_POOL_END に達したら err_screen。
;
; bank 1 は ARR_POOL 専用。dispatch loop は bank 0 (op_array) を読むため、
; ARR_POOL を触る handler だけが入口で bank 1 へ切替、出口で bank 0 へ復帰する。
; 切替は MMC1_WRITE $A000 (bit 2-3 = PRG-RAM bank、CHR-RAM 環境では bit 0-1
; は no-op)。bank 1 の値 = %00000100、bank 0 の値 = 0。
ARR_POOL_BASE    = $6000
ARR_POOL_END     = $8000

; CV シンボル表: WRAM の $0700 以降。1 エントリ 4B ([len, name_ptr_lo, name_ptr_hi, pad])
; 最大 64 CV スロット (= $0700-$07FF 全域、256B 使用)。コンパイル完了後は USER_RAM
; (peek/poke 用) と同領域だが、runtime phase では table の値は不要なので上書き OK。
CMP_CV_TABLE     = $0700

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

; --- attribute table の RAM shadow (64 バイト) ---
; nes_attr の read-modify-write で使用。attribute table 1 byte は 4 つの
; 2×2 タイルブロックのパレット情報を共有するため、1 ブロックだけ変えるには
; 他の 3 ブロックの値を壊さないようにする必要がある。
ATTR_SHADOW       = $0608

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
; 初回 nes_sprite_at で 1 に遷移。
; Phase 3 (NMI 同期書き込み) により、sprite_mode 中でも echo / nes_put /
; nes_puts は動く (NMI キュー経由)。nes_cls だけは依然として forced_blanking
; 専用 (1024B を 1 VBlank 予算 ~2273 cycle に収められないため)。
sprite_mode_on: .res 1

; SXROM PRG-RAM 32KB の現在 bank (0-3)。$A000 reg の bit 2-3 が PRG-RAM
; bank select。CHR-RAM 環境では bit 0-1 (CHR bank) は無効なので、
; $A000 への書込値 = (cur_prg_ram_bank << 2)。
; 起動時は 0 (デフォルト bank、現行コード互換)。
; ARR_POOL を bank 1 に逃すコミット (b) 以降で実際に切替が発生する。
cur_prg_ram_bank: .res 1

; NMI が VBlank ごとに INC するフレームカウンタ (nes_vsync 同期用、8bit wrap OK)
vblank_frame:   .res 1

; nes_rand 用 16-bit Galois LFSR 状態 (周期 65535、tap = $B400)
; reset で 1 に初期化、nes_srand($seed = 0) は内部で 1 に置換 (0 は退化点)
rand_state:     .res 2

; --- On-NES コンパイラ状態 (compile_and_emit 実行中のみ valid) ---
; コンパイル完了後は全て未使用。以降 reset が WRAM を既読のまま VM に引き渡す。
CMP_SRC_PTR:      .res 2    ; ソース現在位置 (PHP_SRC_BODY..)
CMP_SRC_END:      .res 2    ; ソース終端 (one-past-last)
CMP_LINE:         .res 2    ; 現在行 (1-origin、エラー表示用)
CMP_COL:          .res 2    ; 現在列 (1-origin、エラー表示用)
CMP_OP_HEAD:      .res 2    ; 次に zend_op を書く PRG-RAM アドレス
CMP_LIT_HEAD:     .res 2    ; 次に zval を書く PRG-RAM アドレス (CMP_LIT_STAGE から成長)
CMP_OP_COUNT:    .res 2    ; emit 済み opcode 数
CMP_LIT_COUNT:    .res 2    ; emit 済み literal 数
CMP_TMP_COUNT:    .res 1    ; 確保済み TMP スロット数 (算術結果や fgets result 等)
CMP_CV_COUNT:     .res 1    ; 確保済み CV スロット数
CMP_TOK_KIND:     .res 1    ; 現在のトークン種別 (TK_*)
CMP_TOK_PTR:      .res 2    ; トークン開始 ROM アドレス (STRING/IDENT/CV 時)
CMP_TOK_LEN:      .res 1    ; トークン長 (≤ 255)
CMP_TOK_VALUE:    .res 2    ; TK_INT: パース結果の 16bit 整数値
CMP_INTRINSIC_ID: .res 1    ; 解決された intrinsic 番号 (INT_* 定数)
CMP_ARG_COUNT:    .res 1    ; 関数呼び出しの現在引数数 (0..4)
CMP_ARG_LITS:     .res 8    ; 引数 operand 値 (4 引数 × 2B、byte i*2 = arg[i] lo, i*2+1 = hi)
CMP_ARG_TYPES:    .res 4    ; 引数の operand 型 (IS_CONST / IS_CV / IS_TMP_VAR / ARG_STDIN_SENTINEL)
CMP_ASSIGN_SLOT:  .res 1    ; assign_stmt 実行中の LHS CV slot
CMP_INCDEC_SLOT:  .res 1    ; PRE/POST INC/DEC の対象 CV slot (ネスト対応で ASSIGN とは別)
CMP_EXPR_TYPE:    .res 1    ; parse_primary/expr の結果 operand type
CMP_EXPR_VAL:     .res 2    ; parse_primary/expr の結果 operand 値 (16bit)
CMP_LHS_TYPE:     .res 1    ; 二項演算の左オペランド type (一時退避)
CMP_LHS_VAL:      .res 2    ; 二項演算の左オペランド 値
CMP_BP_TOP:       .res 1    ; backpatch stack pointer (0..8)
CMP_BP_STACK:     .res 16   ; backpatch stack: 8 エントリ × 2B (patch 対象の PRG-RAM アドレス)
CMP_FOR_LOOP_TOP:  .res 2   ; for: loop_top op_index (cond の先頭)
CMP_FOR_UPD_START: .res 2   ; for: update 部の先頭 op_index
CMP_LOGIC_SLOT:    .res 1   ; &&/|| の結果を受ける TMP slot
CMP_LOGIC_DONE:    .res 2   ; &&/|| 終端 JMP の patch 対象アドレス
CMP_STRPOOL_HEAD:  .res 2   ; 文字列 pool の次書込アドレス (STR_POOL_BASE から成長)
CMP_ARR_TMP:       .res 2   ; 配列リテラル parse 中: 最新 INIT_ARRAY が返す TMP の value
CMP_ARR_PATCH:     .res 2   ; 配列リテラル parse 中: INIT_ARRAY の op1 を backpatch する位置
CMP_ARR_COUNT:     .res 1   ; 配列リテラル parse 中: 要素カウンタ (capacity として op1 に書く)
ARR_POOL_HEAD:     .res 2   ; runtime array pool の次 alloc アドレス (ARR_POOL_BASE から成長、compile_and_emit 後に init_array_pool が初期化)

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
; iNES ヘッダ  (MMC1 / mapper 1、標準 SXROM: PRG-ROM 64KB / CHR-RAM 8KB / PRG-RAM 32KB)
;
; PRG-ROM 64KB (4 × 16KB bank): bank 0 = PHPSRC, bank 1 = CHRDATA, bank 2 = 予約,
;                                bank 3 = CODE 固定
; CHR-RAM 8KB (起動時に PRG_BANK1 から PPU $0000-$1FFF へ 8KB 転送)
; PRG-RAM 32KB (4 × 8KB bank、$A000 reg の bit 2-3 で bank 切替):
;     bank 0 = op_array + literals + ARR_POOL + STR_POOL (現状維持)
;     bank 1-3 = 予約 (ARR_POOL 移行 / USER_RAM_EXT で順次活用)
; MMC1 により: PRG 16KB 切替 + CHR 4KB × 2 独立切替 + 32KB WRAM (4 bank)
; =============================================================================
.segment "HEADER"
    .byte "NES", $1A
    .byte 4                ; PRG-ROM = 4 * 16KB = 64KB
    .byte 0                ; CHR-ROM = 0 → CHR-RAM 8KB を申告
    .byte %00010000        ; Flags 6: mapper LSB = 1 (上位 nibble), mirroring = horizontal(0)
    .byte %00000000        ; Flags 7: mapper MSB = 0
    .byte 4                ; PRG-RAM = 4 * 8KB = 32KB (SXROM)
    .byte 0, 0, 0, 0, 0, 0, 0

; =============================================================================
; PHPSRC セグメント: pack_src.php が出した src.bin
;   $8000-$8001  u16 ソース長
;   $8002-$8003  pad (0)
;   $8004-       ASCII 本体 (<?php タグ除去済み)
;
; 起動時に compile_and_emit がここを読んで PRG-RAM ($6000-$7FFF) に op_array を
; emit する。VM 本体は PRG-RAM 側 (OPS_BASE = $6000) だけを見る。
; =============================================================================
.segment "PHPSRC"
    .incbin "build/src.bin"

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

    ; nes_rand の LFSR 初期値を 1 にする (0 は退化点で永遠に 0 を返すため)。
    ; ユーザが nes_srand を呼ばずに nes_rand を使ってもとりあえず動く決定列を出す。
    LDA #1
    STA rand_state
    LDA #0
    STA rand_state+1

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

    ; --- CHR-RAM 初期化 (8KB 転送 PRG_BANK1 → PPU $0000-$1FFF) ---
    ; PPU は強制 blanking 中 (PPUMASK=0)、PPUDATA 経由でいつでも書込可。
    ; PRG bank を 1 に切替して $8000-$9FFF の CHRDATA を 8KB 連続読み出し、
    ; PPUDATA ($2007) に流し込む。auto-increment が +1 で動く前提
    ; (PPUCTRL bit 2 = 0、初期化済み)。約 50-65 ms かかる (一度きり)。
    LDA #1
    MMC1_WRITE $E000           ; PRG bank 1 を $8000-$BFFF にマップ
    BIT PPUSTATUS
    LDA #$00
    STA PPUADDR                ; PPU addr hi
    STA PPUADDR                ; PPU addr lo → $0000
    LDA #$00
    STA TMP0                   ; src lo
    LDA #$80
    STA TMP0+1                 ; src = $8000 (= PRG bank 1 視点の先頭)
    LDX #$20                   ; 32 ページ × 256 byte = 8192 byte
    LDY #0
chr_copy_outer:
chr_copy_inner:
    LDA (TMP0), Y
    STA PPUDATA
    INY
    BNE chr_copy_inner
    INC TMP0+1
    DEX
    BNE chr_copy_outer
    LDA #0
    MMC1_WRITE $E000           ; PRG bank 0 (PHPSRC) に戻して compile_and_emit へ

    ; PRG-RAM ($6000-$7FFF) に op_array を配置する。
    ; Phase A (プラミング検証): ROM の ops.bin をそのまま PRG-RAM へ memcpy する
    ;                          だけのスタブ。以降の HDR_* 読み出しは $6000 系を見る。
    ; Phase B 以降: 本物のコンパイラ (PHP ソース → L3 opcode) に置き換える予定。
    JSR compile_and_emit

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

    ; runtime array pool 初期化:
    ;   ARR_POOL_HEAD = ARR_POOL_BASE (= $6000、bank 1 の先頭)
    ; bank 1 全 8KB を配列プールに使う。bank 0 (op_array) と時間的に共存するため、
    ; ARR_POOL を触る handler が動的に bank 切替する (dispatch loop は bank 0)。
    LDA #<ARR_POOL_BASE
    STA ARR_POOL_HEAD
    LDA #>ARR_POOL_BASE
    STA ARR_POOL_HEAD+1

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
    CMP #NESPHP_NES_BG_COLOR
    BNE :+
    JMP handle_nesphp_nes_bg_color
:
    CMP #NESPHP_NES_PALETTE
    BNE :+
    JMP handle_nesphp_nes_palette
:
    CMP #NESPHP_NES_ATTR
    BNE :+
    JMP handle_nesphp_nes_attr
:
    CMP #NESPHP_NES_VSYNC
    BNE :+
    JMP handle_nesphp_nes_vsync
:
    CMP #NESPHP_NES_BTN
    BNE :+
    JMP handle_nesphp_nes_btn
:
    CMP #NESPHP_NES_SPRITE_ATTR
    BNE :+
    JMP handle_nesphp_nes_sprite_attr
:
    CMP #NESPHP_NES_RAND
    BNE :+
    JMP handle_nesphp_nes_rand
:
    CMP #NESPHP_NES_SRAND
    BNE :+
    JMP handle_nesphp_nes_srand
:
    CMP #NESPHP_NES_PUTINT
    BNE :+
    JMP handle_nesphp_nes_putint
:
    CMP #NESPHP_NES_PEEK
    BNE :+
    JMP handle_nesphp_nes_peek
:
    CMP #NESPHP_NES_PEEK16
    BNE :+
    JMP handle_nesphp_nes_peek16
:
    CMP #NESPHP_NES_POKE
    BNE :+
    JMP handle_nesphp_nes_poke
:
    CMP #NESPHP_NES_POKESTR
    BNE :+
    JMP handle_nesphp_nes_pokestr
:
    CMP #NESPHP_NES_PEEK_EXT
    BNE :+
    JMP handle_nesphp_nes_peek_ext
:
    CMP #NESPHP_NES_PEEK16_EXT
    BNE :+
    JMP handle_nesphp_nes_peek16_ext
:
    CMP #NESPHP_NES_POKE_EXT
    BNE :+
    JMP handle_nesphp_nes_poke_ext
:
    CMP #NESPHP_NES_POKESTR_EXT
    BNE :+
    JMP handle_nesphp_nes_pokestr_ext
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
    CMP #ZEND_MUL
    BNE :+
    JMP handle_zend_mul
:
    CMP #ZEND_DIV
    BNE :+
    JMP handle_zend_div
:
    CMP #ZEND_MOD
    BNE :+
    JMP handle_zend_mod
:
    CMP #ZEND_BW_AND
    BNE :+
    JMP handle_zend_bw_and
:
    CMP #ZEND_BW_OR
    BNE :+
    JMP handle_zend_bw_or
:
    CMP #ZEND_SL
    BNE :+
    JMP handle_zend_sl
:
    CMP #ZEND_SR
    BNE :+
    JMP handle_zend_sr
:
    CMP #ZEND_QM_ASSIGN
    BNE :+
    JMP handle_zend_qm_assign
:
    CMP #ZEND_PRE_INC
    BNE :+
    JMP handle_zend_pre_inc
:
    CMP #ZEND_PRE_DEC
    BNE :+
    JMP handle_zend_pre_dec
:
    CMP #ZEND_POST_INC
    BNE :+
    JMP handle_zend_post_inc
:
    CMP #ZEND_POST_DEC
    BNE :+
    JMP handle_zend_post_dec
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
    CMP #ZEND_IS_SMALLER_OR_EQUAL
    BNE :+
    JMP handle_zend_is_smaller_or_equal
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
    CMP #ZEND_INIT_ARRAY
    BNE :+
    JMP handle_zend_init_array
:
    CMP #ZEND_ADD_ARRAY_ELEMENT
    BNE :+
    JMP handle_zend_add_array_element
:
    CMP #ZEND_FETCH_DIM_R
    BNE :+
    JMP handle_zend_fetch_dim_r
:
    CMP #ZEND_COUNT
    BNE :+
    JMP handle_zend_count
:
    CMP #ZEND_ASSIGN_DIM
    BNE :+
    JMP handle_zend_assign_dim
:
    CMP #ZEND_OP_DATA
    BNE :+
    JMP advance                    ; OP_DATA 単独は no-op (通常は ASSIGN_DIM が skip)
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

; cv_addr_y / tmp_addr_y: (VM_PC),Y / (VM_PC),Y+1 の 16bit op.var (slot*16) を
; /4 して CV/TMP base に加算、TMP0 に絶対スロットアドレスを返す。
; CV/TMP slot ≥ 16 (= var lo が wrap する) でも正しく動くよう 16bit で計算。
; Y は呼び出し時に lo オフセット (0 / 4 / 8)、戻り時に +1 (hi 側)。
; A 破壊。callers は Y を必要に応じて再設定すること。
cv_addr_y:
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    LSR TMP0+1
    ROR TMP0
    LSR TMP0+1
    ROR TMP0
    CLC
    LDA TMP0
    ADC VM_CVBASE
    STA TMP0
    LDA TMP0+1
    ADC VM_CVBASE+1
    STA TMP0+1
    RTS

tmp_addr_y:
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    LSR TMP0+1
    ROR TMP0
    LSR TMP0+1
    ROR TMP0
    CLC
    LDA TMP0
    ADC VM_TMPBASE
    STA TMP0
    LDA TMP0+1
    ADC VM_TMPBASE+1
    STA TMP0+1
    RTS

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
    STA OP1_VAL+1          ; value byte 0 (IS_STRING 時は ROM offset lo、IS_LONG 時は lval lo)
    LDY #1
    LDA (TMP0), Y
    STA OP1_VAL+2          ; value byte 1 (同 hi)
    LDY #2
    LDA (TMP0), Y
    STA OP1_VAL+3          ; value byte 2 (IS_STRING 時は length lo、IS_LONG 時は 0)
    RTS

res_cv:
    JSR cv_addr_y
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
    JSR tmp_addr_y
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
    LDY #2
    LDA (TMP0), Y
    STA OP2_VAL+3           ; IS_STRING 時は length lo、他は 0
    RTS

res_cv_to_op2:
    JSR cv_addr_y
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
    JSR tmp_addr_y
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
; resolve_result: result スロット (offset 8, type at offset 23) を RESULT_VAL に
; 4B tagged 値として展開する。op1/op2 と同じ tag 形式。4 引数 intrinsic で
; 「3 番目の引数を runtime int として読みたい」用途のため (例: nes_sprite_at の
; $y)。result_type が IS_UNUSED の場合は 0 で埋める。
; =============================================================================
resolve_result:
    LDY #23                ; result_type
    LDA (VM_PC), Y
    CMP #IS_CONST
    BNE :+
    LDY #8
    JMP res_const_to_result
:
    CMP #IS_CV
    BNE :+
    LDY #8
    JMP res_cv_to_result
:
    CMP #IS_TMP_VAR
    BNE :+
    LDY #8
    JMP res_tmp_to_result
:
    CMP #IS_VAR
    BNE :+
    LDY #8
    JMP res_tmp_to_result
:
    LDA #0
    STA RESULT_VAL
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    RTS

res_const_to_result:
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
    STA RESULT_VAL
    LDY #0
    LDA (TMP0), Y
    STA RESULT_VAL+1
    LDY #1
    LDA (TMP0), Y
    STA RESULT_VAL+2
    LDY #2
    LDA (TMP0), Y
    STA RESULT_VAL+3
    RTS

res_cv_to_result:
    JSR cv_addr_y
    LDY #0
    LDA (TMP0), Y
    STA RESULT_VAL
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+1
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+2
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+3
    RTS

res_tmp_to_result:
    JSR tmp_addr_y
    LDY #0
    LDA (TMP0), Y
    STA RESULT_VAL
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+1
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+2
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+3
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
    LDY #8
    JSR tmp_addr_y
    JMP wr_store

wr_cv:
    LDY #8
    JSR cv_addr_y
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
    ; 新方式: OP1_VAL+1/+2 = val[] 先頭の OPS_BASE 相対 offset、OP1_VAL+3 = length
    CLC
    LDA OP1_VAL+1
    ADC #<OPS_BASE
    STA TMP1                ; val[] の絶対 CPU アドレス
    LDA OP1_VAL+2
    ADC #>OPS_BASE
    STA TMP1+1
    LDA OP1_VAL+3
    STA TMP2                ; len
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
    JSR cv_addr_y
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
; ZEND_MUL: result = op1 * op2 (16bit signed × signed → 16bit truncated)
;
; 16-bit unsigned shift-and-add で実装。signed の結果は下位 16 bit を取る形で
; 自然に正しくなる (signed × signed の low 16 bit は unsigned × unsigned の
; low 16 bit と一致する)。
; -----------------------------------------------------------------------------
handle_zend_mul:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE mul_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE mul_type_err
    ; TMP0 = result accumulator (= 0)
    LDA #0
    STA TMP0
    STA TMP0+1
    ; TMP1 = a (multiplicand、シフトされて消費)
    LDA OP1_VAL+1
    STA TMP1
    LDA OP1_VAL+2
    STA TMP1+1
    ; TMP2 = b (multiplier、左シフトしながら累加)
    LDA OP2_VAL+1
    STA TMP2
    LDA OP2_VAL+2
    STA TMP2+1
    LDX #16
mul_bit_loop:
    ; a の最下位 bit を C に出してテスト
    LSR TMP1+1
    ROR TMP1
    BCC mul_skip_add
    ; result += b
    CLC
    LDA TMP0
    ADC TMP2
    STA TMP0
    LDA TMP0+1
    ADC TMP2+1
    STA TMP0+1
mul_skip_add:
    ; b <<= 1
    ASL TMP2
    ROL TMP2+1
    DEX
    BNE mul_bit_loop
    ; result を RESULT_VAL に
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA TMP0
    STA RESULT_VAL+1
    LDA TMP0+1
    STA RESULT_VAL+2
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
mul_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_DIV: result = op1 / op2 (16bit signed integer divide、truncate-toward-zero)
;
; PHP/C 流の signed div: 商の符号 = sign(a) XOR sign(b)、|q| = |a| / |b|。
; b == 0 は silent fallback で 0 を返す (PHP は例外、NES では halt 大袈裟)。
; -----------------------------------------------------------------------------
handle_zend_div:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE div_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE div_type_err
    ; quotient sign を 6502 stack に push (bit 7 が立っていれば負)
    LDA OP1_VAL+2
    EOR OP2_VAL+2
    PHA
    ; |a| → TMP0
    JSR div_abs_a_to_tmp0
    ; |b| → TMP2
    JSR div_abs_b_to_tmp2
    ; b == 0 チェック
    LDA TMP2
    ORA TMP2+1
    BEQ div_by_zero
    JSR udiv16              ; TMP0 = |q|, TMP1 = |r| (使わない)
    ; quotient sign を見て必要なら negate
    PLA
    AND #$80
    BEQ div_pos
    JSR neg16_tmp0
div_pos:
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA TMP0
    STA RESULT_VAL+1
    LDA TMP0+1
    STA RESULT_VAL+2
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
div_by_zero:
    PLA                     ; discard saved sign
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
div_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_MOD: result = op1 % op2 (16bit signed modulo)
;
; PHP/C 流: 剰余の符号 = sign(a) (= 被除数の符号)。b == 0 は 0 fallback。
; -----------------------------------------------------------------------------
handle_zend_mod:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE mod_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE mod_type_err
    ; remainder sign = sign(a)、stack に push
    LDA OP1_VAL+2
    PHA
    ; |a| → TMP0、|b| → TMP2
    JSR div_abs_a_to_tmp0
    JSR div_abs_b_to_tmp2
    LDA TMP2
    ORA TMP2+1
    BEQ mod_by_zero
    JSR udiv16              ; TMP1 = |r|
    ; remainder を TMP0 に移して符号調整 (write_result 系 helper を流用しやすくする)
    LDA TMP1
    STA TMP0
    LDA TMP1+1
    STA TMP0+1
    PLA
    AND #$80
    BEQ mod_pos
    JSR neg16_tmp0
mod_pos:
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA TMP0
    STA RESULT_VAL+1
    LDA TMP0+1
    STA RESULT_VAL+2
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
mod_by_zero:
    PLA
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
mod_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; div_abs_a_to_tmp0: OP1_VAL の signed 16bit value を絶対値化して TMP0 に
; -----------------------------------------------------------------------------
div_abs_a_to_tmp0:
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1
    BPL :+              ; 正なら何もしない
    JSR neg16_tmp0
:
    RTS

; div_abs_b_to_tmp2: OP2_VAL を絶対値化して TMP2 に
div_abs_b_to_tmp2:
    LDA OP2_VAL+1
    STA TMP2
    LDA OP2_VAL+2
    STA TMP2+1
    LDA TMP2+1
    BPL :+
    ; negate TMP2
    SEC
    LDA #0
    SBC TMP2
    STA TMP2
    LDA #0
    SBC TMP2+1
    STA TMP2+1
:
    RTS

; neg16_tmp0: TMP0 を 2's complement で negate
neg16_tmp0:
    SEC
    LDA #0
    SBC TMP0
    STA TMP0
    LDA #0
    SBC TMP0+1
    STA TMP0+1
    RTS

; -----------------------------------------------------------------------------
; udiv16: unsigned 16-bit divide、TMP0 / TMP2 → TMP0 = quotient, TMP1 = remainder
;
; 16-bit shift-and-subtract。X register を 16 step counter に使う。
; 呼び出し側は TMP0 (dividend), TMP2 (divisor) をセットしてから JSR。
; 結果: TMP0 = quotient, TMP1 = remainder。TMP2 は保持 (divisor)。
; -----------------------------------------------------------------------------
udiv16:
    LDA #0
    STA TMP1
    STA TMP1+1
    LDX #16
udiv16_loop:
    ASL TMP0                ; dividend << 1, MSB → C
    ROL TMP0+1
    ROL TMP1                ; remainder << 1 (with new bit from dividend MSB)
    ROL TMP1+1
    ; remainder >= divisor かテスト (= remainder - divisor が non-negative)
    SEC
    LDA TMP1
    SBC TMP2
    TAY                     ; tentative new remainder lo
    LDA TMP1+1
    SBC TMP2+1
    BCC udiv16_no_sub        ; remainder < divisor
    ; remainder >= divisor: subtract で確定、商の bit を立てる
    STY TMP1
    STA TMP1+1
    INC TMP0                 ; quotient |= 1 (LSB)
udiv16_no_sub:
    DEX
    BNE udiv16_loop
    RTS

; -----------------------------------------------------------------------------
; ZEND_BW_AND: result = op1 & op2 (16bit bitwise AND)
; ZEND_BW_OR:  result = op1 | op2 (16bit bitwise OR)
;   両 operand とも IS_LONG 前提 (mask 演算の実用上の想定)
; -----------------------------------------------------------------------------
handle_zend_bw_and:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE bw_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE bw_type_err
    LDA OP1_VAL+1
    AND OP2_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    AND OP2_VAL+2
    STA RESULT_VAL+2
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

handle_zend_bw_or:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE bw_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE bw_type_err
    LDA OP1_VAL+1
    ORA OP2_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    ORA OP2_VAL+2
    STA RESULT_VAL+2
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

bw_type_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_SL: result = op1 << op2 (16bit logical shift left)
; ZEND_SR: result = op1 >> op2 (16bit arithmetic shift right、符号保持)
;   op2 は下位 1B をシフト量として使う (0..15 を想定、大きいと全 0 / -1 にしかならない)
; -----------------------------------------------------------------------------
handle_zend_sl:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE sh_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE sh_type_err
    LDA OP1_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    STA RESULT_VAL+2
    LDX OP2_VAL+1
sl_loop:
    CPX #0
    BEQ sh_done
    ASL RESULT_VAL+1
    ROL RESULT_VAL+2
    DEX
    JMP sl_loop

handle_zend_sr:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE sh_type_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE sh_type_err
    LDA OP1_VAL+1
    STA RESULT_VAL+1
    LDA OP1_VAL+2
    STA RESULT_VAL+2
    LDX OP2_VAL+1
sr_loop:
    CPX #0
    BEQ sh_done
    ; arithmetic shift right: high byte bit 0 → C、bit 7 は符号保持 (C=sign 前処理で)
    LDA RESULT_VAL+2
    CMP #$80             ; C = sign bit (1 なら負)
    ROR RESULT_VAL+2     ; new bit 7 = 旧 C (sign 保持)
    ROR RESULT_VAL+1     ; new bit 7 = 上位 bit 0
    DEX
    JMP sr_loop

sh_done:
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

sh_type_err:
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
; inc/dec ヘルパ: op1 の CV スロット絶対アドレスを TMP0 にセット
; (op1_type != IS_CV なら handle_unimpl)
; -----------------------------------------------------------------------------
incdec_cv_addr:
    LDY #21
    LDA (VM_PC), Y         ; op1_type
    CMP #IS_CV
    BNE incdec_err
    LDY #0
    JMP cv_addr_y          ; tail call (RTS は cv_addr_y が行う)
incdec_err:
    JMP handle_unimpl

; -----------------------------------------------------------------------------
; ZEND_PRE_INC: ++CV[op1]。result があれば更新後の値を書く
; -----------------------------------------------------------------------------
handle_zend_pre_inc:
    JSR incdec_cv_addr
    LDY #0
    LDA (TMP0), Y          ; type
    CMP #TYPE_LONG
    BEQ :+
    JMP incdec_err
:
    LDY #1
    LDA (TMP0), Y          ; payload lo
    CLC
    ADC #1
    STA (TMP0), Y
    STA RESULT_VAL+1
    LDY #2
    LDA (TMP0), Y          ; payload hi
    ADC #0
    STA (TMP0), Y
    STA RESULT_VAL+2
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_PRE_DEC: --CV[op1]
; -----------------------------------------------------------------------------
handle_zend_pre_dec:
    JSR incdec_cv_addr
    LDY #0
    LDA (TMP0), Y
    CMP #TYPE_LONG
    BEQ :+
    JMP incdec_err
:
    LDY #1
    LDA (TMP0), Y
    SEC
    SBC #1
    STA (TMP0), Y
    STA RESULT_VAL+1
    LDY #2
    LDA (TMP0), Y
    SBC #0
    STA (TMP0), Y
    STA RESULT_VAL+2
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_POST_INC: CV[op1]++。result には「更新前の値」を書く
; -----------------------------------------------------------------------------
handle_zend_post_inc:
    JSR incdec_cv_addr
    LDY #0
    LDA (TMP0), Y
    CMP #TYPE_LONG
    BEQ :+
    JMP incdec_err
:
    ; 更新前の値を RESULT_VAL にコピー
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDY #1
    LDA (TMP0), Y
    STA RESULT_VAL+1
    LDY #2
    LDA (TMP0), Y
    STA RESULT_VAL+2
    LDA #0
    STA RESULT_VAL+3
    ; CV slot を +1
    LDY #1
    LDA (TMP0), Y
    CLC
    ADC #1
    STA (TMP0), Y
    LDY #2
    LDA (TMP0), Y
    ADC #0
    STA (TMP0), Y
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; ZEND_POST_DEC: CV[op1]--。result には更新前の値
; -----------------------------------------------------------------------------
handle_zend_post_dec:
    JSR incdec_cv_addr
    LDY #0
    LDA (TMP0), Y
    CMP #TYPE_LONG
    BEQ :+
    JMP incdec_err
:
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDY #1
    LDA (TMP0), Y
    STA RESULT_VAL+1
    LDY #2
    LDA (TMP0), Y
    STA RESULT_VAL+2
    LDA #0
    STA RESULT_VAL+3
    LDY #1
    LDA (TMP0), Y
    SEC
    SBC #1
    STA (TMP0), Y
    LDY #2
    LDA (TMP0), Y
    SBC #0
    STA (TMP0), Y
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
; ZEND_IS_SMALLER_OR_EQUAL: result = (op1 <= op2) ? TYPE_TRUE : TYPE_FALSE
;
; 実装手抜き: op1 <= op2 ⇔ !(op2 < op1) ⇔ op2 - op1 が non-negative。
; 既存の IS_SMALLER と同じ「16bit signed 減算 + N flag + V flag 補正」の
; ロジックを op2 - op1 で適用し、BMI/BPL の意味を反転させる。
; -----------------------------------------------------------------------------
handle_zend_is_smaller_or_equal:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE is_le_err
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE is_le_err
    ; 16bit signed: op2 - op1
    SEC
    LDA OP2_VAL+1
    SBC OP1_VAL+1
    LDA OP2_VAL+2
    SBC OP1_VAL+2
    BVC is_le_no_ov
    EOR #$80
is_le_no_ov:
    BMI is_le_false           ; op2 < op1 → op1 > op2 → false
    LDA #TYPE_TRUE             ; op2 >= op1 → op1 <= op2 → true
    JMP is_le_store
is_le_false:
    LDA #TYPE_FALSE
is_le_store:
    STA RESULT_VAL
    LDA #0
    STA RESULT_VAL+1
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance
is_le_err:
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
    ; 新方式: OP1/OP2_VAL+1/+2 = val[] 先頭の OPS_BASE 相対 offset、+3 = length
    ; 長さ比較から (byte 3 同士)
    LDA OP1_VAL+3
    CMP OP2_VAL+3
    BNE vec_false
    TAX                    ; X = 残りバイト数
    BEQ vec_eq             ; 両方 len 0 → 等しい
    ; val[] 絶対アドレスを TMP0 / TMP1 に
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
    LDY #0
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
    ; X (= 0 or 1、'-' を書いた直後の buffer 位置) を退避。div_tmp0_by_10 は
    ; X を内部 16 step counter に使うので JSR を跨ぐと壊れる。
    STX TMP1
    LDY #0                 ; 桁数カウンタ
pi_div_loop:
    JSR div_tmp0_by_10     ; A = 余り, TMP0 = 商, X clobber
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

    ; X を復元してから pop loop へ
    LDX TMP1
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
    LDA #1                   ; length = 1 (button char は 1 バイト固定)
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
    ; 新方式: value bytes 0-1 = val[] への OPS_BASE 相対 offset
    ; 1 文字目を直接読み INT_PRINT_BUFFER[0] に保存 (nes_put は 1 文字固定)
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
    LDY #0
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

    ; 新方式: value bytes 0-1 = val[] への OPS_BASE 相対 offset、byte 2 = length
    LDY #0
    LDA (TMP0), Y
    STA TMP1
    INY
    LDA (TMP0), Y
    STA TMP1+1
    CLC
    LDA TMP1
    ADC #<OPS_BASE
    STA TMP1                ; val[] 絶対 CPU アドレス
    LDA TMP1+1
    ADC #>OPS_BASE
    STA TMP1+1
    LDY #2
    LDA (TMP0), Y
    STA TMP2                ; len

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
; NESPHP_NES_CHR_SPR (0xF5): sprite 用 4KB CHR セットを差し替える
;
; 引数: op1 = CHR セット番号 (int literal 0-3、IS_CONST)
;
; CHR-RAM 化に伴い、bank 切替ではなく PRG_BANK1 から PPU $1000-$1FFF への
; 4KB バルク転送として実装。chr_bulk_transfer サブルーチン共有。
; =============================================================================
handle_nesphp_nes_chr_spr:
    JSR resolve_op1
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE chr_spr_err
    LDA OP1_VAL+1
    AND #$03               ; 0-3 にクランプ (PRG_BANK1 16KB / 4KB = 4 セット)
    LDX #$10               ; PPU dest hi = $10 (sprite pattern table)
    JSR chr_bulk_transfer
    JMP advance

chr_spr_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_CHR_BG (0xF6): BG 用 4KB CHR セットを差し替える
;
; 引数: op1 = CHR セット番号 (int literal 0-3、IS_CONST)
;
; CHR-RAM 化に伴い、bank 切替ではなく PRG_BANK1 から PPU $0000-$0FFF への
; 4KB バルク転送として実装。chr_bulk_transfer サブルーチン共有。
; =============================================================================
handle_nesphp_nes_chr_bg:
    JSR resolve_op1
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE chr_bg_err
    LDA OP1_VAL+1
    AND #$03               ; 0-3 にクランプ
    LDX #$00               ; PPU dest hi = $00 (BG pattern table)
    JSR chr_bulk_transfer
    JMP advance

chr_bg_err:
    JMP handle_unimpl

; =============================================================================
; chr_bulk_transfer サブルーチン
;
; 入力:
;   A = CHR セット番号 (0-3)
;   X = PPU 転送先 hi byte ($00 = BG pattern table、$10 = sprite pattern table)
;
; 動作:
;   PRG bank 1 ($8000-$BFFF に CHRDATA) に切替 → PPU $0000 or $1000 に 4KB
;   バルク転送 → PRG bank 0 (PHPSRC) 復帰。
;
;   sprite_mode_on のときは NMI 無効化 + rendering OFF + 転送 + VBlank 待ち +
;   OAM DMA 補完 + rendering ON の流れ (cls_sprite_mode と同じ brief
;   force-blanking パターン)。約 25 ms の黒フラッシュ (1.5 frame)。
;
;   forced_blanking モード (PPUMASK=0、NMI off の起動直後など) では
;   PPUMASK 操作は不要なので転送だけして RTS。
;
; clobber: A, X, Y, TMP0, TMP1
; =============================================================================
chr_bulk_transfer:
    STA TMP0               ; CHR セット番号を保存
    STX TMP1               ; PPU dest hi byte を保存 (TMP1 は src 計算でも使う)

    ; sprite_mode_on で分岐: rendering 切替が必要か判定
    LDA sprite_mode_on
    BEQ chr_xfer_no_blank

    ; --- sprite_mode: NMI 無効化 + rendering OFF ---
    LDA ppu_ctrl_shadow
    PHA                    ; 古い shadow を退避
    AND #$7F
    STA ppu_ctrl_shadow
    STA PPUCTRL            ; bit 7 = 0 で NMI off
    LDA #0
    STA PPUMASK            ; 強制 blanking

chr_xfer_no_blank:
    ; PRG bank を 1 に切替 (CHRDATA を $8000-$BFFF にマップ)
    LDA #1
    MMC1_WRITE $E000

    ; PPU アドレス = (TMP1 << 8) — i.e. $0000 or $1000
    BIT PPUSTATUS
    LDA TMP1               ; X 入力 = PPU dest hi byte
    STA PPUADDR
    LDA #$00
    STA PPUADDR

    ; src ptr = $8000 + (set_index * $1000)
    STA TMP1               ; src lo = 0
    LDA TMP0               ; A = set index
    ASL                    ; × 16 で bit 0-1 を bit 4-5 にシフト
    ASL
    ASL
    ASL
    CLC
    ADC #$80               ; src hi = $80 + (set_index << 4)
    STA TMP1+1

    ; 4KB 転送 (16 ページ × 256 byte)
    LDX #$10
    LDY #0
chr_xfer_outer:
chr_xfer_inner:
    LDA (TMP1), Y
    STA PPUDATA
    INY
    BNE chr_xfer_inner
    INC TMP1+1
    DEX
    BNE chr_xfer_outer

    ; PRG bank 0 (PHPSRC) に戻す
    LDA #0
    MMC1_WRITE $E000

    ; sprite_mode のときだけ rendering 復帰処理
    LDA sprite_mode_on
    BEQ chr_xfer_done

    ; VBlank を待ってから rendering 再開 (画面途中で復帰すると glitch)
    BIT PPUSTATUS
chr_xfer_wait_vb:
    BIT PPUSTATUS
    BPL chr_xfer_wait_vb

    ; OAM DMA を手動補完 (NMI 無効化中の OAM 更新を埋める)
    LDA #>OAM_SHADOW
    STA OAM_DMA

    ; scroll リセット (PPUADDR 連続書込で内部 scroll latch がズレている)
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL

    ; rendering 復帰 (BG + sprite enable)
    LDA #%00011110
    STA PPUMASK

    ; ppu_ctrl_shadow 復帰 (bit 7 復活で NMI 再有効)
    PLA
    STA ppu_ctrl_shadow
    STA PPUCTRL

chr_xfer_done:
    RTS

; =============================================================================
; NESPHP_NES_BG_COLOR (0xF7): 背景色 ($3F00) を設定する
;
; 引数: op1 = NES カラーコード (int literal 0x00-0x3F, IS_CONST)
;
; PPU $3F00 は全パレット共通の背景色。forced_blanking なら直接書き、
; sprite_mode なら NMI キュー経由。1 バイトだけなので ppu_write_bytes を
; 使い、INT_PRINT_BUFFER[0] を一時バッファにする。
; =============================================================================
handle_nesphp_nes_bg_color:
    JSR resolve_op1
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE bg_color_err
    LDA OP1_VAL+1
    AND #$3F               ; NES カラーは 6 bit
    STA INT_PRINT_BUFFER
    ; TMP0 = PPU $3F00
    LDA #$00
    STA TMP0
    LDA #$3F
    STA TMP0+1
    ; TMP1 = INT_PRINT_BUFFER, TMP2 = 1
    LDA #<INT_PRINT_BUFFER
    STA TMP1
    LDA #>INT_PRINT_BUFFER
    STA TMP1+1
    LDA #1
    STA TMP2
    JSR ppu_write_bytes
    JMP advance

bg_color_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_PALETTE (0xF8): パレットエントリの 3 色を設定する
;
; 引数 (4 つ):
;   op1            = パレット ID (0-3 = BG, 4-7 = sprite)
;   op2            = 色 1 (NES カラーコード)
;   result         = 色 2 (IS_CONST、result フィールドを入力引数として流用)
;   extended_value = 色 3
;
; PPU アドレス = $3F01 + id * 4。3 バイトを連続書き込み。
; forced_blanking = 直書き、sprite_mode = NMI キュー経由。
; =============================================================================
handle_nesphp_nes_palette:
    JSR resolve_op1        ; OP1_VAL = id
    JSR resolve_op2        ; OP2_VAL = c1

    ; result (offset 8) を手動 resolve → c2
    LDY #8
    LDA (VM_PC), Y
    STA TMP0
    INY
    LDA (VM_PC), Y
    STA TMP0+1
    ; result_type チェック
    LDY #23                ; result_type
    LDA (VM_PC), Y
    CMP #IS_CONST
    BNE palette_err
    ; TMP0 = literal offset → 実アドレスに解決
    CLC
    LDA VM_LITBASE
    ADC TMP0
    STA TMP0
    LDA VM_LITBASE+1
    ADC TMP0+1
    STA TMP0+1
    ; zval type check
    LDY #8
    LDA (TMP0), Y
    CMP #TYPE_LONG
    BNE palette_err
    ; value.lval 下位 1B = c2
    LDY #0
    LDA (TMP0), Y
    AND #$3F
    STA INT_PRINT_BUFFER+1 ; c2 を buffer[1] に

    ; extended_value (offset 12) → c3
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
    LDY #8
    LDA (TMP0), Y
    CMP #TYPE_LONG
    BNE palette_err
    LDY #0
    LDA (TMP0), Y
    AND #$3F
    STA INT_PRINT_BUFFER+2 ; c3 を buffer[2] に

    ; c1 (OP2_VAL) を buffer[0] に
    LDA OP2_VAL
    CMP #TYPE_LONG
    BNE palette_err
    LDA OP2_VAL+1
    AND #$3F
    STA INT_PRINT_BUFFER   ; c1 を buffer[0] に

    ; id (OP1_VAL) からPPU アドレスを計算: $3F01 + id * 4
    LDA OP1_VAL
    CMP #TYPE_LONG
    BNE palette_err
    LDA OP1_VAL+1
    AND #$07               ; 0-7 にクランプ
    ASL A
    ASL A                  ; id * 4
    CLC
    ADC #$01               ; + $01 (色 0 をスキップ)
    STA TMP0               ; PPU addr lo
    LDA #$3F
    STA TMP0+1             ; PPU addr hi = $3F

    ; TMP1 = INT_PRINT_BUFFER, TMP2 = 3
    LDA #<INT_PRINT_BUFFER
    STA TMP1
    LDA #>INT_PRINT_BUFFER
    STA TMP1+1
    LDA #3
    STA TMP2
    JSR ppu_write_bytes
    JMP advance

palette_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_ATTR (0xF9): attribute table の 2×2 タイルブロックにパレットを設定
;
; 引数 (3 つ):
;   op1            = x (0-15, 2×2 タイルブロック座標)
;   op2            = y (0-14, 同)
;   extended_value = pal (0-3, BG パレット番号)
;
; attribute table は 64 バイト ($23C0-$23FF)。1 byte が 4×4 タイル (32×32 px)
; 領域の 4 つの 2×2 タイル quadrant のパレット情報を持つ:
;   bit 1-0 = 左上 quadrant
;   bit 3-2 = 右上 quadrant
;   bit 5-4 = 左下 quadrant
;   bit 7-6 = 右下 quadrant
;
; attr byte index = (y / 2) * 8 + (x / 2)
; bit position    = ((y % 2) * 2 + (x % 2)) * 2
;
; ATTR_SHADOW (RAM 64B) を read-modify-write して、対象 quadrant だけ変更。
; 変更後の byte を PPU に書く (forced_blanking = 直書き / sprite_mode = queue)。
; =============================================================================
handle_nesphp_nes_attr:
    JSR resolve_op1        ; OP1_VAL = x
    JSR resolve_op2        ; OP2_VAL = y
    JSR resolve_result     ; RESULT_VAL = pal (3 引数枠を再利用、runtime int 可)

    LDA RESULT_VAL
    CMP #TYPE_LONG
    BNE attr_err
    LDA RESULT_VAL+1
    AND #$03               ; pal を 0-3 にクランプ
    STA TMP2               ; TMP2 = pal (2 bit)

    ; attr byte index = (y / 2) * 8 + (x / 2)
    LDA OP2_VAL+1          ; y
    LSR A                  ; y / 2
    ASL A
    ASL A
    ASL A                  ; (y / 2) * 8
    STA TMP0               ; TMP0 = (y/2)*8
    LDA OP1_VAL+1          ; x
    LSR A                  ; x / 2
    CLC
    ADC TMP0
    TAX                    ; X = attr byte index (0-63)

    ; bit position = ((y % 2) * 2 + (x % 2)) * 2
    LDA OP2_VAL+1          ; y
    AND #$01               ; y % 2
    ASL A                  ; * 2
    STA TMP0
    LDA OP1_VAL+1          ; x
    AND #$01               ; x % 2
    ORA TMP0               ; (y%2)*2 + (x%2) = quadrant (0-3)
    ASL A                  ; * 2 = bit shift amount (0, 2, 4, 6)
    TAY                    ; Y = shift amount

    ; pal を shift 量だけ左にずらす
    LDA TMP2               ; pal (0-3)
attr_shift_pal:
    CPY #0
    BEQ attr_shift_done
    ASL A
    DEY
    JMP attr_shift_pal
attr_shift_done:
    STA TMP1               ; TMP1 = pal << shift

    ; mask を計算: ~(%11 << shift)
    ; 方法: $03 を shift 回左シフトして EOR #$FF
    LDA OP2_VAL+1
    AND #$01
    ASL A
    STA TMP0
    LDA OP1_VAL+1
    AND #$01
    ORA TMP0
    ASL A
    TAY                    ; Y = shift amount (再計算)
    LDA #$03
attr_shift_mask:
    CPY #0
    BEQ attr_mask_done
    ASL A
    DEY
    JMP attr_shift_mask
attr_mask_done:
    EOR #$FF               ; A = ~(0x03 << shift) = mask
    AND ATTR_SHADOW, X     ; 既存の byte から対象 quadrant だけクリア
    ORA TMP1               ; pal を OR で合成
    STA ATTR_SHADOW, X     ; shadow に書き戻す

    ; PPU に 1 バイト書き込む: $23C0 + X
    STA INT_PRINT_BUFFER
    TXA
    CLC
    ADC #$C0
    STA TMP0               ; PPU addr lo = $C0 + byte_index
    LDA #$23
    ADC #0                 ; carry (index >= 64 なら $24xx だが通常ありえない)
    STA TMP0+1             ; PPU addr hi = $23
    LDA #<INT_PRINT_BUFFER
    STA TMP1
    LDA #>INT_PRINT_BUFFER
    STA TMP1+1
    LDA #1
    STA TMP2
    JSR ppu_write_bytes
    JMP advance

attr_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_VSYNC (0xFA): 次 VBlank まで spin
;
; sprite_mode が off (NMI 未有効) なら enable_sprite_mode を自動で呼ぶ。
; OAM shadow は reset で $FF (= y 座標 offscreen) に初期化済みなので、
; nes_sprite_at を呼ばずに rendering を有効化してもスプライトは見えない。
; =============================================================================
handle_nesphp_nes_vsync:
    LDA sprite_mode_on
    BNE vsync_nmi_ok
    JSR enable_sprite_mode
vsync_nmi_ok:
    LDA vblank_frame
    STA TMP0
vsync_spin:
    LDA vblank_frame
    CMP TMP0
    BEQ vsync_spin
    JMP advance

; =============================================================================
; NESPHP_NES_BTN (0xFB): コントローラ状態を読み、buttons bitmask を IS_LONG 返却
;
; 0 引数 (op1/op2 未使用)。result = IS_LONG(buttons) where
;   bit 7=A, 6=B, 5=Select, 4=Start, 3=U, 2=D, 1=L, 0=R
; 呼び出し側 (PHP) が `$b & 0x80` などで bitmask 判定を行う。
; =============================================================================
handle_nesphp_nes_btn:
    JSR read_controller          ; buttons ZP に現状態を更新
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA buttons
    STA RESULT_VAL+1             ; 下位 1B = ボタン状態
    LDA #0
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; =============================================================================
; Pre-baked 1 文字 zend_string (ボタン対応)
;
; 各ブロックは spec/01-rom-format.md の zend_string 24B ヘッダ + content + null
; のレイアウトに準拠 (fgets が返す IS_STRING の参照先として)。
; =============================================================================
; 新方式: zend_string ヘッダは持たず、1 バイトの val[] だけを ROM に置く。
; fgets_got_str は RESULT_VAL+1/+2 に OPS_BASE 相対 offset、RESULT_VAL+3 に
; length=1 を書き込む。
button_str_a:     .byte 'A'
button_str_b:     .byte 'B'
button_str_sel:   .byte 'S'
button_str_start: .byte 'T'
button_str_u:     .byte 'U'
button_str_d:     .byte 'D'
button_str_l:     .byte 'L'
button_str_r:     .byte 'R'

; =============================================================================
; NESPHP_NES_SPRITE (0xF2): nes_sprite_at($idx, $x, $y, $tile)
;
; OAM[$idx] (0..63) の shadow を更新する。$idx, $x, $y は runtime int 可
; (CV/TMP/CONST いずれも)、$tile はリテラル必須 (IS_CONST IS_LONG)。
;
; op1            = $idx (any operand type、IS_LONG)
; op2            = $x   (any operand type、IS_LONG)
; result slot    = $y   (any operand type、IS_LONG) — result の field を入力
;                       3 番目の runtime 値の格納場所として再利用
; extended_value = $tile literal pointer (IS_CONST IS_LONG)
;
; OAM offset = ($idx & 0x3F) * 4
;   +0 = y, +1 = tile, +2 = attr (touch しない), +3 = x
;
; attr バイトは触らない (= 既存値を保持)。属性変更は nes_sprite_attr で別途。
;
; 初回呼び出しで rendering + NMI を有効化し、以降は OAM shadow 書き込みだけ。
; NMI ハンドラが毎 VBlank で OAM DMA を実行するので、書き換えは即座に反映。
; =============================================================================
handle_nesphp_nes_sprite:
    LDA sprite_mode_on
    BNE nss_mode_ready
    JSR enable_sprite_mode
nss_mode_ready:
    JSR resolve_op1        ; OP1_VAL = $idx
    JSR resolve_op2        ; OP2_VAL = $x
    JSR resolve_result     ; RESULT_VAL = $y

    ; extended_value から $tile を decode (literal 必須)
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
    STA TMP2               ; TMP2 = tile (lo byte)

    ; OAM offset = ($idx & 0x3F) * 4 (= idx を 0-63 にクランプして << 2)
    LDA OP1_VAL+1          ; idx lo byte
    AND #$3F
    ASL A
    ASL A
    TAX                    ; X = OAM offset (0, 4, 8, ..., 252)

    ; OAM_SHADOW[X..X+3] を更新 (attr は触らない)
    LDA RESULT_VAL+1
    STA OAM_SHADOW + 0, X  ; y
    LDA TMP2
    STA OAM_SHADOW + 1, X  ; tile
    LDA OP2_VAL+1
    STA OAM_SHADOW + 3, X  ; x

    JMP advance

nss_type_err:
    JMP handle_unimpl

; =============================================================================
; NESPHP_NES_SPRITE_ATTR (0xFC): nes_sprite_attr($idx, $attr)
;
; OAM[$idx*4+2] = $attr。attr バイトのビット構成:
;   bit 0-1 : palette (0-3、sprite palette 0/1/2/3 = $3F11/15/19/1D 系)
;   bit 5   : 優先度 (0 = BG の前 / 1 = BG の後ろ)
;   bit 6   : 水平反転 (1 で左右反転)
;   bit 7   : 垂直反転 (1 で上下反転)
;
; 両引数とも runtime int 可。$idx は 0-63 にクランプ。
; sprite_mode は本 intrinsic 単独では起動しない (位置を設定する nes_sprite_at と
; 組み合わせる前提、属性だけ書き換えても sprite y=$FF のままだと見えない)。
; =============================================================================
handle_nesphp_nes_sprite_attr:
    JSR resolve_op1        ; OP1_VAL = $idx
    JSR resolve_op2        ; OP2_VAL = $attr

    LDA OP1_VAL+1
    AND #$3F
    ASL A
    ASL A
    TAX                    ; X = OAM offset

    LDA OP2_VAL+1
    STA OAM_SHADOW + 2, X  ; attr

    JMP advance

; =============================================================================
; NESPHP_NES_RAND (0xFD): nes_rand() — 0 引数、戻り値 IS_LONG
;
; 16-bit Galois LFSR (tap = $B400、polynomial x^16 + x^14 + x^13 + x^11 + 1、
; 周期 65535) を 1 step 進めて結果を IS_LONG として result スロットに書く。
;
;   if (state & 1) { state = (state >> 1) ^ $B400 }
;   else           { state = (state >> 1)          }
;
; 6502 では LSR/ROR で 16-bit 右シフトしつつ「シフト前の bit 0」を C に拾い、
; BCC で XOR 分岐させると 8 byte で書ける。
; rand_state = 0 だと永遠に 0 を返すので reset で 1 に初期化済み。
; =============================================================================
handle_nesphp_nes_rand:
    LSR rand_state+1       ; hi >>= 1, C = old hi bit 0
    ROR rand_state         ; lo = (lo>>1) | (C<<7), C = old lo bit 0
    BCC :+
    LDA rand_state+1
    EOR #$B4
    STA rand_state+1
:
    LDA #TYPE_LONG
    STA RESULT_VAL
    LDA rand_state
    STA RESULT_VAL+1       ; lo
    LDA rand_state+1
    STA RESULT_VAL+2       ; hi
    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; =============================================================================
; NESPHP_NES_SRAND (0xFE): nes_srand($seed) — 1 引数、戻り値なし
;
; LFSR 状態を $seed で上書きする。$seed = 0 は LFSR の退化点なので内部で 1 に
; 置換 (ユーザが事故で 0 を渡しても破綻しない)。
;
; シード源パターン (典型):
;   nes_srand(1);                // 初期化 (適当な非 0)
;   while (true) {
;       nes_vsync();
;       nes_rand();              // 毎フレーム空回し
;       $b = nes_btn();
;       if ($b & 0x10) { ... }   // Start で抜ける
;   }
;   // 抜けた時点で rand_state は「待機フレーム数」依存の値
; =============================================================================
handle_nesphp_nes_srand:
    JSR resolve_op1        ; OP1_VAL = $seed
    LDA OP1_VAL+1
    STA rand_state         ; lo
    LDA OP1_VAL+2
    STA rand_state+1       ; hi
    ; if (state == 0) state = 1
    LDA rand_state
    ORA rand_state+1
    BNE :+
    LDA #1
    STA rand_state
:
    JMP advance

; =============================================================================
; NESPHP_NES_PUTINT (0xFF): nes_putint($x, $y, $value)
;
; nametable (x, y) に **5-char 右詰め unsigned 16-bit int** を ASCII で書く。
;
; op1         = $x (any operand type、IS_LONG)
; op2         = $y (any operand type、IS_LONG)
; result slot = $value (any operand type、IS_LONG; 3 番目の runtime int)
;
; $value は unsigned 16-bit として解釈し、0..65535 範囲。出力例:
;   0     → "    0"
;   99    → "   99"
;   1234  → " 1234"
;   65535 → "65535"
;
; 負数 (signed として解釈すると負) を渡すと unsigned 値として表示される
; (例: -1 → "65535")。スコア HUD など正値前提の用途を想定。
;
; sprite_mode 中なら NMI 同期書き込みキュー (ppu_write_bytes 経由) で次 VBlank
; に反映、forced_blanking 中なら直書き。
; =============================================================================
handle_nesphp_nes_putint:
    JSR resolve_op1        ; OP1_VAL = $x
    JSR resolve_op2        ; OP2_VAL = $y
    JSR resolve_result     ; RESULT_VAL = $value

    ; TMP0 = $value (unsigned 16-bit)
    LDA RESULT_VAL+1
    STA TMP0
    LDA RESULT_VAL+2
    STA TMP0+1

    ; Step 1: 位置 4..0 に 5 桁全部 ('0' を含む leading zeros) を書く
    ; 注意: div_tmp0_by_10 は X register を clobber する (内部で 16 step counter
    ; に使用)。Y は touch しないので Y を loop counter にする。
    LDY #4
npti_div_loop:
    JSR div_tmp0_by_10     ; A = 余り 0-9, TMP0 = 商, X = clobber, Y は保持
    CLC
    ADC #'0'
    STA INT_PRINT_BUFFER, Y
    DEY
    BPL npti_div_loop

    ; Step 2: 先頭の '0' 連続を ' ' に置換 (位置 4 = 末尾は残すので 0..3 のみ)
    LDY #0
npti_pad_loop:
    LDA INT_PRINT_BUFFER, Y
    CMP #'0'
    BNE npti_addr          ; 非 '0' 出現 → 以降そのまま
    LDA #' '
    STA INT_PRINT_BUFFER, Y
    INY
    CPY #4
    BNE npti_pad_loop

npti_addr:
    ; nametable アドレス = $2000 + y*32 + x → TMP0 (nes_put と同じロジック)
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

    ; TMP1 = INT_PRINT_BUFFER, TMP2 = 5 (固定 5 byte)
    LDA #<INT_PRINT_BUFFER
    STA TMP1
    LDA #>INT_PRINT_BUFFER
    STA TMP1+1
    LDA #5
    STA TMP2
    JSR ppu_write_bytes
    JMP advance

; =============================================================================
; NESPHP_NES_PEEK (0xED): nes_peek($offset) → byte at USER_RAM[$offset]
;
; op1 = $offset (any operand type、IS_LONG)
; result = IS_LONG with byte value (上位バイトは 0)
;
; offset は & $FF で 0..255 にラップ。範囲外は wrap、エラーにはしない。
; =============================================================================
handle_nesphp_nes_peek:
    JSR resolve_op1
    LDA OP1_VAL+1                 ; offset lo
    TAX                           ; X = offset (8-bit、$FF を超えると wrap)
    LDA USER_RAM_BASE, X
    STA RESULT_VAL+1
    LDA #0
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    LDA #TYPE_LONG
    STA RESULT_VAL
    JSR write_result
    JMP advance

; =============================================================================
; NESPHP_NES_PEEK16 (0xED): nes_peek16($offset) → 2 byte little-endian as IS_LONG
;
; op1 = $offset
; result = USER_RAM[$offset] | (USER_RAM[$offset+1] << 8)
;
; offset+1 が 256 を越えると 0 番地に wrap (8-bit X 演算)。
; =============================================================================
handle_nesphp_nes_peek16:
    JSR resolve_op1
    LDA OP1_VAL+1
    TAX
    LDA USER_RAM_BASE, X
    STA RESULT_VAL+1              ; lo byte
    INX
    LDA USER_RAM_BASE, X
    STA RESULT_VAL+2              ; hi byte
    LDA #0
    STA RESULT_VAL+3
    LDA #TYPE_LONG
    STA RESULT_VAL
    JSR write_result
    JMP advance

; =============================================================================
; NESPHP_NES_POKE (0xEE): nes_poke($offset, $byte)
;
; op1 = $offset (any、IS_LONG)
; op2 = $byte (any、IS_LONG; 下位 1 byte のみ書込)
; result = IS_UNUSED (戻り値なし)
;
; offset は & $FF で 0..255 にラップ。値は & $FF で 0..255 にトランケート。
; =============================================================================
handle_nesphp_nes_poke:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL+1                 ; offset lo
    TAX
    LDA OP2_VAL+1                 ; value lo (下位バイトのみ)
    STA USER_RAM_BASE, X
    JMP advance

; =============================================================================
; NESPHP_NES_POKESTR (0xEF): nes_pokestr($offset, $string)
;
; op1 = $offset (any、IS_LONG): USER_RAM 内の書込開始オフセット
; result slot (= 3 番目の引数の格納場所として再利用) = $string (any、IS_STRING)
;
; $string の生バイト (デコード済み)を USER_RAM_BASE + $offset から bulk copy。
; offset + len > 256 の場合は 256B 境界でクランプして停止。
; =============================================================================
handle_nesphp_nes_pokestr:
    JSR resolve_op1
    JSR resolve_result            ; RESULT_VAL = $string
    LDA RESULT_VAL
    CMP #TYPE_STRING
    BEQ :+
    JMP handle_unimpl
:
    ; 文字列の絶対 CPU アドレス = OPS_BASE + RESULT_VAL+1/+2 → TMP1
    CLC
    LDA RESULT_VAL+1
    ADC #<OPS_BASE
    STA TMP1
    LDA RESULT_VAL+2
    ADC #>OPS_BASE
    STA TMP1+1
    ; len = RESULT_VAL+3 (val[3] = length lo)
    LDA RESULT_VAL+3
    STA TMP2
    ; X = offset (USER_RAM 先頭からのインデックス)
    LDA OP1_VAL+1
    TAX
    LDY #0
nps_loop:
    CPY TMP2
    BEQ nps_done
    LDA (TMP1), Y
    STA USER_RAM_BASE, X
    INX
    BEQ nps_done                  ; X が wrap (256B 越え) したら停止
    INY
    BNE nps_loop
nps_done:
    JMP advance

; =============================================================================
; NESPHP_NES_PEEK_EXT (0xE8): nes_peek_ext($offset) → byte at USER_RAM_EXT[$offset]
;
; op1 = $offset (0..8191、IS_LONG)
; result = IS_LONG with byte value
;
; PRG-RAM bank 3 ($6000-$7FFF when bank 3 mapped) を 8KB の汎用領域として読出。
; offset は & $1FFF で 13-bit にラップ。bank 切替は intrinsic 内で完結。
; =============================================================================
handle_nesphp_nes_peek_ext:
    JSR resolve_op1
    ; ptr = $6000 + (offset & $1FFF)
    LDA OP1_VAL+1
    STA TMP0                      ; src lo = offset_lo
    LDA OP1_VAL+2
    AND #$1F                      ; clamp 13-bit
    CLC
    ADC #>USER_RAM_EXT_BASE       ; + $60
    STA TMP0+1                    ; src hi

    PRG_RAM_BANK3
    LDY #0
    LDA (TMP0), Y                 ; bank 3 読出
    STA RESULT_VAL+1              ; ★ 読み出した A を bank 0 復帰前に保存
    PRG_RAM_BANK0                 ; (BANK0 macro 内の LDA #0 で A clobber)

    LDA #0
    STA RESULT_VAL+2
    STA RESULT_VAL+3
    LDA #TYPE_LONG
    STA RESULT_VAL
    JSR write_result
    JMP advance

; =============================================================================
; NESPHP_NES_PEEK16_EXT (0xE9): nes_peek16_ext($offset) → 2 byte LE as IS_LONG
;
; op1 = $offset (0..8190)
; result = USER_RAM_EXT[$ofs] | (USER_RAM_EXT[$ofs+1] << 8)
; =============================================================================
handle_nesphp_nes_peek16_ext:
    JSR resolve_op1
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    AND #$1F
    CLC
    ADC #>USER_RAM_EXT_BASE
    STA TMP0+1

    PRG_RAM_BANK3
    LDY #0
    LDA (TMP0), Y
    STA RESULT_VAL+1              ; lo
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+2              ; hi
    PRG_RAM_BANK0

    LDA #0
    STA RESULT_VAL+3
    LDA #TYPE_LONG
    STA RESULT_VAL
    JSR write_result
    JMP advance

; =============================================================================
; NESPHP_NES_POKE_EXT (0xEA): nes_poke_ext($offset, $byte)
;
; op1 = $offset, op2 = $byte
; result = IS_UNUSED
; =============================================================================
handle_nesphp_nes_poke_ext:
    JSR resolve_op1
    JSR resolve_op2
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    AND #$1F
    CLC
    ADC #>USER_RAM_EXT_BASE
    STA TMP0+1

    PRG_RAM_BANK3
    LDY #0
    LDA OP2_VAL+1                 ; byte to write
    STA (TMP0), Y
    PRG_RAM_BANK0

    JMP advance

; =============================================================================
; NESPHP_NES_POKESTR_EXT (0xEB): nes_pokestr_ext($offset, $string)
;
; op1 = $offset、result slot = $string (= 3 引数 intrinsic 枠と同じ慣習)
;
; ソース ($string) は STR_POOL (PRG-RAM bank 0)、宛先は bank 3。両方を同時に
; マップできないので、内蔵 RAM の text buffer ($0600-$06FF, 256B) を中継
; バッファとして使う 2-stage コピー:
;   stage 1 (bank 0): STR_POOL → $0600 (string max 255 bytes、1 chunk で足りる)
;   stage 2 (bank 3): $0600 → USER_RAM_EXT[$offset]
; =============================================================================
handle_nesphp_nes_pokestr_ext:
    JSR resolve_op1
    JSR resolve_result            ; RESULT_VAL = $string
    LDA RESULT_VAL
    CMP #TYPE_STRING
    BEQ :+
    JMP handle_unimpl
:
    ; src = OPS_BASE + RESULT_VAL+1/+2 (bank 0 PRG-RAM、STR_POOL 内)
    CLC
    LDA RESULT_VAL+1
    ADC #<OPS_BASE
    STA TMP0
    LDA RESULT_VAL+2
    ADC #>OPS_BASE
    STA TMP0+1
    ; len = RESULT_VAL+3 (1 byte、max 255)
    LDA RESULT_VAL+3
    STA TMP2

    ; --- stage 1 (bank 0): STR_POOL → 内蔵 RAM 中継 ($0600+) ---
    LDY #0
nps_ext_to_ram:
    CPY TMP2
    BEQ nps_ext_to_ram_done
    LDA (TMP0), Y
    STA $0600, Y
    INY
    BNE nps_ext_to_ram
nps_ext_to_ram_done:

    ; dest = $6000 + (offset & $1FFF)
    LDA OP1_VAL+1
    STA TMP1                      ; dest lo
    LDA OP1_VAL+2
    AND #$1F
    CLC
    ADC #>USER_RAM_EXT_BASE
    STA TMP1+1                    ; dest hi

    ; --- stage 2 (bank 3): 中継 → USER_RAM_EXT ---
    PRG_RAM_BANK3
    LDY #0
nps_ext_to_bank3:
    CPY TMP2
    BEQ nps_ext_to_bank3_done
    LDA $0600, Y
    STA (TMP1), Y
    INY
    BNE nps_ext_to_bank3
nps_ext_to_bank3_done:
    PRG_RAM_BANK0

    JMP advance

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

    ; フレームカウンタを進める (nes_vsync が差分を spin wait する)
    INC vblank_frame

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

; =============================================================================
; ZEND_INIT_ARRAY / ZEND_ADD_ARRAY_ELEMENT / ZEND_FETCH_DIM_R / ZEND_COUNT
;
; 配列は ARR_POOL_BASE ($7000) から ARR_POOL_END ($7800) の 2KB pool に追記型で
; allocate。各配列の layout:
;   offset 0-1: count (u16、現在の要素数)
;   offset 2-3: capacity (u16、確保済みスロット数)
;   offset 4+:  capacity × 16 bytes (zval 配列)
; 配列 zval (4B tagged) は [TYPE_ARRAY, ptr_lo, ptr_hi, 0]。
; pool 枯渇で handle_unimpl へジャンプ。GC 無しで追記のみ。
; =============================================================================

; handle_zend_init_array: op1 = capacity (raw u16, IS_UNUSED type)。
; 新配列を alloc し、count=0/cap=capacity で初期化、RESULT に TYPE_ARRAY + pool
; 内 ptr を返す。MVP: cap < 16 を想定。
handle_zend_init_array:
    LDY #0
    LDA (VM_PC), Y             ; op1 lo = cap (bank 0、op_array 読出)
    STA TMP0
    ; needed = 4 + cap*16
    LDA TMP0
    ASL A
    ASL A
    ASL A
    ASL A                      ; A = (cap*16) & $FF
    CLC
    ADC #4
    STA TMP1                   ; needed lo
    LDA #0
    ADC #0                     ; carry from +4
    STA TMP1+1
    LDA TMP0
    LSR A
    LSR A
    LSR A
    LSR A                      ; A = cap >> 4 (cap*16 の上位 byte)
    CLC
    ADC TMP1+1
    STA TMP1+1
    ; 終端判定: new_head = head + needed (ZP 演算、bank 不問)
    CLC
    LDA ARR_POOL_HEAD
    ADC TMP1
    STA TMP2
    LDA ARR_POOL_HEAD+1
    ADC TMP1+1
    STA TMP2+1
    ; new_head >= ARR_POOL_END -> err
    LDA TMP2+1
    CMP #>ARR_POOL_END
    BCC ia_have_space
    BNE ia_overflow
    LDA TMP2
    CMP #<ARR_POOL_END
    BCC ia_have_space
ia_overflow:
    JMP handle_unimpl
ia_have_space:
    ; RESULT = [TYPE_ARRAY, head_lo, head_hi, 0]
    LDA #TYPE_ARRAY
    STA RESULT_VAL
    LDA ARR_POOL_HEAD
    STA RESULT_VAL+1
    LDA ARR_POOL_HEAD+1
    STA RESULT_VAL+2
    LDA #0
    STA RESULT_VAL+3

    ; --- bank 1 へ切替: header を ARR_POOL に書く ---
    PRG_RAM_BANK1
    LDY #0
    LDA #0
    STA (ARR_POOL_HEAD), Y
    INY
    STA (ARR_POOL_HEAD), Y
    INY
    LDA TMP0
    STA (ARR_POOL_HEAD), Y
    INY
    LDA #0
    STA (ARR_POOL_HEAD), Y
    PRG_RAM_BANK0
    ; --- bank 0 復帰 ---

    ; advance pool head (ZP 操作、bank 不問)
    LDA TMP2
    STA ARR_POOL_HEAD
    LDA TMP2+1
    STA ARR_POOL_HEAD+1
    JSR write_result
    JMP advance

; handle_zend_add_array_element: op1 = array、op2 = element。
; array->count 番目に element の 16B zval を書き込み、count++。
handle_zend_add_array_element:
    JSR resolve_op1            ; bank 0: array zval を OP1_VAL に展開
    JSR resolve_op2            ; bank 0: element zval を OP2_VAL に展開
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1                 ; TMP0 = array ptr (bank 1 view address)

    ; --- bank 1 へ切替: ARR_POOL の count 読み + 16B zval 書き + count++ ---
    PRG_RAM_BANK1

    ; count を 16-bit で読む (count_lo, count_hi)
    LDY #0
    LDA (TMP0), Y
    STA TMP1                   ; count_lo
    INY
    LDA (TMP0), Y
    STA TMP1+1                 ; count_hi
    ; (count * 16) を 16-bit で計算 (count_hi:count_lo を 4 回左シフト)
    LDA TMP1                   ; restore A = count_lo
    LDX #4
aae_mul16:
    ASL A
    ROL TMP1+1
    DEX
    BNE aae_mul16
    STA TMP1                   ; TMP1 = (count*16) & $FFFF
    ; dest = TMP0 + 4 + count*16
    CLC
    LDA TMP0
    ADC #4
    STA TMP2
    LDA TMP0+1
    ADC #0
    STA TMP2+1
    CLC
    LDA TMP2
    ADC TMP1
    STA TMP2                   ; dest lo
    LDA TMP2+1
    ADC TMP1+1
    STA TMP2+1                 ; dest hi
    ; 16B zval を書く (4B tagged -> 16B zval)
    LDY #0
    LDA OP2_VAL+1
    STA (TMP2), Y
    INY
    LDA OP2_VAL+2
    STA (TMP2), Y
    INY
    LDA OP2_VAL+3
    STA (TMP2), Y
    INY
    LDA #0
aae_zero1:
    STA (TMP2), Y
    INY
    CPY #8
    BNE aae_zero1
    LDA OP2_VAL                ; type
    STA (TMP2), Y
    INY
    LDA #0
aae_zero2:
    STA (TMP2), Y
    INY
    CPY #16
    BNE aae_zero2
    ; count++
    LDY #0
    LDA (TMP0), Y
    CLC
    ADC #1
    STA (TMP0), Y
    BCC aae_done
    INY
    LDA (TMP0), Y
    ADC #0
    STA (TMP0), Y
aae_done:
    PRG_RAM_BANK0
    ; --- bank 0 復帰 ---
    JSR write_result
    JMP advance

; handle_zend_fetch_dim_r: op1 = array、op2 = index (IS_LONG)。
; array[index] の 16B zval を RESULT (4B tagged) に展開。
handle_zend_fetch_dim_r:
    JSR resolve_op1            ; bank 0: array zval
    JSR resolve_op2            ; bank 0: index zval
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1
    ; index*16 を 16-bit で計算 (TMP2 = index*16、ZP のみ、bank 不問)
    LDA OP2_VAL+1
    STA TMP2                   ; index_lo
    LDA OP2_VAL+2
    STA TMP2+1                 ; index_hi
    LDA TMP2
    LDX #4
fdr_mul16:
    ASL A
    ROL TMP2+1
    DEX
    BNE fdr_mul16
    STA TMP2                   ; TMP2 = index*16
    ; src = base + 4 + index*16 → TMP1
    CLC
    LDA TMP0
    ADC #4
    STA TMP1
    LDA TMP0+1
    ADC #0
    STA TMP1+1
    CLC
    LDA TMP1
    ADC TMP2
    STA TMP1
    LDA TMP1+1
    ADC TMP2+1
    STA TMP1+1

    ; --- bank 1 へ切替: ARR_POOL から zval 読出 ---
    PRG_RAM_BANK1
    ; zval[0..2] → RESULT_VAL+1..+3
    LDY #0
    LDA (TMP1), Y
    STA RESULT_VAL+1
    INY
    LDA (TMP1), Y
    STA RESULT_VAL+2
    INY
    LDA (TMP1), Y
    STA RESULT_VAL+3
    LDY #8
    LDA (TMP1), Y
    STA RESULT_VAL
    PRG_RAM_BANK0
    ; --- bank 0 復帰 ---

    JSR write_result
    JMP advance

; handle_zend_count: op1 = array、RESULT = IS_LONG(count)。
handle_zend_count:
    JSR resolve_op1            ; bank 0: array zval
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1
    LDA #TYPE_LONG
    STA RESULT_VAL

    ; --- bank 1 へ切替: ARR_POOL から count を読出 ---
    PRG_RAM_BANK1
    LDY #0
    LDA (TMP0), Y
    STA RESULT_VAL+1
    INY
    LDA (TMP0), Y
    STA RESULT_VAL+2
    PRG_RAM_BANK0
    ; --- bank 0 復帰 ---

    LDA #0
    STA RESULT_VAL+3
    JSR write_result
    JMP advance

; -----------------------------------------------------------------------------
; handle_zend_assign_dim: $a[key] = value (または append $a[] = value)
;   op1 = array, op2 = key (IS_UNUSED なら append)
;   value は次の opcode (ZEND_OP_DATA) の op1 から取る
;   VM_PC を +48 進める (ASSIGN_DIM + OP_DATA の 2 op を消費)
;   count は max(count, slot+1) に更新 (任意 index への直接書換も count に反映)
; -----------------------------------------------------------------------------
handle_zend_assign_dim:
    JSR resolve_op1                ; OP1_VAL = array (ptr in +1/+2)
    ; array ptr を stack に退避 (push hi, lo の順。pop は lo, hi)
    LDA OP1_VAL+2
    PHA
    LDA OP1_VAL+1
    PHA
    ; slot 決定: op2_type が IS_UNUSED (= 0) なら append、それ以外は index
    LDY #22
    LDA (VM_PC), Y
    BNE asd_use_index
    ; append: slot = count (header[0..1] = 16-bit count)
    PLA
    STA TMP0
    PLA
    STA TMP0+1

    ; --- bank 1 へ切替: ARR_POOL から count 読出 ---
    PRG_RAM_BANK1
    LDY #0
    LDA (TMP0), Y
    STA TMP1                       ; TMP1 = count_lo
    INY
    LDA (TMP0), Y
    STA TMP1+1                     ; TMP1+1 = count_hi
    PRG_RAM_BANK0
    ; --- bank 0 復帰 ---

    LDA TMP0+1
    PHA
    LDA TMP0
    PHA
    JMP asd_slot_ready
asd_use_index:
    JSR resolve_op2                ; OP2_VAL = index (TMP0 は clobber される)
    ; 16-bit index を TMP1 に保存
    LDA OP2_VAL+1
    STA TMP1                       ; index_lo
    LDA OP2_VAL+2
    STA TMP1+1                     ; index_hi
asd_slot_ready:
    ; 現時点で stack 最上位 = [lo, hi] (array ptr)
    ; ptr を pop → TMP0 (+1)、ここで dest を計算。ptr は push し直す (count 更新用)
    PLA
    STA TMP0
    PLA
    STA TMP0+1
    LDA TMP0+1
    PHA
    LDA TMP0
    PHA
    ; dest = TMP0 + 4 + slot*16 (16-bit、N >= 16 でも正しく動く)
    LDA TMP1
    LDX #4
asd_mul16:
    ASL A
    ROL TMP1+1
    DEX
    BNE asd_mul16
    STA TMP1                       ; TMP1 = slot*16 (16-bit)
    CLC
    LDA TMP0
    ADC #4
    STA TMP2
    LDA TMP0+1
    ADC #0
    STA TMP2+1
    CLC
    LDA TMP2
    ADC TMP1
    STA TMP2                       ; dest lo
    LDA TMP2+1
    ADC TMP1+1
    STA TMP2+1                     ; dest hi
    ; VM_PC を +24 して OP_DATA を指す
    CLC
    LDA VM_PC
    ADC #24
    STA VM_PC
    BCC :+
    INC VM_PC+1
:
    JSR resolve_op1                ; bank 0: OP1_VAL = value (TMP0 clobber される)

    ; --- bank 1 へ切替: 16B zval 書込 + count 更新 (連続して bank 1 で実行) ---
    PRG_RAM_BANK1

    ; 16B zval を (TMP2) に書込
    LDY #0
    LDA OP1_VAL+1
    STA (TMP2), Y
    INY
    LDA OP1_VAL+2
    STA (TMP2), Y
    INY
    LDA OP1_VAL+3
    STA (TMP2), Y
    INY
    LDA #0
asd_zero1:
    STA (TMP2), Y
    INY
    CPY #8
    BNE asd_zero1
    LDA OP1_VAL                    ; type
    STA (TMP2), Y
    INY
    LDA #0
asd_zero2:
    STA (TMP2), Y
    INY
    CPY #16
    BNE asd_zero2
    ; array ptr を stack から復元して count 更新 (PLA/STA は bank 不問)
    PLA
    STA TMP0
    PLA
    STA TMP0+1
    LDA TMP1
    CLC
    ADC #1                         ; A = slot + 1
    LDY #0
    CMP (TMP0), Y                  ; bank 1: count_lo を読む
    BCC asd_no_update
    STA (TMP0), Y                  ; count_lo = slot+1 (bank 1 書込)
    LDA #0
    INY
    STA (TMP0), Y                  ; count_hi = 0 (bank 1 書込)
asd_no_update:
    PRG_RAM_BANK0
    ; --- bank 0 復帰 ---
    JMP advance

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

; -----------------------------------------------------------------------------
; On-NES コンパイラ本体 (compile_and_emit) は別ファイルに分離
; ca65 invocation は -I vm なので "compiler.s" で解決される
; -----------------------------------------------------------------------------
.include "compiler.s"

; =============================================================================
; VECTORS
; =============================================================================
.segment "VECTORS"
    .word nmi
    .word reset
    .word irq

; =============================================================================
; CHRDATA — CHR-RAM 化に伴い PRG_BANK1 経由で焼く CHR タイル data
;
; PRG_BANK1 16KB に 4 つの 4KB CHR セットを並べる:
;   offset 0      ($8000 when bank 1): set 0 = 通常 ASCII フォント
;   offset $1000  ($9000):              set 1 = インバースフォント
;   offset $2000  ($A000):              set 2 = (旧 CHR-ROM bank 2 相当)
;   offset $3000  ($B000):              set 3 = (旧 CHR-ROM bank 3 相当)
;
; 起動時の reset では set 0 + set 1 (先頭 8KB) を PPU $0000-$1FFF へ転送
; (= 従来の BG = bank 0、sprite = bank 1 と同じ初期見た目)。
;
; 実行時の nes_chr_bg($n) / nes_chr_spr($n) ($n=0..3) は chr_bulk_transfer で
; 該当セット 4KB を PPU $0000 (BG) or $1000 (sprite) へ書き直す。
; =============================================================================
.segment "CHRDATA"
    .incbin "chr/font.chr", 0, $4000  ; 16KB (4 セット分、PRG_BANK1 全域)
