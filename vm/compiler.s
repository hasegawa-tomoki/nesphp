; =============================================================================
; compiler.s — on-NES PHP コンパイラ (L3S, spec/13-compiler.md)
;
; Milestone: M-A' + P1 + P2 (CV + assign + 整数演算 + エラー表示)
;
; 対応構文:
;   program     ::= "<?php" stmt* EOF
;   stmt        ::= echo_stmt | call_stmt | assign_stmt
;   echo_stmt   ::= "echo" expr ";"
;   call_stmt   ::= IDENT "(" args? ")" ";"
;   assign_stmt ::= CV "=" expr ";"
;   args        ::= arg ("," arg)*
;   arg         ::= expr | "STDIN"
;   expr        ::= primary (("+"|"-") primary)*
;   primary     ::= INT | STRING | CV
;   CV          ::= "$" IDENT
;
; 対応 intrinsic: nes_cls / nes_chr_bg / nes_chr_spr / nes_bg_color /
;                 nes_palette / nes_puts / fgets
; =============================================================================

; --- Token kind ---
TK_EOF     = 0
TK_ECHO    = 1
TK_STRING  = 2
TK_SEMI    = 3
TK_IDENT   = 4
TK_INT     = 5
TK_LPAREN  = 6
TK_RPAREN  = 7
TK_COMMA   = 8
TK_CV      = 9
TK_ASSIGN  = 10
TK_PLUS    = 11
TK_MINUS   = 12

; --- Intrinsic ID ---
INT_CLS       = 0
INT_CHR_BG    = 1
INT_CHR_SPR   = 2
INT_BG_COLOR  = 3
INT_PALETTE   = 4
INT_PUTS      = 5
INT_FGETS     = 6
INT_NOT_FOUND = $FF

ARG_STDIN_SENTINEL = $FE

; =============================================================================
; compile_and_emit: エントリポイント (reset から JSR)
; =============================================================================
compile_and_emit:
    JSR cmp_init
    JSR cmp_skip_php_tag
    JSR cmp_parse_program
    JSR cmp_finalize
    RTS

; -----------------------------------------------------------------------------
; cmp_init: ZP 状態初期化
; -----------------------------------------------------------------------------
cmp_init:
    LDA #<PHP_SRC_BODY
    STA CMP_SRC_PTR
    LDA #>PHP_SRC_BODY
    STA CMP_SRC_PTR+1
    CLC
    LDA #<PHP_SRC_BODY
    ADC PHP_SRC_LEN
    STA CMP_SRC_END
    LDA #>PHP_SRC_BODY
    ADC PHP_SRC_LEN+1
    STA CMP_SRC_END+1
    ; 行/列を 1 に
    LDA #1
    STA CMP_LINE
    STA CMP_COL
    LDA #0
    STA CMP_LINE+1
    STA CMP_COL+1
    ; emit head
    LDA #<OPS_FIRST_OP
    STA CMP_OP_HEAD
    LDA #>OPS_FIRST_OP
    STA CMP_OP_HEAD+1
    LDA #<CMP_LIT_STAGE
    STA CMP_LIT_HEAD
    LDA #>CMP_LIT_STAGE
    STA CMP_LIT_HEAD+1
    LDA #0
    STA CMP_OP_COUNT
    STA CMP_OP_COUNT+1
    STA CMP_LIT_COUNT
    STA CMP_LIT_COUNT+1
    STA CMP_TMP_COUNT
    STA CMP_CV_COUNT
    RTS

; -----------------------------------------------------------------------------
; cmp_skip_php_tag: 先頭の <?php を消費
; -----------------------------------------------------------------------------
cmp_skip_php_tag:
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'<'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'?'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'p'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'h'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'p'
    BEQ :+
    JMP cmp_error
:
    LDA #5
    JSR cmp_advance_n
    RTS

; =============================================================================
; parse_program: stmt* EOF
; =============================================================================
cmp_parse_program:
cpp_loop:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_EOF
    BNE cpl_chk_echo
    JMP cpp_emit_return
cpl_chk_echo:
    CMP #TK_ECHO
    BNE cpl_chk_ident
    JMP cpp_echo
cpl_chk_ident:
    CMP #TK_IDENT
    BNE cpl_chk_cv
    JMP cpp_call_stmt
cpl_chk_cv:
    CMP #TK_CV
    BNE cpl_err
    JMP cpp_assign_stmt
cpl_err:
    JMP cmp_error

; --- echo expr ';' ---
cpp_echo:
    JSR cmp_lex_next            ; first token of expr
    JSR cmp_parse_expr          ; emits literal/binaries, CMP_EXPR = result
    LDA #ZEND_ECHO
    JSR cmp_emit_op_expr1
    LDA CMP_TOK_KIND            ; parse_expr は terminator をここに置く
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    JMP cpp_loop

; --- CV '=' expr ';' ---
cpp_assign_stmt:
    ; CMP_TOK_PTR/LEN = CV 名
    JSR cmp_cv_intern
    STA CMP_ASSIGN_SLOT
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_ASSIGN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next            ; first token of RHS expr
    JSR cmp_parse_expr
    JSR cmp_emit_assign
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    JMP cpp_loop

; --- IDENT '(' args ')' ';' ---
cpp_call_stmt:
    JSR cmp_match_intrinsic
    CMP #INT_NOT_FOUND
    BNE :+
    JMP cmp_error
:
    STA CMP_INTRINSIC_ID
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    LDA #0
    STA CMP_ARG_COUNT
    JSR cmp_lex_next            ; 最初の arg or ')'
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BNE ccs_args
    JMP ccs_rparen_done
ccs_args:
    JSR cmp_parse_arg           ; CMP_TOK_KIND は arg 後の token (, or ))
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ ccs_rparen_done
    CMP #TK_COMMA
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next            ; 次 arg の先頭 token
    JMP ccs_args

ccs_rparen_done:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    JSR cmp_emit_intrinsic
    JMP cpp_loop

cpp_emit_return:
    JSR cmp_emit_zval_long_1
    LDA #ZEND_RETURN
    JSR cmp_emit_op_const1
    RTS

; =============================================================================
; error display + halt
; =============================================================================
cmp_error:
    JSR show_compile_error
cmp_error_halt:
    JMP cmp_error_halt

; show_compile_error: nametable に "ERR Lnn Cnn" を書き、rendering を ON
show_compile_error:
    BIT PPUSTATUS
    LDA #$21                    ; nametable $2160 (row 11, col 0)
    STA PPUADDR
    LDA #$60
    STA PPUADDR
    LDA #'E'
    STA PPUDATA
    LDA #'R'
    STA PPUDATA
    STA PPUDATA
    LDA #' '
    STA PPUDATA
    LDA #'L'
    STA PPUDATA
    LDA CMP_LINE
    STA TMP0
    LDA CMP_LINE+1
    STA TMP0+1
    JSR print_int16
    LDX #0
sce_wline:
    CPX pi_count
    BEQ sce_line_done
    LDA INT_PRINT_BUFFER, X
    STA PPUDATA
    INX
    JMP sce_wline
sce_line_done:
    LDA #' '
    STA PPUDATA
    LDA #'C'
    STA PPUDATA
    LDA CMP_COL
    STA TMP0
    LDA CMP_COL+1
    STA TMP0+1
    JSR print_int16
    LDX #0
sce_wcol:
    CPX pi_count
    BEQ sce_col_done
    LDA INT_PRINT_BUFFER, X
    STA PPUDATA
    INX
    JMP sce_wcol
sce_col_done:
    ; scroll reset + BG enable
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL
    LDA #%00001010
    STA PPUMASK
    RTS

; =============================================================================
; parse_arg: 1 引数を parse (CMP_TOK_KIND = 最初の token で entry)
;   - IDENT → STDIN 専用扱い
;   - それ以外 → parse_expr で処理
; エントリ後の CMP_ARG_COUNT に結果を追加し、CMP_TOK_KIND を後続 token に
; =============================================================================
cmp_parse_arg:
    LDA CMP_TOK_KIND
    CMP #TK_IDENT
    BNE cpa_expr
    JMP cpa_stdin

cpa_stdin:
    ; "STDIN" か確認
    LDA CMP_TOK_LEN
    CMP #5
    BEQ :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_TOK_PTR), Y
    CMP #'S'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'T'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'D'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'I'
    BEQ :+
    JMP cmp_error
:
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'N'
    BEQ :+
    JMP cmp_error
:
    LDX CMP_ARG_COUNT
    CPX #4
    BCC :+
    JMP cmp_error
:
    LDA #ARG_STDIN_SENTINEL
    STA CMP_ARG_TYPES, X
    INC CMP_ARG_COUNT
    JSR cmp_lex_next            ; peek next
    RTS

cpa_expr:
    JSR cmp_parse_expr
    LDX CMP_ARG_COUNT
    CPX #4
    BCC :+
    JMP cmp_error
:
    ; CMP_EXPR を CMP_ARG_LITS[X*2..] と CMP_ARG_TYPES[X] に保存
    LDA CMP_EXPR_TYPE
    STA CMP_ARG_TYPES, X
    TXA
    ASL A
    TAY
    LDA CMP_EXPR_VAL
    STA CMP_ARG_LITS, Y
    INY
    LDA CMP_EXPR_VAL+1
    STA CMP_ARG_LITS, Y
    INC CMP_ARG_COUNT
    RTS

; =============================================================================
; parse_expr: primary (('+'|'-') primary)*
; parse_primary: INT | STRING | CV
;
; 戻り時 CMP_EXPR_TYPE/VAL に結果 operand、CMP_TOK_KIND は後続 token
; =============================================================================
cmp_parse_expr:
    JSR cmp_parse_primary
cpe_loop:
    LDA CMP_TOK_KIND
    CMP #TK_PLUS
    BNE cpe_chk_minus
    LDA #ZEND_ADD
    JMP cpe_binop
cpe_chk_minus:
    CMP #TK_MINUS
    BNE cpe_done
    LDA #ZEND_SUB
cpe_binop:
    ; save opcode
    STA CMP_INTRINSIC_ID        ; 流用: 二項演算 opcode 保存先
    ; save current CMP_EXPR as LHS
    LDA CMP_EXPR_TYPE
    STA CMP_LHS_TYPE
    LDA CMP_EXPR_VAL
    STA CMP_LHS_VAL
    LDA CMP_EXPR_VAL+1
    STA CMP_LHS_VAL+1
    ; consume operator, fetch right primary's first token
    JSR cmp_lex_next
    JSR cmp_parse_primary
    ; emit binary (CMP_LHS, CMP_EXPR, opcode in CMP_INTRINSIC_ID)
    JSR cmp_emit_binary
    JMP cpe_loop
cpe_done:
    RTS

cmp_parse_primary:
    LDA CMP_TOK_KIND
    CMP #TK_INT
    BEQ cpp_int
    CMP #TK_STRING
    BEQ cpp_str
    CMP #TK_CV
    BEQ cpp_cv
    JMP cmp_error

cpp_int:
    JSR cmp_emit_zval_long_value
    ; TMP1 = lit_idx、CMP_EXPR_VAL = lit_idx * 16
    LDX TMP1
    JSR cmp_lit_idx_to_offset
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_CONST
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next            ; peek next
    RTS

cpp_str:
    SEC
    LDA CMP_TOK_PTR
    SBC #<OPS_BASE
    STA TMP0
    LDA CMP_TOK_PTR+1
    SBC #>OPS_BASE
    STA TMP0+1
    JSR cmp_emit_zval_string
    LDX TMP1
    JSR cmp_lit_idx_to_offset
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_CONST
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next
    RTS

cpp_cv:
    JSR cmp_cv_intern
    ; A = slot
    TAX
    JSR cmp_lit_idx_to_offset
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_CV
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next
    RTS

; =============================================================================
; CV シンボル表
;   CMP_CV_TABLE ($0700) から 4B エントリ: [name_len, name_ptr_lo, name_ptr_hi, pad]
;   最大 32 スロット
;
; cmp_cv_intern:
;   入力: CMP_TOK_PTR/LEN = CV 名
;   戻り: A = スロット番号 (0..CMP_CV_COUNT-1)、既存なら再利用、なければ新規 alloc
; =============================================================================
cmp_cv_intern:
    LDX #0
ccv_find:
    CPX CMP_CV_COUNT
    BEQ ccv_alloc
    ; Entry アドレス = CMP_CV_TABLE + X*4
    TXA
    ASL A
    ASL A                        ; A = X*4
    TAY
    LDA CMP_CV_TABLE, Y          ; len
    CMP CMP_TOK_LEN
    BNE ccv_skip
    ; len 一致、ptr を TMP1 に取って中身比較
    INY
    LDA CMP_CV_TABLE, Y
    STA TMP1
    INY
    LDA CMP_CV_TABLE, Y
    STA TMP1+1
    ; 中身比較
    LDY #0
ccv_cmp:
    CPY CMP_TOK_LEN
    BEQ ccv_match
    LDA (TMP1), Y
    CMP (CMP_TOK_PTR), Y
    BNE ccv_skip
    INY
    BNE ccv_cmp
ccv_match:
    TXA
    RTS
ccv_skip:
    INX
    JMP ccv_find

ccv_alloc:
    ; 新規スロット
    CPX #32
    BCC :+
    JMP cmp_error                ; CV が多すぎる
:
    TXA
    ASL A
    ASL A                        ; X*4
    TAY
    LDA CMP_TOK_LEN
    STA CMP_CV_TABLE, Y
    INY
    LDA CMP_TOK_PTR
    STA CMP_CV_TABLE, Y
    INY
    LDA CMP_TOK_PTR+1
    STA CMP_CV_TABLE, Y
    INY
    LDA #0
    STA CMP_CV_TABLE, Y          ; pad
    TXA                          ; X = 元の CMP_CV_COUNT = 新スロット番号
    INC CMP_CV_COUNT
    RTS

; =============================================================================
; LEXER
; =============================================================================
cmp_lex_next:
    JSR cmp_skip_ws
    JSR cmp_at_eof
    BNE cln_not_eof
    LDA #TK_EOF
    STA CMP_TOK_KIND
    RTS
cln_not_eof:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'"'
    BNE :+
    JMP cln_string
:
    CMP #';'
    BNE :+
    JMP cln_semi
:
    CMP #'('
    BNE :+
    JMP cln_lparen
:
    CMP #')'
    BNE :+
    JMP cln_rparen
:
    CMP #','
    BNE :+
    JMP cln_comma
:
    CMP #'$'
    BNE :+
    JMP cln_cv
:
    CMP #'='
    BNE :+
    JMP cln_assign
:
    CMP #'+'
    BNE :+
    JMP cln_plus
:
    CMP #'-'
    BNE :+
    JMP cln_minus
:
    ; 数字?
    CMP #'0'
    BCC cln_try_ident
    CMP #'9'+1
    BCS cln_try_ident
    JMP cln_int
cln_try_ident:
    JSR is_ident_start
    BCC :+
    JMP cln_ident
:
    JMP cmp_error

cln_semi:
    JSR cmp_advance1
    LDA #TK_SEMI
    STA CMP_TOK_KIND
    RTS

cln_lparen:
    JSR cmp_advance1
    LDA #TK_LPAREN
    STA CMP_TOK_KIND
    RTS

cln_rparen:
    JSR cmp_advance1
    LDA #TK_RPAREN
    STA CMP_TOK_KIND
    RTS

cln_comma:
    JSR cmp_advance1
    LDA #TK_COMMA
    STA CMP_TOK_KIND
    RTS

cln_assign:
    JSR cmp_advance1
    LDA #TK_ASSIGN
    STA CMP_TOK_KIND
    RTS

cln_plus:
    JSR cmp_advance1
    LDA #TK_PLUS
    STA CMP_TOK_KIND
    RTS

cln_minus:
    JSR cmp_advance1
    LDA #TK_MINUS
    STA CMP_TOK_KIND
    RTS

cln_cv:
    JSR cmp_advance1             ; `$` を消費
    LDA CMP_SRC_PTR
    STA CMP_TOK_PTR
    LDA CMP_SRC_PTR+1
    STA CMP_TOK_PTR+1
    LDX #0
cln_cv_loop:
    JSR cmp_at_eof
    BEQ cln_cv_done
    LDY #0
    LDA (CMP_SRC_PTR), Y
    JSR is_ident_cont
    BCC cln_cv_done
    JSR cmp_advance1
    INX
    CPX #$FF
    BCC cln_cv_loop
    JMP cmp_error
cln_cv_done:
    TXA
    BNE :+
    JMP cmp_error                ; `$` alone (no ident)
:
    STX CMP_TOK_LEN
    LDA #TK_CV
    STA CMP_TOK_KIND
    RTS

cln_string:
    JSR cmp_advance1
    LDA CMP_SRC_PTR
    STA CMP_TOK_PTR
    LDA CMP_SRC_PTR+1
    STA CMP_TOK_PTR+1
    LDX #0
cln_str_loop:
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'"'
    BEQ cln_str_end
    JSR cmp_advance1
    INX
    CPX #$FF
    BCC cln_str_loop
    JMP cmp_error
cln_str_end:
    STX CMP_TOK_LEN
    JSR cmp_advance1             ; 閉じ `"`
    LDA #TK_STRING
    STA CMP_TOK_KIND
    RTS

cln_int:
    LDA #0
    STA CMP_TOK_VALUE
    STA CMP_TOK_VALUE+1
cln_int_loop:
    JSR cmp_at_eof
    BEQ cln_int_done
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'0'
    BCC cln_int_done
    CMP #'9'+1
    BCS cln_int_done
    SEC
    SBC #'0'
    PHA
    LDA CMP_TOK_VALUE
    STA TMP1
    LDA CMP_TOK_VALUE+1
    STA TMP1+1
    ASL TMP1
    ROL TMP1+1
    LDA TMP1
    STA TMP2
    LDA TMP1+1
    STA TMP2+1
    ASL TMP1
    ROL TMP1+1
    ASL TMP1
    ROL TMP1+1
    CLC
    LDA TMP1
    ADC TMP2
    STA CMP_TOK_VALUE
    LDA TMP1+1
    ADC TMP2+1
    STA CMP_TOK_VALUE+1
    PLA
    CLC
    ADC CMP_TOK_VALUE
    STA CMP_TOK_VALUE
    LDA CMP_TOK_VALUE+1
    ADC #0
    STA CMP_TOK_VALUE+1
    JSR cmp_advance1
    JMP cln_int_loop
cln_int_done:
    LDA #TK_INT
    STA CMP_TOK_KIND
    RTS

cln_ident:
    LDA CMP_SRC_PTR
    STA CMP_TOK_PTR
    LDA CMP_SRC_PTR+1
    STA CMP_TOK_PTR+1
    LDX #0
cli_loop:
    JSR cmp_at_eof
    BEQ cli_done
    LDY #0
    LDA (CMP_SRC_PTR), Y
    JSR is_ident_cont
    BCC cli_done
    JSR cmp_advance1
    INX
    CPX #$FF
    BCC cli_loop
    JMP cmp_error
cli_done:
    STX CMP_TOK_LEN
    ; "echo" 判定
    CPX #4
    BNE cli_is_ident
    LDY #0
    LDA (CMP_TOK_PTR), Y
    CMP #'e'
    BNE cli_is_ident
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'c'
    BNE cli_is_ident
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'h'
    BNE cli_is_ident
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'o'
    BNE cli_is_ident
    LDA #TK_ECHO
    STA CMP_TOK_KIND
    RTS
cli_is_ident:
    LDA #TK_IDENT
    STA CMP_TOK_KIND
    RTS

is_ident_start:
    CMP #'_'
    BEQ iis_yes
    CMP #'A'
    BCC iis_no
    CMP #'Z'+1
    BCC iis_yes
    CMP #'a'
    BCC iis_no
    CMP #'z'+1
    BCC iis_yes
iis_no:
    CLC
    RTS
iis_yes:
    SEC
    RTS

is_ident_cont:
    CMP #'_'
    BEQ iic_yes
    CMP #'0'
    BCC iic_no
    CMP #'9'+1
    BCC iic_yes
    CMP #'A'
    BCC iic_no
    CMP #'Z'+1
    BCC iic_yes
    CMP #'a'
    BCC iic_no
    CMP #'z'+1
    BCC iic_yes
iic_no:
    CLC
    RTS
iic_yes:
    SEC
    RTS

; -----------------------------------------------------------------------------
; position / advance helpers (line/col 追跡あり)
; -----------------------------------------------------------------------------
cmp_skip_ws:
    JSR cmp_at_eof
    BEQ csw_done
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #' '
    BEQ csw_skip
    CMP #9
    BEQ csw_skip
    CMP #10
    BEQ csw_skip
    CMP #13
    BEQ csw_skip
    RTS
csw_skip:
    JSR cmp_advance1
    JMP cmp_skip_ws
csw_done:
    RTS

cmp_at_eof:
    LDA CMP_SRC_PTR+1
    CMP CMP_SRC_END+1
    BNE cae_no
    LDA CMP_SRC_PTR
    CMP CMP_SRC_END
    BNE cae_no
    LDA #0
    RTS
cae_no:
    LDA #1
    RTS

; cmp_advance1: src_ptr を 1 進める + line/col を更新
cmp_advance1:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #10                      ; LF?
    BNE ca1_notLF
    INC CMP_LINE
    BNE :+
    INC CMP_LINE+1
:
    LDA #1
    STA CMP_COL
    LDA #0
    STA CMP_COL+1
    JMP ca1_pos
ca1_notLF:
    INC CMP_COL
    BNE ca1_pos
    INC CMP_COL+1
ca1_pos:
    INC CMP_SRC_PTR
    BNE ca1_ret
    INC CMP_SRC_PTR+1
ca1_ret:
    RTS

; cmp_advance_n: A 分進める (LF 非含有前提、<?php や echo の固定長 skip 用)
cmp_advance_n:
    PHA
    CLC
    ADC CMP_SRC_PTR
    STA CMP_SRC_PTR
    BCC :+
    INC CMP_SRC_PTR+1
:
    PLA
    CLC
    ADC CMP_COL
    STA CMP_COL
    BCC can_ret
    INC CMP_COL+1
can_ret:
    RTS

; =============================================================================
; intrinsic 解決
; =============================================================================
cmp_match_intrinsic:
    LDA #<intrinsic_name_nes_cls
    LDX #>intrinsic_name_nes_cls
    LDY #7
    JSR cmi_try_match
    BCS :+
    LDA #INT_CLS
    RTS
:
    LDA #<intrinsic_name_nes_chr_bg
    LDX #>intrinsic_name_nes_chr_bg
    LDY #10
    JSR cmi_try_match
    BCS :+
    LDA #INT_CHR_BG
    RTS
:
    LDA #<intrinsic_name_nes_chr_spr
    LDX #>intrinsic_name_nes_chr_spr
    LDY #11
    JSR cmi_try_match
    BCS :+
    LDA #INT_CHR_SPR
    RTS
:
    LDA #<intrinsic_name_nes_bg_color
    LDX #>intrinsic_name_nes_bg_color
    LDY #12
    JSR cmi_try_match
    BCS :+
    LDA #INT_BG_COLOR
    RTS
:
    LDA #<intrinsic_name_nes_palette
    LDX #>intrinsic_name_nes_palette
    LDY #11
    JSR cmi_try_match
    BCS :+
    LDA #INT_PALETTE
    RTS
:
    LDA #<intrinsic_name_nes_puts
    LDX #>intrinsic_name_nes_puts
    LDY #8
    JSR cmi_try_match
    BCS :+
    LDA #INT_PUTS
    RTS
:
    LDA #<intrinsic_name_fgets
    LDX #>intrinsic_name_fgets
    LDY #5
    JSR cmi_try_match
    BCS :+
    LDA #INT_FGETS
    RTS
:
    LDA #INT_NOT_FOUND
    RTS

cmi_try_match:
    STA TMP1
    STX TMP1+1
    TYA
    CMP CMP_TOK_LEN
    BNE ctm_no
    TAX
    LDY #0
ctm_loop:
    LDA (TMP1), Y
    CMP (CMP_TOK_PTR), Y
    BNE ctm_no
    INY
    DEX
    BNE ctm_loop
    CLC
    RTS
ctm_no:
    SEC
    RTS

intrinsic_name_nes_cls:       .byte "nes_cls"
intrinsic_name_nes_chr_bg:    .byte "nes_chr_bg"
intrinsic_name_nes_chr_spr:   .byte "nes_chr_spr"
intrinsic_name_nes_bg_color:  .byte "nes_bg_color"
intrinsic_name_nes_palette:   .byte "nes_palette"
intrinsic_name_nes_puts:      .byte "nes_puts"
intrinsic_name_fgets:         .byte "fgets"

; =============================================================================
; intrinsic 発行 (dispatch + 各 emitter)
; =============================================================================
cmp_emit_intrinsic:
    LDA CMP_INTRINSIC_ID
    ASL A
    TAX
    LDA cmp_emit_jmp_table, X
    STA TMP0
    LDA cmp_emit_jmp_table+1, X
    STA TMP0+1
    JMP (TMP0)

cmp_emit_jmp_table:
    .word cmp_emit_cls
    .word cmp_emit_chr_bg
    .word cmp_emit_chr_spr
    .word cmp_emit_bg_color
    .word cmp_emit_palette
    .word cmp_emit_puts
    .word cmp_emit_fgets

cmp_emit_cls:
    LDA CMP_ARG_COUNT
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDY #20
    LDA #NESPHP_NES_CLS
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_emit_chr_bg:
    LDA CMP_ARG_COUNT
    CMP #1
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDY #20
    LDA #NESPHP_NES_CHR_BG
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_emit_chr_spr:
    LDA CMP_ARG_COUNT
    CMP #1
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDY #20
    LDA #NESPHP_NES_CHR_SPR
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_emit_bg_color:
    LDA CMP_ARG_COUNT
    CMP #1
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDY #20
    LDA #NESPHP_NES_BG_COLOR
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_emit_palette:
    LDA CMP_ARG_COUNT
    CMP #4
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDX #1
    JSR cmp_set_op2_from_arg
    LDX #2
    JSR cmp_set_result_from_arg
    LDX #3
    JSR cmp_set_extended_from_arg
    LDY #20
    LDA #NESPHP_NES_PALETTE
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_emit_puts:
    LDA CMP_ARG_COUNT
    CMP #3
    BEQ :+
    JMP cmp_error
:
    ; 第 3 引数 (string) はリテラル必須 (IS_CONST)
    LDA CMP_ARG_TYPES+2
    CMP #IS_CONST
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDX #1
    JSR cmp_set_op2_from_arg
    LDX #2
    JSR cmp_set_extended_from_arg
    LDY #20
    LDA #NESPHP_NES_PUTS
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_emit_fgets:
    LDA CMP_ARG_COUNT
    CMP #1
    BEQ :+
    JMP cmp_error
:
    LDA CMP_ARG_TYPES+0
    CMP #ARG_STDIN_SENTINEL
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    ; result_type = IS_UNUSED、戻り値は破棄
    LDY #20
    LDA #NESPHP_FGETS
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; =============================================================================
; zend_op emit helpers
; =============================================================================
cmp_op24_zero:
    LDY #23
    LDA #0
coz_loop:
    STA (CMP_OP_HEAD), Y
    DEY
    BPL coz_loop
    RTS

cmp_op_finish:
    CLC
    LDA CMP_OP_HEAD
    ADC #24
    STA CMP_OP_HEAD
    BCC :+
    INC CMP_OP_HEAD+1
:
    INC CMP_OP_COUNT
    BNE :+
    INC CMP_OP_COUNT+1
:
    RTS

; cmp_lit_idx_to_offset: X (lit_idx or slot) → TMP0 (X * 16, 16bit)
cmp_lit_idx_to_offset:
    TXA
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
    RTS

; cmp_set_op1_from_arg: X = arg index (0..3)
;   op (bytes 0-3) = CMP_ARG_LITS[X*2..X*2+1]、op1_type = CMP_ARG_TYPES[X]
cmp_set_op1_from_arg:
    STX TMP2
    TXA
    ASL A
    TAY
    LDA CMP_ARG_LITS, Y
    STA TMP0
    INY
    LDA CMP_ARG_LITS, Y
    STA TMP0+1
    LDX TMP2
    LDA CMP_ARG_TYPES, X
    STA TMP1
    LDY #0
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA TMP1
    STA (CMP_OP_HEAD), Y
    RTS

cmp_set_op2_from_arg:
    STX TMP2
    TXA
    ASL A
    TAY
    LDA CMP_ARG_LITS, Y
    STA TMP0
    INY
    LDA CMP_ARG_LITS, Y
    STA TMP0+1
    LDX TMP2
    LDA CMP_ARG_TYPES, X
    STA TMP1
    LDY #4
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA TMP1
    STA (CMP_OP_HEAD), Y
    RTS

cmp_set_result_from_arg:
    STX TMP2
    TXA
    ASL A
    TAY
    LDA CMP_ARG_LITS, Y
    STA TMP0
    INY
    LDA CMP_ARG_LITS, Y
    STA TMP0+1
    LDX TMP2
    LDA CMP_ARG_TYPES, X
    STA TMP1
    LDY #8
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #23
    LDA TMP1
    STA (CMP_OP_HEAD), Y
    RTS

cmp_set_extended_from_arg:
    TXA
    ASL A
    TAY
    LDA CMP_ARG_LITS, Y
    STA TMP0
    INY
    LDA CMP_ARG_LITS, Y
    STA TMP0+1
    LDY #12
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    RTS

; =============================================================================
; cmp_emit_assign: ZEND_ASSIGN op1=CV(CMP_ASSIGN_SLOT), op2=CMP_EXPR
; =============================================================================
cmp_emit_assign:
    JSR cmp_op24_zero
    ; op1: CMP_ASSIGN_SLOT * 16 + IS_CV
    LDX CMP_ASSIGN_SLOT
    JSR cmp_lit_idx_to_offset
    LDY #0
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA #IS_CV
    STA (CMP_OP_HEAD), Y
    ; op2: CMP_EXPR_VAL + CMP_EXPR_TYPE
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    ; opcode
    LDY #20
    LDA #ZEND_ASSIGN
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; =============================================================================
; cmp_emit_binary: ZEND_ADD/SUB op1=CMP_LHS, op2=CMP_EXPR, result=TMP_new
;   入力: CMP_INTRINSIC_ID = opcode (ZEND_ADD or ZEND_SUB)
;   出力: CMP_EXPR_TYPE/VAL = TMP_new の ref
; =============================================================================
cmp_emit_binary:
    JSR cmp_op24_zero
    ; op1 = LHS
    LDY #0
    LDA CMP_LHS_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_LHS_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA CMP_LHS_TYPE
    STA (CMP_OP_HEAD), Y
    ; op2 = RHS (CMP_EXPR)
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    ; result = 新 TMP slot * 16、result_type = IS_TMP_VAR
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error                ; TMP slot 超過
:
    JSR cmp_lit_idx_to_offset
    LDY #8
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #23
    LDA #IS_TMP_VAR
    STA (CMP_OP_HEAD), Y
    ; opcode
    LDY #20
    LDA CMP_INTRINSIC_ID
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    ; CMP_EXPR は新 TMP を指す
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    INC CMP_TMP_COUNT
    RTS

; =============================================================================
; cmp_emit_op_expr1 (echo / return 用): op1 = CMP_EXPR
; =============================================================================
cmp_emit_op_expr1:
    STA TMP2                     ; opcode
    JSR cmp_op24_zero
    LDY #0
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA TMP2
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; 既存との互換用: op1 に literal[TMP1] を IS_CONST で入れる
cmp_emit_op_const1:
    STA TMP2
    JSR cmp_op24_zero
    LDX TMP1
    JSR cmp_lit_idx_to_offset
    LDY #0
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA #IS_CONST
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA TMP2
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; =============================================================================
; literal emitters
; =============================================================================
cmp_emit_zval_string:
    LDA CMP_LIT_COUNT
    STA TMP1
    LDA CMP_LIT_COUNT+1
    STA TMP1+1
    LDY #15
    LDA #0
cezvs_zero:
    STA (CMP_LIT_HEAD), Y
    DEY
    BPL cezvs_zero
    LDY #0
    LDA TMP0
    STA (CMP_LIT_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_LIT_HEAD), Y
    INY
    LDA CMP_TOK_LEN
    STA (CMP_LIT_HEAD), Y
    LDY #8
    LDA #TYPE_STRING
    STA (CMP_LIT_HEAD), Y
    CLC
    LDA CMP_LIT_HEAD
    ADC #16
    STA CMP_LIT_HEAD
    BCC :+
    INC CMP_LIT_HEAD+1
:
    INC CMP_LIT_COUNT
    BNE :+
    INC CMP_LIT_COUNT+1
:
    RTS

cmp_emit_zval_long_value:
    LDA CMP_LIT_COUNT
    STA TMP1
    LDA CMP_LIT_COUNT+1
    STA TMP1+1
    LDY #15
    LDA #0
cezlv_zero:
    STA (CMP_LIT_HEAD), Y
    DEY
    BPL cezlv_zero
    LDY #0
    LDA CMP_TOK_VALUE
    STA (CMP_LIT_HEAD), Y
    INY
    LDA CMP_TOK_VALUE+1
    STA (CMP_LIT_HEAD), Y
    LDY #8
    LDA #TYPE_LONG
    STA (CMP_LIT_HEAD), Y
    CLC
    LDA CMP_LIT_HEAD
    ADC #16
    STA CMP_LIT_HEAD
    BCC :+
    INC CMP_LIT_HEAD+1
:
    INC CMP_LIT_COUNT
    BNE :+
    INC CMP_LIT_COUNT+1
:
    RTS

cmp_emit_zval_long_1:
    LDA #1
    STA CMP_TOK_VALUE
    LDA #0
    STA CMP_TOK_VALUE+1
    JSR cmp_emit_zval_long_value
    RTS

; =============================================================================
; cmp_finalize
; =============================================================================
cmp_finalize:
    LDA #<CMP_LIT_STAGE
    STA TMP0
    LDA #>CMP_LIT_STAGE
    STA TMP0+1
    LDA CMP_OP_HEAD
    STA TMP1
    LDA CMP_OP_HEAD+1
    STA TMP1+1
    LDA CMP_LIT_COUNT
    STA TMP2
    LDA CMP_LIT_COUNT+1
    STA TMP2+1
    ASL TMP2
    ROL TMP2+1
    ASL TMP2
    ROL TMP2+1
    ASL TMP2
    ROL TMP2+1
    ASL TMP2
    ROL TMP2+1

cf_copy_loop:
    LDA TMP2
    ORA TMP2+1
    BEQ cf_copy_done
    LDY #0
    LDA (TMP0), Y
    STA (TMP1), Y
    INC TMP0
    BNE cf_adv_dst
    INC TMP0+1
cf_adv_dst:
    INC TMP1
    BNE cf_dec_size
    INC TMP1+1
cf_dec_size:
    LDA TMP2
    BNE cf_lo_nz
    DEC TMP2+1
cf_lo_nz:
    DEC TMP2
    JMP cf_copy_loop
cf_copy_done:

    LDA CMP_OP_COUNT
    STA HDR_NUM_OPS
    LDA CMP_OP_COUNT+1
    STA HDR_NUM_OPS+1

    SEC
    LDA CMP_OP_HEAD
    SBC #<OPS_BASE
    STA HDR_LITERALS_OFF
    LDA CMP_OP_HEAD+1
    SBC #>OPS_BASE
    STA HDR_LITERALS_OFF+1

    LDA CMP_LIT_COUNT
    STA HDR_NUM_LITERALS
    LDA CMP_LIT_COUNT+1
    STA HDR_NUM_LITERALS+1

    LDA CMP_CV_COUNT
    STA HDR_NUM_CVS
    LDA #0
    STA HDR_NUM_CVS+1
    LDA CMP_TMP_COUNT
    STA HDR_NUM_TMPS
    LDA #0
    STA HDR_NUM_TMPS+1

    LDA #8
    STA HDR_PHP_MAJOR
    LDA #4
    STA HDR_PHP_MINOR

    LDA #0
    STA OPS_BASE+12
    STA OPS_BASE+13
    STA OPS_BASE+14
    STA OPS_BASE+15

    RTS
