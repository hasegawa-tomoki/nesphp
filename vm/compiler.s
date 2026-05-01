; =============================================================================
; compiler.s — on-NES PHP コンパイラ (L3S, spec/13-compiler.md)
;
; Milestone: M-A' + P1 + P2 + P3
;   - M-A': echo "..."; + <?php
;   - P1: intrinsic + 整数リテラル + fgets 単独
;   - P2: CV + assign + 整数算術 + エラー表示
;   - P3 (M-C): while + if + 比較 + block + fgets-as-expr + backpatch
;
; 対応構文:
;   program     ::= "<?php" stmt* EOF
;   stmt        ::= echo_stmt | call_stmt | assign_stmt | while_stmt | if_stmt
;   echo_stmt   ::= "echo" expr ";"
;   call_stmt   ::= IDENT "(" args? ")" ";"
;   assign_stmt ::= CV "=" expr ";"
;   while_stmt  ::= "while" "(" expr ")" "{" stmt* "}"
;   if_stmt     ::= "if" "(" expr ")" "{" stmt* "}"
;   expr        ::= add_expr (cmp_op add_expr)?
;   cmp_op      ::= "===" | "!==" | "==" | "!=" | "<"
;   add_expr    ::= primary (("+"|"-") primary)*
;   primary     ::= INT | STRING | CV | "true" | call_expr
;   call_expr   ::= IDENT "(" args? ")"  (現状 fgets のみ、戻り値 TMP)
;   args        ::= arg ("," arg)*
;   arg         ::= expr | "STDIN"
;   CV          ::= "$" IDENT
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
TK_WHILE   = 13
TK_IF      = 14
TK_LBRACE  = 15
TK_RBRACE  = 16
TK_LT      = 17
TK_EQ2     = 18
TK_EQ3     = 19
TK_NEQ2    = 20
TK_NEQ3    = 21
TK_TRUE    = 22
TK_INC     = 23
TK_DEC     = 24
TK_FOR     = 25
TK_AMP     = 26
TK_PIPE    = 27
TK_AMPAMP  = 28
TK_PIPEPIPE = 29
TK_SL      = 30
TK_SR      = 31
TK_LBRACKET = 32
TK_RBRACKET = 33

; --- Intrinsic ID ---
INT_CLS         = 0
INT_CHR_BG      = 1
INT_CHR_SPR     = 2
INT_BG_COLOR    = 3
INT_PALETTE     = 4
INT_PUTS        = 5
INT_FGETS       = 6
INT_PUT         = 7
INT_SPRITE_AT   = 8     ; nes_sprite_at($idx, $x, $y, $tile)
INT_ATTR        = 9
INT_VSYNC       = 10
INT_BTN         = 11
INT_COUNT       = 12
INT_SPRITE_ATTR = 13    ; nes_sprite_attr($idx, $attr)
INT_NOT_FOUND   = $FF

ARG_STDIN_SENTINEL = $FE

; =============================================================================
compile_and_emit:
    JSR cmp_init
    JSR cmp_skip_php_tag
    JSR cmp_parse_program
    JSR cmp_finalize
    RTS

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
    LDA #1
    STA CMP_LINE
    STA CMP_COL
    LDA #0
    STA CMP_LINE+1
    STA CMP_COL+1
    LDA #<OPS_FIRST_OP
    STA CMP_OP_HEAD
    LDA #>OPS_FIRST_OP
    STA CMP_OP_HEAD+1
    LDA #<CMP_LIT_STAGE
    STA CMP_LIT_HEAD
    LDA #>CMP_LIT_STAGE
    STA CMP_LIT_HEAD+1
    LDA #<STR_POOL_BASE
    STA CMP_STRPOOL_HEAD
    LDA #>STR_POOL_BASE
    STA CMP_STRPOOL_HEAD+1
    LDA #0
    STA CMP_OP_COUNT
    STA CMP_OP_COUNT+1
    STA CMP_LIT_COUNT
    STA CMP_LIT_COUNT+1
    STA CMP_TMP_COUNT
    STA CMP_CV_COUNT
    STA CMP_BP_TOP
    RTS

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
    BNE :+
    JMP cpp_emit_return
:
    JSR cmp_dispatch_stmt
    JMP cpp_loop

cpp_emit_return:
    JSR cmp_emit_zval_long_1
    LDA #ZEND_RETURN
    JSR cmp_emit_op_const1
    RTS

; -----------------------------------------------------------------------------
; cmp_dispatch_stmt: CMP_TOK_KIND に応じて文ハンドラへ
;   各ハンドラは RTS で返ってくる (cpp_loop / cblk_loop から JSR される前提)
; -----------------------------------------------------------------------------
cmp_dispatch_stmt:
    LDA CMP_TOK_KIND
    CMP #TK_ECHO
    BNE :+
    JMP cpp_echo
:
    CMP #TK_CV
    BNE :+
    JMP cpp_assign_stmt
:
    CMP #TK_IDENT
    BNE :+
    JMP cpp_call_stmt
:
    CMP #TK_WHILE
    BNE :+
    JMP cpp_while_stmt
:
    CMP #TK_IF
    BNE :+
    JMP cpp_if_stmt
:
    CMP #TK_FOR
    BNE :+
    JMP cpp_for_stmt
:
    CMP #TK_INC
    BNE :+
    JMP cpp_pre_inc_stmt
:
    CMP #TK_DEC
    BNE :+
    JMP cpp_pre_dec_stmt
:
    JMP cmp_error

; -----------------------------------------------------------------------------
; echo expr ';'
; -----------------------------------------------------------------------------
cpp_echo:
    JSR cmp_lex_next
    JSR cmp_parse_expr
    LDA #ZEND_ECHO
    JSR cmp_emit_op_expr1
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    RTS

; -----------------------------------------------------------------------------
; CV '=' expr ';'
; -----------------------------------------------------------------------------
cpp_assign_stmt:
    JSR cmp_cv_intern
    STA CMP_ASSIGN_SLOT
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_ASSIGN
    BEQ cas_eq
    CMP #TK_INC
    BEQ cas_post_inc
    CMP #TK_DEC
    BEQ cas_post_dec
    CMP #TK_LBRACKET
    BNE :+
    JMP cas_dim
:
    JMP cmp_error
cas_eq:
    JSR cmp_lex_next
    JSR cmp_parse_expr
    JSR cmp_emit_assign
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    RTS
cas_post_inc:
    LDA #ZEND_POST_INC
    JMP cas_incdec_stmt
cas_post_dec:
    LDA #ZEND_POST_DEC
    JMP cas_incdec_stmt

; $a[idx] = v;  または  $a[] = v;
; CMP_ASSIGN_SLOT = CV slot (array)、CMP_TOK_KIND = '[' (まだ consume してない)
cas_dim:
    JSR cmp_lex_next                 ; '[' を consume、index の先頭 token か ']' を peek
    LDA CMP_TOK_KIND
    CMP #TK_RBRACKET
    BEQ cas_dim_append               ; $a[] = v → append モード
    ; index expr を parse
    JSR cmp_parse_expr               ; CMP_EXPR = index、CMP_TOK = ']'
    LDA CMP_TOK_KIND
    CMP #TK_RBRACKET
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next                 ; ']' を consume、次は '=' 期待
    LDA CMP_TOK_KIND
    CMP #TK_ASSIGN
    BEQ :+
    JMP cmp_error
:
    ; --- ASSIGN_DIM emit (index mode) ---
    JSR cmp_op24_zero
    ; op1 = CV array
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
    ; op2 = index (from CMP_EXPR)
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_ASSIGN_DIM
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    JMP cas_dim_emit_value

cas_dim_append:
    JSR cmp_lex_next                 ; ']' を consume、次は '=' 期待
    LDA CMP_TOK_KIND
    CMP #TK_ASSIGN
    BEQ :+
    JMP cmp_error
:
    ; --- ASSIGN_DIM emit (append、op2_type = IS_UNUSED) ---
    JSR cmp_op24_zero
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
    ; op2_type is IS_UNUSED (zero from op24_zero)
    LDY #20
    LDA #ZEND_ASSIGN_DIM
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish

cas_dim_emit_value:
    ; value expr を parse
    JSR cmp_lex_next                 ; '=' を consume、value の先頭 token を peek
    JSR cmp_parse_expr               ; CMP_EXPR = value、CMP_TOK = ';'
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    ; --- OP_DATA emit (op1 = value) ---
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
    LDA #ZEND_OP_DATA
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cas_incdec_stmt:
    STA TMP2
    ; CMP_ASSIGN_SLOT を CMP_INCDEC_SLOT にコピー
    LDA CMP_ASSIGN_SLOT
    STA CMP_INCDEC_SLOT
    LDA TMP2
    JSR cmp_emit_incdec_discard
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    RTS

; ++$x; / --$x; (stmt-level prefix inc/dec、結果破棄)
cpp_pre_inc_stmt:
    LDA #ZEND_PRE_INC
    JMP cpp_pre_incdec_stmt
cpp_pre_dec_stmt:
    LDA #ZEND_PRE_DEC
cpp_pre_incdec_stmt:
    STA TMP2
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_CV
    BEQ :+
    JMP cmp_error
:
    JSR cmp_cv_intern
    STA CMP_INCDEC_SLOT
    LDA TMP2
    JSR cmp_emit_incdec_discard
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    RTS

; -----------------------------------------------------------------------------
; IDENT '(' args? ')' ';'  (intrinsic call as statement, 戻り値破棄)
; -----------------------------------------------------------------------------
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
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ ccs_rparen
ccs_args:
    JSR cmp_parse_arg
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ ccs_rparen
    CMP #TK_COMMA
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next
    JMP ccs_args
ccs_rparen:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    JSR cmp_emit_intrinsic
    RTS

; -----------------------------------------------------------------------------
; while '(' expr ')' '{' stmt* '}'
;
; 生成コード:
;   loop_top:
;     JMPZ cond, loop_end  ; placeholder, backpatch
;     body...
;     JMP loop_top
;   loop_end:
; -----------------------------------------------------------------------------
cpp_while_stmt:
    LDA CMP_OP_COUNT
    PHA
    LDA CMP_OP_COUNT+1
    PHA

    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next
    JSR cmp_parse_expr
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ :+
    JMP cmp_error
:
    LDA #ZEND_JMPZ
    JSR cmp_emit_jmpxx_with_bp

    ; body: ブロック or 単文
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LBRACE
    BNE cpw_single
    JSR cmp_parse_block_body
    JMP cpw_after_body
cpw_single:
    JSR cmp_dispatch_stmt
cpw_after_body:

    ; JMP loop_top
    JSR cmp_op24_zero
    PLA
    STA TMP0+1
    PLA
    STA TMP0
    LDY #0
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_JMP
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish

    JSR cmp_bp_pop_patch
    RTS

; -----------------------------------------------------------------------------
; if '(' expr ')' '{' stmt* '}'   (else 未対応)
;
; 生成コード:
;   JMPZ cond, if_end  ; placeholder
;   body...
;   if_end:
; -----------------------------------------------------------------------------
cpp_if_stmt:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next
    JSR cmp_parse_expr
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ :+
    JMP cmp_error
:
    LDA #ZEND_JMPZ
    JSR cmp_emit_jmpxx_with_bp

    ; body: ブロック or 単文
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LBRACE
    BNE cpif_single
    JSR cmp_parse_block_body
    JMP cpif_patch
cpif_single:
    JSR cmp_dispatch_stmt
cpif_patch:
    JSR cmp_bp_pop_patch
    RTS

; -----------------------------------------------------------------------------
; cmp_parse_block_body: '{' は既に消費済、'}' まで stmt* を処理
; -----------------------------------------------------------------------------
cmp_parse_block_body:
cblk_loop:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_RBRACE
    BEQ cblk_done
    CMP #TK_EOF
    BNE :+
    JMP cmp_error
:
    JSR cmp_dispatch_stmt
    JMP cblk_loop
cblk_done:
    RTS

; -----------------------------------------------------------------------------
; for (init; cond; update) body
;
; 生成コード (update が body より前 にソースに出る都合で double-JMP):
;   init
;   L0 (loop_top):
;     cond
;     JMPZ cond, END          (bp1)
;     JMP body-start          (bp2)
;     update-start:
;     update
;     JMP L0
;   body-start:               (patch bp2)
;     body
;     JMP update-start
;   END:                      (patch bp1)
;
; 外側 for のために CMP_FOR_LOOP_TOP / CMP_FOR_UPD_START を HW stack に退避
; -----------------------------------------------------------------------------
cpp_for_stmt:
    LDA CMP_FOR_LOOP_TOP
    PHA
    LDA CMP_FOR_LOOP_TOP+1
    PHA
    LDA CMP_FOR_UPD_START
    PHA
    LDA CMP_FOR_UPD_START+1
    PHA

    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    ; --- init ---
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ cfs_init_skip
    JSR cmp_dispatch_stmt
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
cfs_init_skip:

    ; loop_top を記録
    LDA CMP_OP_COUNT
    STA CMP_FOR_LOOP_TOP
    LDA CMP_OP_COUNT+1
    STA CMP_FOR_LOOP_TOP+1

    ; --- cond ---
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ cfs_cond_true
    JSR cmp_parse_expr
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BEQ :+
    JMP cmp_error
:
    JMP cfs_cond_emit
cfs_cond_true:
    ; 空の cond → IS_TRUE を使う
    JSR cmp_emit_zval_true
    LDX TMP1
    JSR cmp_lit_idx_to_offset
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_CONST
    STA CMP_EXPR_TYPE
cfs_cond_emit:
    LDA #ZEND_JMPZ
    JSR cmp_emit_jmpxx_with_bp       ; bp1: END
    JSR cmp_emit_jmp_with_bp         ; bp2: body-start

    ; update_start を記録
    LDA CMP_OP_COUNT
    STA CMP_FOR_UPD_START
    LDA CMP_OP_COUNT+1
    STA CMP_FOR_UPD_START+1

    ; --- update ---
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ cfs_update_skip
    JSR cmp_parse_expr
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ :+
    JMP cmp_error
:
cfs_update_skip:

    ; JMP loop_top
    JSR cmp_op24_zero
    LDY #0
    LDA CMP_FOR_LOOP_TOP
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_FOR_LOOP_TOP+1
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_JMP
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish

    ; Patch bp2 (body-start = 現在の OP_COUNT)
    JSR cmp_bp_pop_patch

    ; --- body ---
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LBRACE
    BNE cfs_body_single
    JSR cmp_parse_block_body
    JMP cfs_body_done
cfs_body_single:
    JSR cmp_dispatch_stmt
cfs_body_done:

    ; JMP update_start
    JSR cmp_op24_zero
    LDY #0
    LDA CMP_FOR_UPD_START
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_FOR_UPD_START+1
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_JMP
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish

    ; Patch bp1 (END = 現在の OP_COUNT)
    JSR cmp_bp_pop_patch

    ; 外側 for 状態を復帰
    PLA
    STA CMP_FOR_UPD_START+1
    PLA
    STA CMP_FOR_UPD_START
    PLA
    STA CMP_FOR_LOOP_TOP+1
    PLA
    STA CMP_FOR_LOOP_TOP
    RTS

; cmp_emit_jmp_with_bp: 無条件 JMP を placeholder 0 で emit、op1 アドレスを bp stack に push
cmp_emit_jmp_with_bp:
    JSR cmp_op24_zero
    LDY #20
    LDA #ZEND_JMP
    STA (CMP_OP_HEAD), Y
    LDA CMP_OP_HEAD
    STA TMP0
    LDA CMP_OP_HEAD+1
    STA TMP0+1
    JSR cmp_bp_push
    JSR cmp_op_finish
    RTS

; =============================================================================
; error display + halt
; =============================================================================
cmp_error:
    JSR show_compile_error
cmp_error_halt:
    JMP cmp_error_halt

show_compile_error:
    BIT PPUSTATUS
    LDA #$21
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
sce_wl:
    CPX pi_count
    BEQ sce_ldone
    LDA INT_PRINT_BUFFER, X
    STA PPUDATA
    INX
    JMP sce_wl
sce_ldone:
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
sce_wc:
    CPX pi_count
    BEQ sce_cdone
    LDA INT_PRINT_BUFFER, X
    STA PPUDATA
    INX
    JMP sce_wc
sce_cdone:
    BIT PPUSTATUS
    LDA #0
    STA PPUSCROLL
    STA PPUSCROLL
    LDA #%00001010
    STA PPUMASK
    RTS

; =============================================================================
; backpatch stack (CMP_BP_STACK は 16B = 8 エントリ × 2B の patch 対象アドレス)
; =============================================================================
; cmp_bp_push: TMP0 = patch 対象アドレス → stack
cmp_bp_push:
    LDX CMP_BP_TOP
    CPX #8
    BCC :+
    JMP cmp_error
:
    TXA
    ASL A
    TAY
    LDA TMP0
    STA CMP_BP_STACK, Y
    INY
    LDA TMP0+1
    STA CMP_BP_STACK, Y
    INC CMP_BP_TOP
    RTS

; cmp_bp_pop_patch: stack トップを pop し、そのアドレスに CMP_OP_COUNT を 16bit 書く
cmp_bp_pop_patch:
    LDA CMP_BP_TOP
    BNE :+
    JMP cmp_error
:
    DEC CMP_BP_TOP
    LDX CMP_BP_TOP
    TXA
    ASL A
    TAY
    LDA CMP_BP_STACK, Y
    STA TMP0
    INY
    LDA CMP_BP_STACK, Y
    STA TMP0+1
    LDY #0
    LDA CMP_OP_COUNT
    STA (TMP0), Y
    INY
    LDA CMP_OP_COUNT+1
    STA (TMP0), Y
    RTS

; =============================================================================
; parse_arg (function call)
; =============================================================================
cmp_parse_arg:
    LDA CMP_TOK_KIND
    CMP #TK_IDENT
    BNE cpa_expr
    JMP cpa_stdin_or_call

cpa_stdin_or_call:
    ; "STDIN" なら sentinel、それ以外は IDENT が fgets 式かもしれないので expr へ
    LDA CMP_TOK_LEN
    CMP #5
    BNE cpa_expr
    LDY #0
    LDA (CMP_TOK_PTR), Y
    CMP #'S'
    BNE cpa_expr
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'T'
    BNE cpa_expr
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'D'
    BNE cpa_expr
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'I'
    BNE cpa_expr
    INY
    LDA (CMP_TOK_PTR), Y
    CMP #'N'
    BNE cpa_expr
    ; STDIN 確定
    LDX CMP_ARG_COUNT
    CPX #4
    BCC :+
    JMP cmp_error
:
    LDA #ARG_STDIN_SENTINEL
    STA CMP_ARG_TYPES, X
    INC CMP_ARG_COUNT
    JSR cmp_lex_next
    RTS

cpa_expr:
    JSR cmp_parse_expr
    LDX CMP_ARG_COUNT
    CPX #4
    BCC :+
    JMP cmp_error
:
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
; parse_expr: 式のトップレベル、logic_expr = cmp_expr (&&|||cmp_expr)*
; parse_cmp_expr: add_expr (cmp_op add_expr)?
; parse_add_expr: primary (+/-/&/|/<</>> primary)*
; parse_primary: INT | STRING | CV | TRUE | fgets(...) | nes_btn() | ++/-- etc.
; =============================================================================
cmp_parse_expr:
    JSR cmp_parse_cmp_expr
cle_loop:
    LDA CMP_TOK_KIND
    CMP #TK_AMPAMP
    BNE :+
    JMP cle_andand
:
    CMP #TK_PIPEPIPE
    BNE :+
    JMP cle_oror
:
    RTS

; --- && 短絡評価 (両 operand truthy なら 1、一つでも falsy なら 0) ---
cle_andand:
    JSR cmp_reserve_logic_slot
    LDA #ZEND_JMPZ
    JSR cmp_emit_jmpxx_with_bp       ; bp1: a → L_false
    JSR cmp_lex_next                 ; consume '&&'
    JSR cmp_parse_cmp_expr           ; RHS
    LDA #ZEND_JMPZ
    JSR cmp_emit_jmpxx_with_bp       ; bp2: b → L_false
    LDA #1
    JSR cmp_emit_qm_assign_const_slot ; slot = 1
    JSR cmp_emit_jmp_save_done        ; JMP → L_done
    JSR cmp_bp_pop_patch             ; bp2 → current (L_false)
    JSR cmp_bp_pop_patch             ; bp1 → current
    LDA #0
    JSR cmp_emit_qm_assign_const_slot ; slot = 0
    JSR cmp_patch_logic_done          ; L_done
    JSR cmp_expr_set_to_logic_slot
    JMP cle_loop

; --- || 短絡評価 (どちらか truthy なら 1、両 falsy なら 0) ---
cle_oror:
    JSR cmp_reserve_logic_slot
    LDA #ZEND_JMPNZ
    JSR cmp_emit_jmpxx_with_bp       ; bp1: a → L_true
    JSR cmp_lex_next
    JSR cmp_parse_cmp_expr
    LDA #ZEND_JMPNZ
    JSR cmp_emit_jmpxx_with_bp       ; bp2: b → L_true
    LDA #0
    JSR cmp_emit_qm_assign_const_slot ; slot = 0 (両 falsy)
    JSR cmp_emit_jmp_save_done
    JSR cmp_bp_pop_patch
    JSR cmp_bp_pop_patch
    LDA #1
    JSR cmp_emit_qm_assign_const_slot
    JSR cmp_patch_logic_done
    JSR cmp_expr_set_to_logic_slot
    JMP cle_loop

; --- 共通ヘルパー ---
cmp_reserve_logic_slot:
    LDA CMP_TMP_COUNT
    STA CMP_LOGIC_SLOT
    CMP #64
    BCC :+
    JMP cmp_error
:
    INC CMP_TMP_COUNT
    RTS

cmp_emit_jmp_save_done:
    JSR cmp_op24_zero
    LDY #20
    LDA #ZEND_JMP
    STA (CMP_OP_HEAD), Y
    LDA CMP_OP_HEAD
    STA CMP_LOGIC_DONE
    LDA CMP_OP_HEAD+1
    STA CMP_LOGIC_DONE+1
    JSR cmp_op_finish
    RTS

cmp_patch_logic_done:
    LDA CMP_LOGIC_DONE
    STA TMP0
    LDA CMP_LOGIC_DONE+1
    STA TMP0+1
    LDY #0
    LDA CMP_OP_COUNT
    STA (TMP0), Y
    INY
    LDA CMP_OP_COUNT+1
    STA (TMP0), Y
    RTS

; QM_ASSIGN literal(A) → CMP_LOGIC_SLOT (IS_TMP_VAR)
cmp_emit_qm_assign_const_slot:
    STA CMP_TOK_VALUE
    LDA #0
    STA CMP_TOK_VALUE+1
    JSR cmp_emit_zval_long_value     ; TMP1 = lit_idx
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
    LDX CMP_LOGIC_SLOT
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
    LDY #20
    LDA #ZEND_QM_ASSIGN
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

cmp_expr_set_to_logic_slot:
    LDX CMP_LOGIC_SLOT
    JSR cmp_lit_idx_to_offset
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    RTS

; --- 旧 cmp_parse_expr の本体を cmp_parse_cmp_expr にリネーム ---
cmp_parse_cmp_expr:
    JSR cmp_parse_add_expr
    LDA CMP_TOK_KIND
    CMP #TK_EQ3
    BNE :+
    LDA #ZEND_IS_IDENTICAL
    JMP cpe_cmp
:
    CMP #TK_NEQ3
    BNE :+
    LDA #ZEND_IS_NOT_IDENTICAL
    JMP cpe_cmp
:
    CMP #TK_EQ2
    BNE :+
    LDA #ZEND_IS_EQUAL
    JMP cpe_cmp
:
    CMP #TK_NEQ2
    BNE :+
    LDA #ZEND_IS_NOT_EQUAL
    JMP cpe_cmp
:
    CMP #TK_LT
    BNE :+
    LDA #ZEND_IS_SMALLER
    JMP cpe_cmp
:
    RTS                          ; no cmp, return

cpe_cmp:
    STA CMP_INTRINSIC_ID         ; 流用: opcode 保存
    LDA CMP_EXPR_TYPE
    STA CMP_LHS_TYPE
    LDA CMP_EXPR_VAL
    STA CMP_LHS_VAL
    LDA CMP_EXPR_VAL+1
    STA CMP_LHS_VAL+1
    JSR cmp_lex_next
    JSR cmp_parse_add_expr
    JSR cmp_emit_binary          ; 比較は二項演算と同じ形式 (result=TMP)
    RTS

cmp_parse_add_expr:
    JSR cmp_parse_primary
cpa_loop:
    LDA CMP_TOK_KIND
    CMP #TK_PLUS
    BNE :+
    LDA #ZEND_ADD
    JMP cpa_binop
:
    CMP #TK_MINUS
    BNE :+
    LDA #ZEND_SUB
    JMP cpa_binop
:
    CMP #TK_AMP
    BNE :+
    LDA #ZEND_BW_AND
    JMP cpa_binop
:
    CMP #TK_PIPE
    BNE :+
    LDA #ZEND_BW_OR
    JMP cpa_binop
:
    CMP #TK_SL
    BNE :+
    LDA #ZEND_SL
    JMP cpa_binop
:
    CMP #TK_SR
    BNE cpa_done
    LDA #ZEND_SR
cpa_binop:
    STA CMP_INTRINSIC_ID
    LDA CMP_EXPR_TYPE
    STA CMP_LHS_TYPE
    LDA CMP_EXPR_VAL
    STA CMP_LHS_VAL
    LDA CMP_EXPR_VAL+1
    STA CMP_LHS_VAL+1
    JSR cmp_lex_next
    JSR cmp_parse_primary
    JSR cmp_emit_binary
    JMP cpa_loop
cpa_done:
    RTS

cmp_parse_primary:
    LDA CMP_TOK_KIND
    CMP #TK_INT
    BNE :+
    JMP cpp_int
:
    CMP #TK_STRING
    BNE :+
    JMP cpp_str
:
    CMP #TK_CV
    BNE :+
    JMP cpp_cv
:
    CMP #TK_TRUE
    BNE :+
    JMP cpp_true
:
    CMP #TK_IDENT
    BNE :+
    JMP cpp_ident
:
    CMP #TK_INC
    BNE :+
    JMP cpp_pre_inc_expr
:
    CMP #TK_DEC
    BNE :+
    JMP cpp_pre_dec_expr
:
    CMP #TK_LBRACKET
    BNE :+
    JMP cpp_array_literal
:
    JMP cmp_error

; ++$x (prefix in expression) → PRE_INC with TMP result
cpp_pre_inc_expr:
    LDA #ZEND_PRE_INC
    JMP cpp_pre_incdec_expr
cpp_pre_dec_expr:
    LDA #ZEND_PRE_DEC
cpp_pre_incdec_expr:
    STA TMP2                        ; opcode 退避
    JSR cmp_lex_next                ; TK_CV を期待
    LDA CMP_TOK_KIND
    CMP #TK_CV
    BEQ :+
    JMP cmp_error
:
    JSR cmp_cv_intern
    STA CMP_INCDEC_SLOT
    LDA TMP2
    JSR cmp_emit_incdec_tmp
    JSR cmp_lex_next                ; peek next
    RTS

cpp_int:
    JSR cmp_emit_zval_long_value
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
    STA CMP_INCDEC_SLOT             ; postfix ++/-- で再利用する可能性がある
    TAX
    JSR cmp_lit_idx_to_offset
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_CV
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next                ; peek next
    LDA CMP_TOK_KIND
    CMP #TK_INC
    BNE :+
    JMP cpp_cv_post_inc
:
    CMP #TK_DEC
    BNE :+
    JMP cpp_cv_post_dec
:
    CMP #TK_LBRACKET
    BEQ cpp_cv_fetch_dim
    RTS                              ; just CV、terminator は CMP_TOK_KIND に残る

; $cv [ idx ] [ idx ] ... → チェーンで FETCH_DIM_R を繰り返し emit
cpp_cv_fetch_dim:
cdf_loop:
    ; CMP_EXPR (CV または前回の TMP) を LHS に退避
    LDA CMP_EXPR_VAL
    STA CMP_LHS_VAL
    LDA CMP_EXPR_VAL+1
    STA CMP_LHS_VAL+1
    LDA CMP_EXPR_TYPE
    STA CMP_LHS_TYPE
    JSR cmp_lex_next                 ; '[' を consume、index 先頭 token を peek
    JSR cmp_parse_expr               ; index → CMP_EXPR、終了時 CMP_TOK = ']'
    LDA CMP_TOK_KIND
    CMP #TK_RBRACKET
    BEQ :+
    JMP cmp_error
:
    ; --- FETCH_DIM_R emit ---
    JSR cmp_op24_zero
    LDY #0
    LDA CMP_LHS_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_LHS_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA CMP_LHS_TYPE
    STA (CMP_OP_HEAD), Y
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
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
    LDY #20
    LDA #ZEND_FETCH_DIM_R
    STA (CMP_OP_HEAD), Y
    INC CMP_TMP_COUNT
    JSR cmp_op_finish
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next                 ; ']' を consume、次 token を peek
    LDA CMP_TOK_KIND
    CMP #TK_LBRACKET
    BEQ cdf_loop                     ; 次も [ ならチェーン
    RTS

cpp_cv_post_inc:
    LDA #ZEND_POST_INC
    JMP cpp_cv_post_common
cpp_cv_post_dec:
    LDA #ZEND_POST_DEC
cpp_cv_post_common:
    JSR cmp_emit_incdec_tmp         ; CMP_INCDEC_SLOT の CV を inc/dec、CMP_EXPR = TMP (旧値)
    JSR cmp_lex_next                ; ++/-- の次の token
    RTS

; '[' expr (',' expr)* ']' → 配列リテラル
;   INIT_ARRAY (op1 = capacity、result = 新 TMP) を先に emit し、
;   op1 の位置を CMP_ARR_PATCH に覚えて backpatch する。
;   各要素は ADD_ARRAY_ELEMENT (op1 = array TMP, op2 = element expr) を emit。
;   終了時に要素数を backpatch。CMP_EXPR = array TMP (IS_TMP_VAR)。
;   ネスト可 ([[...],[...]]): 入口で CMP_ARR_* を stack に退避、出口で復元。
;   空配列 [] 可 (cap=0)。
cpp_array_literal:
    ; 現在の配列 parse 状態を stack に退避 (ネスト対応)
    LDA CMP_ARR_TMP
    PHA
    LDA CMP_ARR_TMP+1
    PHA
    LDA CMP_ARR_PATCH
    PHA
    LDA CMP_ARR_PATCH+1
    PHA
    LDA CMP_ARR_COUNT
    PHA
    JSR cmp_lex_next                ; '[' を consume、先頭 token を peek
    ; --- INIT_ARRAY emit ---
    JSR cmp_op24_zero
    ; backpatch 位置 = 現 CMP_OP_HEAD (op の先頭)
    LDA CMP_OP_HEAD
    STA CMP_ARR_PATCH
    LDA CMP_OP_HEAD+1
    STA CMP_ARR_PATCH+1
    ; result = 新 TMP
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
:
    JSR cmp_lit_idx_to_offset        ; TMP0 = TMP idx * 4
    LDY #8
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y
    LDY #23
    LDA #IS_TMP_VAR
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_INIT_ARRAY
    STA (CMP_OP_HEAD), Y
    INC CMP_TMP_COUNT
    ; array TMP value を退避
    LDA TMP0
    STA CMP_ARR_TMP
    LDA TMP0+1
    STA CMP_ARR_TMP+1
    JSR cmp_op_finish
    ; 要素 count = 0
    LDA #0
    STA CMP_ARR_COUNT

    ; empty array 対応
    LDA CMP_TOK_KIND
    CMP #TK_RBRACKET
    BEQ cpal_end

cpal_element_loop:
    JSR cmp_parse_expr               ; 要素。終了時 CMP_TOK_KIND = ',' or ']'
    ; --- ADD_ARRAY_ELEMENT emit ---
    JSR cmp_op24_zero
    ; op1 = array TMP (IS_TMP_VAR)
    LDY #0
    LDA CMP_ARR_TMP
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_ARR_TMP+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA #IS_TMP_VAR
    STA (CMP_OP_HEAD), Y
    ; op2 = element (CMP_EXPR)
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_ADD_ARRAY_ELEMENT
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    INC CMP_ARR_COUNT
    ; 次は ',' か ']'
    LDA CMP_TOK_KIND
    CMP #TK_COMMA
    BEQ cpal_next
    CMP #TK_RBRACKET
    BEQ cpal_end
    JMP cmp_error
cpal_next:
    JSR cmp_lex_next                 ; ',' を consume、次 element token を peek
    JMP cpal_element_loop

cpal_end:
    ; backpatch: INIT_ARRAY の op1 (byte 0-1) に要素数 count を書く
    LDY #0
    LDA CMP_ARR_COUNT
    STA (CMP_ARR_PATCH), Y
    INY
    LDA #0
    STA (CMP_ARR_PATCH), Y
    ; CMP_EXPR = array TMP (この literal の結果)
    LDA CMP_ARR_TMP
    STA CMP_EXPR_VAL
    LDA CMP_ARR_TMP+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next                 ; ']' を consume
    ; 退避していた親レベルの配列 parse 状態を復元 (ネスト対応)
    PLA
    STA CMP_ARR_COUNT
    PLA
    STA CMP_ARR_PATCH+1
    PLA
    STA CMP_ARR_PATCH
    PLA
    STA CMP_ARR_TMP+1
    PLA
    STA CMP_ARR_TMP
    RTS

; true → IS_TRUE zval (literal)
cpp_true:
    JSR cmp_emit_zval_true
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

; IDENT 式 — fgets(STDIN) / nes_btn() / count($a) に対応 (戻り値 TMP)
cpp_ident:
    JSR cmp_match_intrinsic
    CMP #INT_FGETS
    BNE :+
    JMP cpp_ident_fgets
:
    CMP #INT_BTN
    BNE :+
    JMP cpp_ident_btn
:
    CMP #INT_COUNT
    BEQ cpp_ident_count
    JMP cmp_error

; count($a) 式: '(' expr ')' をパース、ZEND_COUNT op1=expr、result = 新 TMP
cpp_ident_count:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next
    JSR cmp_parse_expr               ; CMP_EXPR = array 式
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ :+
    JMP cmp_error
:
    ; --- ZEND_COUNT emit ---
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
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
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
    LDY #20
    LDA #ZEND_COUNT
    STA (CMP_OP_HEAD), Y
    INC CMP_TMP_COUNT
    JSR cmp_op_finish
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    JSR cmp_lex_next                 ; ')' を consume
    RTS

cpp_ident_btn:
    ; '(' ')' をパース (0 引数)、NESPHP_NES_BTN result=TMP を emit
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_emit_btn_tmp             ; result = 新 TMP、CMP_EXPR = TMP
    JSR cmp_lex_next                 ; peek next
    RTS

cpp_ident_fgets:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_LPAREN
    BEQ :+
    JMP cmp_error
:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_IDENT
    BEQ :+
    JMP cmp_error
:
    ; verify "STDIN"
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
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_RPAREN
    BEQ :+
    JMP cmp_error
:
    ; emit NESPHP_FGETS with result=new TMP
    JSR cmp_emit_fgets_tmp
    JSR cmp_lex_next
    RTS

cmp_emit_fgets_tmp:
    JSR cmp_op24_zero
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
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
    LDY #20
    LDA #NESPHP_FGETS
    STA (CMP_OP_HEAD), Y
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    INC CMP_TMP_COUNT
    JSR cmp_op_finish
    RTS

; cmp_emit_btn_tmp: nes_btn() (expr 文脈、0 引数)
;   NESPHP_NES_BTN を result=新 TMP で emit、CMP_EXPR を TMP に更新
;   出力: CMP_EXPR_TYPE/VAL = 新 TMP (実行時に IS_LONG(buttons bitmask) が入る)
cmp_emit_btn_tmp:
    JSR cmp_op24_zero
    ; result = 新 TMP
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
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
    LDY #20
    LDA #NESPHP_NES_BTN
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    INC CMP_TMP_COUNT
    RTS

; =============================================================================
; CV symbol table ($0700 起点、4B × 最大 32)
; =============================================================================
cmp_cv_intern:
    LDX #0
ccv_find:
    CPX CMP_CV_COUNT
    BEQ ccv_alloc
    TXA
    ASL A
    ASL A
    TAY
    LDA CMP_CV_TABLE, Y
    CMP CMP_TOK_LEN
    BNE ccv_skip
    INY
    LDA CMP_CV_TABLE, Y
    STA TMP1
    INY
    LDA CMP_CV_TABLE, Y
    STA TMP1+1
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
    CPX #32
    BCC :+
    JMP cmp_error
:
    TXA
    ASL A
    ASL A
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
    STA CMP_CV_TABLE, Y
    TXA
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
    JMP cln_eq
:
    CMP #'!'
    BNE :+
    JMP cln_bang
:
    CMP #'<'
    BNE :+
    JMP cln_lt
:
    CMP #'>'
    BNE :+
    JMP cln_gt
:
    CMP #'{'
    BNE :+
    JMP cln_lbrace
:
    CMP #'}'
    BNE :+
    JMP cln_rbrace
:
    CMP #'['
    BNE :+
    JMP cln_lbracket
:
    CMP #']'
    BNE :+
    JMP cln_rbracket
:
    CMP #'+'
    BNE :+
    JMP cln_plus
:
    CMP #'-'
    BNE :+
    JMP cln_minus
:
    CMP #'&'
    BNE :+
    JMP cln_amp
:
    CMP #'|'
    BNE :+
    JMP cln_pipe
:
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
cln_lt:
    JSR cmp_advance1                ; 最初の '<'
    JSR cmp_at_eof
    BEQ cln_lt_single
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'<'
    BNE cln_lt_single
    JSR cmp_advance1                ; '<<'
    LDA #TK_SL
    STA CMP_TOK_KIND
    RTS
cln_lt_single:
    LDA #TK_LT
    STA CMP_TOK_KIND
    RTS

; '>' 単体は比較演算として未対応 (エラー)。'>>' のみ TK_SR として emit。
cln_gt:
    JSR cmp_advance1
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'>'
    BEQ :+
    JMP cmp_error                    ; `>` 単独は未対応
:
    JSR cmp_advance1                 ; '>>'
    LDA #TK_SR
    STA CMP_TOK_KIND
    RTS
cln_lbrace:
    JSR cmp_advance1
    LDA #TK_LBRACE
    STA CMP_TOK_KIND
    RTS
cln_rbrace:
    JSR cmp_advance1
    LDA #TK_RBRACE
    STA CMP_TOK_KIND
    RTS
cln_lbracket:
    JSR cmp_advance1
    LDA #TK_LBRACKET
    STA CMP_TOK_KIND
    RTS
cln_rbracket:
    JSR cmp_advance1
    LDA #TK_RBRACKET
    STA CMP_TOK_KIND
    RTS
cln_plus:
    JSR cmp_advance1                ; 1 個目の '+'
    JSR cmp_at_eof
    BEQ cln_plus_one
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'+'
    BNE cln_plus_one
    JSR cmp_advance1                ; 2 個目の '+'
    LDA #TK_INC
    STA CMP_TOK_KIND
    RTS
cln_plus_one:
    LDA #TK_PLUS
    STA CMP_TOK_KIND
    RTS

cln_minus:
    JSR cmp_advance1                ; 1 個目の '-'
    JSR cmp_at_eof
    BEQ cln_minus_one
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'-'
    BNE cln_minus_one
    JSR cmp_advance1
    LDA #TK_DEC
    STA CMP_TOK_KIND
    RTS
cln_minus_one:
    LDA #TK_MINUS
    STA CMP_TOK_KIND
    RTS

; ビット AND `&` / 論理 AND `&&`
cln_amp:
    JSR cmp_advance1
    JSR cmp_at_eof
    BEQ cln_amp_single
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'&'
    BNE cln_amp_single
    JSR cmp_advance1
    LDA #TK_AMPAMP
    STA CMP_TOK_KIND
    RTS
cln_amp_single:
    LDA #TK_AMP
    STA CMP_TOK_KIND
    RTS

; ビット OR `|` / 論理 OR `||`
cln_pipe:
    JSR cmp_advance1
    JSR cmp_at_eof
    BEQ cln_pipe_single
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'|'
    BNE cln_pipe_single
    JSR cmp_advance1
    LDA #TK_PIPEPIPE
    STA CMP_TOK_KIND
    RTS
cln_pipe_single:
    LDA #TK_PIPE
    STA CMP_TOK_KIND
    RTS

cln_eq:
    JSR cmp_advance1                ; consume first '='
    JSR cmp_at_eof
    BEQ cln_eq_one
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'='
    BNE cln_eq_one
    JSR cmp_advance1                ; consume second '='
    JSR cmp_at_eof
    BEQ cln_eq_two
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'='
    BNE cln_eq_two
    JSR cmp_advance1                ; consume third '='
    LDA #TK_EQ3
    STA CMP_TOK_KIND
    RTS
cln_eq_two:
    LDA #TK_EQ2
    STA CMP_TOK_KIND
    RTS
cln_eq_one:
    LDA #TK_ASSIGN
    STA CMP_TOK_KIND
    RTS

cln_bang:
    JSR cmp_advance1                ; consume '!'
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'='
    BEQ :+
    JMP cmp_error
:
    JSR cmp_advance1                ; consume '='
    JSR cmp_at_eof
    BEQ cln_neq_two
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'='
    BNE cln_neq_two
    JSR cmp_advance1                ; consume third '='
    LDA #TK_NEQ3
    STA CMP_TOK_KIND
    RTS
cln_neq_two:
    LDA #TK_NEQ2
    STA CMP_TOK_KIND
    RTS

cln_cv:
    JSR cmp_advance1                ; consume '$'
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
    JMP cmp_error
:
    STX CMP_TOK_LEN
    LDA #TK_CV
    STA CMP_TOK_KIND
    RTS

; cln_string: 文字列リテラルを lex。
;   - 開始 `"` を消費
;   - 内容は常に STR_POOL_BASE 以降の pool へ bytewise に decode して書く
;     (escape なしの普通の文字もコピー)。cpp_str が zval から参照するため、
;     TOK_PTR は pool 上のこの文字列の先頭を指す。
;   - 対応エスケープ:
;       \xHH  → 1 byte (HH は hex 2 桁、大小文字 OK)
;       \\    → '\'
;       \"    → '"'
;     それ以外の `\` に続く文字は compile error
;   - pool overflow ($8000 以上) も compile error
cln_string:
    JSR cmp_advance1                ; consume opening "
    ; TOK_PTR = 現在の pool head (この文字列の先頭)
    LDA CMP_STRPOOL_HEAD
    STA CMP_TOK_PTR
    LDA CMP_STRPOOL_HEAD+1
    STA CMP_TOK_PTR+1
    LDX #0                          ; decoded byte count
cln_str_loop:
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'"'
    BEQ cln_str_end
    CMP #'\'
    BEQ cln_str_escape
    ; plain byte: write-through to pool
    JSR cln_str_pool_put            ; preserves X
    JSR cmp_advance1
    INX
    CPX #$FF
    BCC cln_str_loop
    JMP cmp_error

cln_str_escape:
    JSR cmp_advance1                ; skip '\'
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'x'
    BEQ cln_str_hex
    CMP #'X'
    BEQ cln_str_hex
    CMP #'\'
    BEQ cln_str_lit_bs
    CMP #'"'
    BEQ cln_str_lit_dq
    JMP cmp_error                   ; unknown escape

cln_str_lit_bs:
    JSR cmp_advance1
    LDA #'\'
    JSR cln_str_pool_put
    INX
    CPX #$FF
    BCC cln_str_loop
    JMP cmp_error

cln_str_lit_dq:
    JSR cmp_advance1
    LDA #'"'
    JSR cln_str_pool_put
    INX
    CPX #$FF
    BCC cln_str_loop
    JMP cmp_error

cln_str_hex:
    JSR cmp_advance1                ; skip 'x'
    JSR cln_str_read_hex2           ; A = decoded byte
    JSR cln_str_pool_put
    INX
    CPX #$FF
    BCC cln_str_loop
    JMP cmp_error

cln_str_end:
    STX CMP_TOK_LEN
    JSR cmp_advance1                ; consume closing "
    LDA #TK_STRING
    STA CMP_TOK_KIND
    RTS

; cln_str_pool_put: A を *CMP_STRPOOL_HEAD++ に書く。overflow で cmp_error。
; X は保存する (caller のカウンタ)。Y は 0 に潰す。A は clobber。
cln_str_pool_put:
    LDY #0
    STA (CMP_STRPOOL_HEAD), Y
    INC CMP_STRPOOL_HEAD
    BNE :+
    INC CMP_STRPOOL_HEAD+1
:
    LDA CMP_STRPOOL_HEAD+1
    CMP #>STR_POOL_END
    BCC :+
    JMP cmp_error                   ; pool overflow
:
    RTS

; cln_str_read_hex2: SRC_PTR 位置から 2 桁の hex を読み、A = decoded byte にして
; SRC_PTR を 2 進める。失敗で cmp_error。X は保存する。
; ハイニブルをスタックに退避してヘルパー間で TMP を汚染しない。
cln_str_read_hex2:
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    JSR hex_digit
    BCC :+
    JMP cmp_error
:
    ASL A
    ASL A
    ASL A
    ASL A
    PHA                             ; save high nibble
    JSR cmp_advance1
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error_pop1
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    JSR hex_digit
    BCC :+
    JMP cmp_error_pop1
:
    STA CMP_TOK_VALUE               ; 一時置場 (STRING token 中 TK_INT の value 枠は未使用)
    PLA
    ORA CMP_TOK_VALUE
    PHA
    JSR cmp_advance1
    PLA
    RTS

; stack を 1 調整してから cmp_error へ飛ぶ補助 (中断時の leak 回避)
cmp_error_pop1:
    PLA
    JMP cmp_error

cln_int:
    LDA #0
    STA CMP_TOK_VALUE
    STA CMP_TOK_VALUE+1
    ; 先頭 '0' の後が 'x' / 'X' なら hex、'b' / 'B' なら binary に分岐
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'0'
    BNE cln_int_loop              ; '0' 以外で始まる場合は 10 進のみ
    ; peek next
    LDY #1
    LDA (CMP_SRC_PTR), Y
    CMP #'x'
    BEQ cln_hex_consume_prefix
    CMP #'X'
    BEQ cln_hex_consume_prefix
    CMP #'b'
    BNE :+
    JMP cln_bin_consume_prefix
:
    CMP #'B'
    BNE :+
    JMP cln_bin_consume_prefix
:
    ; 10 進で続行
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

; --- 16 進リテラル: 先頭 '0x' または '0X' を消費してから hex 桁を解析 ---
cln_hex_consume_prefix:
    JSR cmp_advance1              ; '0'
    JSR cmp_advance1              ; 'x' / 'X'
    ; 少なくとも 1 桁必須
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    JSR hex_digit
    BCC :+
    JMP cmp_error                 ; 無効な hex 桁
:
cln_hex_loop:
    JSR cmp_at_eof
    BEQ cln_int_done
    LDY #0
    LDA (CMP_SRC_PTR), Y
    JSR hex_digit                 ; A = digit value (0-15), C=0 成功 / C=1 失敗
    BCC :+
    JMP cln_int_done_hex          ; 非 hex 文字で終了
:
    PHA
    ; value <<= 4 (16 倍)
    ASL CMP_TOK_VALUE
    ROL CMP_TOK_VALUE+1
    ASL CMP_TOK_VALUE
    ROL CMP_TOK_VALUE+1
    ASL CMP_TOK_VALUE
    ROL CMP_TOK_VALUE+1
    ASL CMP_TOK_VALUE
    ROL CMP_TOK_VALUE+1
    ; + digit
    PLA
    CLC
    ADC CMP_TOK_VALUE
    STA CMP_TOK_VALUE
    LDA CMP_TOK_VALUE+1
    ADC #0
    STA CMP_TOK_VALUE+1
    JSR cmp_advance1
    JMP cln_hex_loop
cln_int_done_hex:
    LDA #TK_INT
    STA CMP_TOK_KIND
    RTS

; hex_digit: A = char → A = digit value (0-15), C=0 成功 / C=1 失敗
hex_digit:
    CMP #'0'
    BCC hd_no
    CMP #'9'+1
    BCS hd_alpha
    SEC
    SBC #'0'
    CLC
    RTS
hd_alpha:
    CMP #'A'
    BCC hd_no
    CMP #'F'+1
    BCS hd_lower
    SEC
    SBC #'A'-10
    CLC
    RTS
hd_lower:
    CMP #'a'
    BCC hd_no
    CMP #'f'+1
    BCS hd_no
    SEC
    SBC #'a'-10
    CLC
    RTS
hd_no:
    SEC
    RTS

; --- 2 進リテラル: 先頭 '0b' / '0B' を消費してから '0' / '1' を解析 ---
cln_bin_consume_prefix:
    JSR cmp_advance1              ; '0'
    JSR cmp_advance1              ; 'b' / 'B'
    ; 少なくとも 1 桁必須
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'0'
    BCC cln_bin_err
    CMP #'2'
    BCS cln_bin_err
cln_bin_loop:
    JSR cmp_at_eof
    BEQ cln_int_done_bin
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'0'
    BCC cln_int_done_bin
    CMP #'2'
    BCS cln_int_done_bin
    SEC
    SBC #'0'                      ; A = 0 または 1
    PHA
    ; value <<= 1 (16bit)
    ASL CMP_TOK_VALUE
    ROL CMP_TOK_VALUE+1
    PLA
    ORA CMP_TOK_VALUE
    STA CMP_TOK_VALUE
    JSR cmp_advance1
    JMP cln_bin_loop
cln_int_done_bin:
    LDA #TK_INT
    STA CMP_TOK_KIND
    RTS
cln_bin_err:
    JMP cmp_error

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
    ; keyword 判定
    JSR cmp_check_keyword
    STA CMP_TOK_KIND
    RTS

; cmp_check_keyword: CMP_TOK_PTR/LEN を keyword 表と比較、該当 TK_* を A に
cmp_check_keyword:
    LDA #<kw_echo
    LDX #>kw_echo
    LDY #4
    JSR cmi_try_match
    BCS :+
    LDA #TK_ECHO
    RTS
:
    LDA #<kw_while
    LDX #>kw_while
    LDY #5
    JSR cmi_try_match
    BCS :+
    LDA #TK_WHILE
    RTS
:
    LDA #<kw_if
    LDX #>kw_if
    LDY #2
    JSR cmi_try_match
    BCS :+
    LDA #TK_IF
    RTS
:
    LDA #<kw_true
    LDX #>kw_true
    LDY #4
    JSR cmi_try_match
    BCS :+
    LDA #TK_TRUE
    RTS
:
    LDA #<kw_for
    LDX #>kw_for
    LDY #3
    JSR cmi_try_match
    BCS :+
    LDA #TK_FOR
    RTS
:
    LDA #TK_IDENT
    RTS

kw_echo:  .byte "echo"
kw_while: .byte "while"
kw_if:    .byte "if"
kw_true:  .byte "true"
kw_for:   .byte "for"

; -----------------------------------------------------------------------------
; char classification
; -----------------------------------------------------------------------------
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
; position helpers (line/col 追跡あり)
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; cmp_skip_ws: 空白・タブ・改行・コメント (// / # / /* */) を skip
;   空白類の後にコメントが続く場合も透過的に読み飛ばす
;   block コメントが未閉のまま EOF に達したら compile error
; -----------------------------------------------------------------------------
cmp_skip_ws:
csw_loop:
    JSR cmp_at_eof
    BNE :+
    JMP csw_done
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #' '
    BEQ csw_space
    CMP #9
    BEQ csw_space
    CMP #10
    BEQ csw_space
    CMP #13
    BEQ csw_space
    CMP #'#'
    BEQ csw_line
    CMP #'/'
    BEQ csw_maybe_comment
    RTS
csw_space:
    JSR cmp_advance1
    JMP csw_loop

csw_maybe_comment:
    LDY #1
    LDA (CMP_SRC_PTR), Y         ; 末尾パディングは 0、つまり非マッチで安全
    CMP #'/'
    BEQ csw_line_slash
    CMP #'*'
    BEQ csw_block
    RTS                          ; '/' 単独 (非コメント) → 呼び出し側へ、そこで error

csw_line_slash:
    JSR cmp_advance1             ; 最初の '/'
    JSR cmp_advance1             ; 2 個目の '/'
    JMP csw_line_body

csw_line:
    JSR cmp_advance1             ; '#' を消費
csw_line_body:
    JSR cmp_at_eof
    BNE :+
    JMP csw_done                 ; EOF に到達した
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #10                      ; LF
    BEQ csw_line_end
    JSR cmp_advance1
    JMP csw_line_body
csw_line_end:
    JSR cmp_advance1             ; LF 消費 (line/col も更新される)
    JMP csw_loop

csw_block:
    JSR cmp_advance1             ; '/' 消費
    JSR cmp_advance1             ; '*' 消費
csw_block_body:
    JSR cmp_at_eof
    BNE :+
    JMP cmp_error                ; 未閉の block コメント
:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'*'
    BNE csw_block_adv
    LDY #1
    LDA (CMP_SRC_PTR), Y
    CMP #'/'
    BEQ csw_block_end
csw_block_adv:
    JSR cmp_advance1
    JMP csw_block_body
csw_block_end:
    JSR cmp_advance1             ; '*' 消費
    JSR cmp_advance1             ; '/' 消費
    JMP csw_loop

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

cmp_advance1:
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #10
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
    LDA #<intrinsic_name_nes_put
    LDX #>intrinsic_name_nes_put
    LDY #7
    JSR cmi_try_match
    BCS :+
    LDA #INT_PUT
    RTS
:
    LDA #<intrinsic_name_nes_sprite_attr
    LDX #>intrinsic_name_nes_sprite_attr
    LDY #15
    JSR cmi_try_match
    BCS :+
    LDA #INT_SPRITE_ATTR
    RTS
:
    LDA #<intrinsic_name_nes_sprite_at
    LDX #>intrinsic_name_nes_sprite_at
    LDY #13
    JSR cmi_try_match
    BCS :+
    LDA #INT_SPRITE_AT
    RTS
:
    LDA #<intrinsic_name_nes_attr
    LDX #>intrinsic_name_nes_attr
    LDY #8
    JSR cmi_try_match
    BCS :+
    LDA #INT_ATTR
    RTS
:
    LDA #<intrinsic_name_nes_vsync
    LDX #>intrinsic_name_nes_vsync
    LDY #9
    JSR cmi_try_match
    BCS :+
    LDA #INT_VSYNC
    RTS
:
    LDA #<intrinsic_name_nes_btn
    LDX #>intrinsic_name_nes_btn
    LDY #7
    JSR cmi_try_match
    BCS :+
    LDA #INT_BTN
    RTS
:
    LDA #<intrinsic_name_count
    LDX #>intrinsic_name_count
    LDY #5
    JSR cmi_try_match
    BCS :+
    LDA #INT_COUNT
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
intrinsic_name_nes_put:       .byte "nes_put"
intrinsic_name_nes_sprite_at:   .byte "nes_sprite_at"
intrinsic_name_nes_sprite_attr: .byte "nes_sprite_attr"
intrinsic_name_nes_attr:      .byte "nes_attr"
intrinsic_name_nes_vsync:     .byte "nes_vsync"
intrinsic_name_nes_btn:       .byte "nes_btn"
intrinsic_name_count:         .byte "count"

; =============================================================================
; intrinsic 発行 (statement context、戻り値破棄)
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
    .word cmp_emit_fgets_stmt
    .word cmp_emit_put
    .word cmp_emit_sprite_at        ; INT_SPRITE_AT (8)
    .word cmp_emit_attr
    .word cmp_emit_vsync
    .word cmp_emit_btn_stmt
    .word cmp_emit_count_stmt
    .word cmp_emit_sprite_attr      ; INT_SPRITE_ATTR (13)

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

cmp_emit_fgets_stmt:
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
    LDY #20
    LDA #NESPHP_FGETS
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; nes_put($x, $y, "X" | tile_int)
; op1 = $x, op2 = $y, extended_value = char/tile literal (IS_CONST)
cmp_emit_put:
    LDA CMP_ARG_COUNT
    CMP #3
    BEQ :+
    JMP cmp_error
:
    LDA CMP_ARG_TYPES+2
    CMP #IS_CONST
    BEQ :+
    JMP cmp_error                ; 第 3 引数は compile-time リテラル必須
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDX #1
    JSR cmp_set_op2_from_arg
    LDX #2
    JSR cmp_set_extended_from_arg
    LDY #20
    LDA #NESPHP_NES_PUT
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; nes_sprite_at($idx, $x, $y, $tile)
; op1 = $idx, op2 = $x, result = $y, extended_value = tile literal
; $idx/$x/$y は any operand type (CV/TMP/CONST)、$tile は IS_CONST 必須
cmp_emit_sprite_at:
    LDA CMP_ARG_COUNT
    CMP #4
    BEQ :+
    JMP cmp_error
:
    LDA CMP_ARG_TYPES+3
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
    JSR cmp_set_result_from_arg
    LDX #3
    JSR cmp_set_extended_from_arg
    LDY #20
    LDA #NESPHP_NES_SPRITE
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; nes_sprite_attr($idx, $attr) — どちらも any operand type
; op1 = $idx, op2 = $attr
cmp_emit_sprite_attr:
    LDA CMP_ARG_COUNT
    CMP #2
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDX #1
    JSR cmp_set_op2_from_arg
    LDY #20
    LDA #NESPHP_NES_SPRITE_ATTR
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; nes_attr($x, $y, $pal)
; op1 = $x, op2 = $y, extended_value = pal literal (IS_CONST、int)
cmp_emit_attr:
    LDA CMP_ARG_COUNT
    CMP #3
    BEQ :+
    JMP cmp_error
:
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
    LDA #NESPHP_NES_ATTR
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; nes_vsync() — 0 引数、戻り値なし
cmp_emit_vsync:
    LDA CMP_ARG_COUNT
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDY #20
    LDA #NESPHP_NES_VSYNC
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; nes_btn() stmt 形式 — 0 引数、戻り値破棄 (result_type = IS_UNUSED)
cmp_emit_btn_stmt:
    LDA CMP_ARG_COUNT
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDY #20
    LDA #NESPHP_NES_BTN
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; count($a); 単独 stmt (結果破棄) — argは arg[0] に配置済、result_type = IS_UNUSED
cmp_emit_count_stmt:
    LDA CMP_ARG_COUNT
    CMP #1
    BEQ :+
    JMP cmp_error
:
    JSR cmp_op24_zero
    LDX #0
    JSR cmp_set_op1_from_arg
    LDY #20
    LDA #ZEND_COUNT
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

; -----------------------------------------------------------------------------
; cmp_emit_assign: ZEND_ASSIGN op1=CV(slot), op2=expr
; -----------------------------------------------------------------------------
cmp_emit_assign:
    JSR cmp_op24_zero
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
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    LDY #20
    LDA #ZEND_ASSIGN
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; -----------------------------------------------------------------------------
; cmp_emit_binary: ADD/SUB/比較 op1=LHS, op2=RHS, result=TMP_new
;   opcode は CMP_INTRINSIC_ID
; -----------------------------------------------------------------------------
cmp_emit_binary:
    JSR cmp_op24_zero
    LDY #0
    LDA CMP_LHS_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_LHS_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #21
    LDA CMP_LHS_TYPE
    STA (CMP_OP_HEAD), Y
    LDY #4
    LDA CMP_EXPR_VAL
    STA (CMP_OP_HEAD), Y
    INY
    LDA CMP_EXPR_VAL+1
    STA (CMP_OP_HEAD), Y
    LDY #22
    LDA CMP_EXPR_TYPE
    STA (CMP_OP_HEAD), Y
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
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
    LDY #20
    LDA CMP_INTRINSIC_ID
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    INC CMP_TMP_COUNT
    RTS

; -----------------------------------------------------------------------------
; cmp_emit_jmpxx_with_bp: JMPZ / JMPNZ を op1=CMP_EXPR、op2=placeholder で emit
;   入力: A = opcode (ZEND_JMPZ etc.)
;   op2 のアドレスを backpatch stack に push
; -----------------------------------------------------------------------------
cmp_emit_jmpxx_with_bp:
    STA TMP2
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
    ; backpatch 対象 = CMP_OP_HEAD + 4 (op2 offset)
    CLC
    LDA CMP_OP_HEAD
    ADC #4
    STA TMP0
    LDA CMP_OP_HEAD+1
    ADC #0
    STA TMP0+1
    JSR cmp_bp_push
    JSR cmp_op_finish
    RTS

; -----------------------------------------------------------------------------
; cmp_emit_op_expr1 (echo): op1 = CMP_EXPR
; -----------------------------------------------------------------------------
cmp_emit_op_expr1:
    STA TMP2
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

; -----------------------------------------------------------------------------
; cmp_emit_incdec_discard: PRE/POST INC/DEC、result_type = IS_UNUSED
;   入力: A = opcode (ZEND_PRE_INC / PRE_DEC / POST_INC / POST_DEC)
;         CMP_INCDEC_SLOT = CV slot
; -----------------------------------------------------------------------------
cmp_emit_incdec_discard:
    STA TMP2
    JSR cmp_op24_zero
    LDX CMP_INCDEC_SLOT
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
    LDY #20
    LDA TMP2
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    RTS

; cmp_emit_incdec_tmp: PRE/POST INC/DEC、result = 新 TMP、CMP_EXPR = TMP
;   入力: A = opcode、CMP_INCDEC_SLOT = CV slot
cmp_emit_incdec_tmp:
    STA TMP2
    JSR cmp_op24_zero
    LDX CMP_INCDEC_SLOT
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
    ; result = 新 TMP
    LDX CMP_TMP_COUNT
    CPX #64
    BCC :+
    JMP cmp_error
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
    LDY #20
    LDA TMP2
    STA (CMP_OP_HEAD), Y
    JSR cmp_op_finish
    LDA TMP0
    STA CMP_EXPR_VAL
    LDA TMP0+1
    STA CMP_EXPR_VAL+1
    LDA #IS_TMP_VAR
    STA CMP_EXPR_TYPE
    INC CMP_TMP_COUNT
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

cmp_emit_zval_true:
    LDA CMP_LIT_COUNT
    STA TMP1
    LDA CMP_LIT_COUNT+1
    STA TMP1+1
    LDY #15
    LDA #0
cezvt_zero:
    STA (CMP_LIT_HEAD), Y
    DEY
    BPL cezvt_zero
    LDY #8
    LDA #TYPE_TRUE
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
