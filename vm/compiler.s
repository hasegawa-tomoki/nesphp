; =============================================================================
; compiler.s — on-NES PHP コンパイラ (Milestone M-A)
;
; PHP ソース ($8000-) を読み、PRG-RAM に L3 形式の op_array を emit する。
; VM 本体はそれを解釈するだけ。
;
; ROM レイアウト ($8000-) は pack_src.php が用意する (詳細は nesphp.s 参照):
;   $8000  u16 src_len
;   $8002  u16 pool_off
;   $8004  u16 pool_count
;   $8008  ASCII src body
;   $8000+pool_off  zend_string プール (Zend 互換レイアウト)
;
; 方針:
;   - zend_string は ROM-resident のまま使う。コンパイラは value.str に
;     (pool エントリ ROM address) - OPS_BASE を書くだけ
;   - opcode は CMP_OP_HEAD ($6010..) から前向きに emit
;   - zval は CMP_LIT_STAGE ($7000..) に一時的に emit し、parse 終了後に
;     OPS_BASE + literals_off へ memcpy
;   - op.constant (literal 参照) は literal_index * 16 として emit
;
; M-A で対応する構文:
;   program   ::= echo_stmt* EOF
;   echo_stmt ::= "echo" STRING ";"
;
; このファイルは nesphp.s の CODE セグメント末尾で .include される。
; =============================================================================

; --- Token kind ---
TK_EOF     = 0
TK_ECHO    = 1
TK_STRING  = 2
TK_SEMI    = 3

; -----------------------------------------------------------------------------
; compile_and_emit: エントリポイント (reset から JSR される)
; -----------------------------------------------------------------------------
compile_and_emit:
    JSR cmp_init
    JSR cmp_parse_program
    JSR cmp_finalize
    RTS

; -----------------------------------------------------------------------------
; cmp_init: ZP 状態を初期化
; -----------------------------------------------------------------------------
cmp_init:
    ; CMP_SRC_PTR = PHP_SRC_BODY
    LDA #<PHP_SRC_BODY
    STA CMP_SRC_PTR
    LDA #>PHP_SRC_BODY
    STA CMP_SRC_PTR+1
    ; CMP_SRC_END = PHP_SRC_BODY + src_len
    CLC
    LDA #<PHP_SRC_BODY
    ADC PHP_SRC_LEN
    STA CMP_SRC_END
    LDA #>PHP_SRC_BODY
    ADC PHP_SRC_LEN+1
    STA CMP_SRC_END+1
    ; CMP_POOL_CURSOR = $8000 + pool_off = PHP_SRC_LEN + pool_off
    ; (PHP_SRC_LEN == $8000 なので、$8000 を基点に pool_off を足すだけ)
    CLC
    LDA #<PHP_SRC_LEN
    ADC PHP_POOL_OFF
    STA CMP_POOL_CURSOR
    LDA #>PHP_SRC_LEN
    ADC PHP_POOL_OFF+1
    STA CMP_POOL_CURSOR+1
    ; op_head = OPS_FIRST_OP
    LDA #<OPS_FIRST_OP
    STA CMP_OP_HEAD
    LDA #>OPS_FIRST_OP
    STA CMP_OP_HEAD+1
    ; lit_head = CMP_LIT_STAGE
    LDA #<CMP_LIT_STAGE
    STA CMP_LIT_HEAD
    LDA #>CMP_LIT_STAGE
    STA CMP_LIT_HEAD+1
    ; カウンタを 0 に
    LDA #0
    STA CMP_OP_COUNT
    STA CMP_OP_COUNT+1
    STA CMP_LIT_COUNT
    STA CMP_LIT_COUNT+1
    RTS

; -----------------------------------------------------------------------------
; cmp_parse_program: ループで echo_stmt を処理、EOF で暗黙 RETURN
; -----------------------------------------------------------------------------
cmp_parse_program:
cpp_loop:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_EOF
    BEQ cpp_emit_return
    CMP #TK_ECHO
    BEQ cpp_echo
    JMP cmp_error

cpp_echo:
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_STRING
    BNE cmp_error
    ; pool から zend_string の OPS_BASE 相対 offset を TMP0 に取る
    ; (消費: CMP_POOL_CURSOR を 24 + len + 1 進める、TMP0 に offset を返す)
    JSR cmp_consume_pool_entry
    ; IS_STRING zval を CMP_LIT_HEAD に書く (TMP0 を使う、TMP1 に lit_idx を返す)
    JSR cmp_emit_zval_string
    ; ZEND_ECHO op を CMP_OP_HEAD に書く (A = opcode, TMP1 = lit_idx)
    LDA #ZEND_ECHO
    JSR cmp_emit_op_const1
    ; SEMI
    JSR cmp_lex_next
    LDA CMP_TOK_KIND
    CMP #TK_SEMI
    BNE cmp_error
    JMP cpp_loop

cpp_emit_return:
    JSR cmp_emit_zval_long_1
    LDA #ZEND_RETURN
    JSR cmp_emit_op_const1
    RTS

; -----------------------------------------------------------------------------
; cmp_error: M-A では無限ループ (後で画面表示に置き換える)
; -----------------------------------------------------------------------------
cmp_error:
    JMP cmp_error

; -----------------------------------------------------------------------------
; cmp_lex_next: 次のトークンを CMP_TOK_KIND に書く
; -----------------------------------------------------------------------------
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
    BEQ cln_string
    CMP #';'
    BEQ cln_semi
    CMP #'e'
    BEQ cln_echo
    JMP cmp_error

cln_semi:
    JSR cmp_advance1
    LDA #TK_SEMI
    STA CMP_TOK_KIND
    RTS

cln_string:
    ; 開きダブルクォートを消費
    JSR cmp_advance1
    ; TOK_PTR = 現在位置 (文字列本体の先頭)
    LDA CMP_SRC_PTR
    STA CMP_TOK_PTR
    LDA CMP_SRC_PTR+1
    STA CMP_TOK_PTR+1
    LDX #0
cln_str_loop:
    JSR cmp_at_eof
    BEQ cmp_error
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
    JSR cmp_advance1          ; 閉じダブルクォート
    LDA #TK_STRING
    STA CMP_TOK_KIND
    RTS

cln_echo:
    ; 'echo' の 4 文字判定 + 直後の語境界確認
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #'e'
    BNE cmp_error
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'c'
    BNE cmp_error
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'h'
    BNE cmp_error
    INY
    LDA (CMP_SRC_PTR), Y
    CMP #'o'
    BNE cmp_error
    LDA #4
    JSR cmp_advance_n
    ; 直後は空白/"/EOF のみ許容
    JSR cmp_at_eof
    BEQ cln_echo_ok
    LDY #0
    LDA (CMP_SRC_PTR), Y
    CMP #' '
    BEQ cln_echo_ok
    CMP #9
    BEQ cln_echo_ok
    CMP #10
    BEQ cln_echo_ok
    CMP #13
    BEQ cln_echo_ok
    CMP #'"'
    BEQ cln_echo_ok
    JMP cmp_error
cln_echo_ok:
    LDA #TK_ECHO
    STA CMP_TOK_KIND
    RTS

; -----------------------------------------------------------------------------
; cmp_skip_ws: 空白・タブ・改行を消費
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

; -----------------------------------------------------------------------------
; cmp_at_eof: Z=1 なら EOF、Z=0 なら未 EOF
; -----------------------------------------------------------------------------
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

; -----------------------------------------------------------------------------
; cmp_advance1 / cmp_advance_n: CMP_SRC_PTR を進める
; -----------------------------------------------------------------------------
cmp_advance1:
    INC CMP_SRC_PTR
    BNE ca1_ret
    INC CMP_SRC_PTR+1
ca1_ret:
    RTS

cmp_advance_n:
    CLC
    ADC CMP_SRC_PTR
    STA CMP_SRC_PTR
    BCC can_ret
    INC CMP_SRC_PTR+1
can_ret:
    RTS

; -----------------------------------------------------------------------------
; cmp_consume_pool_entry: pool 内の次の zend_string を「消費」する
;   - TMP0 に OPS_BASE 相対 16bit offset (= CMP_POOL_CURSOR - OPS_BASE) を返す
;   - CMP_POOL_CURSOR を 24 + CMP_TOK_LEN + 1 進める
;
; 呼び出し契約:
;   pool は pack_src.php が ソース出現順に並べている。コンパイラも ソース順に
;   消費するので 1:1 対応。CMP_TOK_LEN は直前の cmp_lex_next で設定済み。
;   (ROM 内 zend_string の len フィールドも同じ値が入っているはずだが確認はしない)
; -----------------------------------------------------------------------------
cmp_consume_pool_entry:
    SEC
    LDA CMP_POOL_CURSOR
    SBC #<OPS_BASE
    STA TMP0
    LDA CMP_POOL_CURSOR+1
    SBC #>OPS_BASE
    STA TMP0+1
    ; pool_cursor += 24 + len + 1  = len + 25
    LDA CMP_TOK_LEN
    CLC
    ADC #25
    CLC
    ADC CMP_POOL_CURSOR
    STA CMP_POOL_CURSOR
    BCC ccpe_ret
    INC CMP_POOL_CURSOR+1
ccpe_ret:
    RTS

; -----------------------------------------------------------------------------
; cmp_emit_zval_string: CMP_LIT_HEAD に IS_STRING zval (16B) を書く
;   入力: TMP0 = zend_string の OPS_BASE 相対 offset
;   出力: TMP1 = literal_index
; -----------------------------------------------------------------------------
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

    LDY #8
    LDA #TYPE_STRING
    STA (CMP_LIT_HEAD), Y

    CLC
    LDA CMP_LIT_HEAD
    ADC #16
    STA CMP_LIT_HEAD
    BCC cezvs_hi_ok
    INC CMP_LIT_HEAD+1
cezvs_hi_ok:
    INC CMP_LIT_COUNT
    BNE cezvs_ret
    INC CMP_LIT_COUNT+1
cezvs_ret:
    RTS

; -----------------------------------------------------------------------------
; cmp_emit_zval_long_1: CMP_LIT_HEAD に IS_LONG(1) zval を書く
;   出力: TMP1 = literal_index
; -----------------------------------------------------------------------------
cmp_emit_zval_long_1:
    LDA CMP_LIT_COUNT
    STA TMP1
    LDA CMP_LIT_COUNT+1
    STA TMP1+1

    LDY #15
    LDA #0
cezvl_zero:
    STA (CMP_LIT_HEAD), Y
    DEY
    BPL cezvl_zero

    LDY #0
    LDA #1
    STA (CMP_LIT_HEAD), Y
    LDY #8
    LDA #TYPE_LONG
    STA (CMP_LIT_HEAD), Y

    CLC
    LDA CMP_LIT_HEAD
    ADC #16
    STA CMP_LIT_HEAD
    BCC cezvl_hi_ok
    INC CMP_LIT_HEAD+1
cezvl_hi_ok:
    INC CMP_LIT_COUNT
    BNE cezvl_ret
    INC CMP_LIT_COUNT+1
cezvl_ret:
    RTS

; -----------------------------------------------------------------------------
; cmp_emit_op_const1: op1 に IS_CONST の literal[TMP1] を取る zend_op を emit
;   入力: A = opcode 番号、TMP1 = literal_index
;   op.op1 = TMP1 * 16、op.op1_type = IS_CONST
;   op2/result/extended_value = 0
; -----------------------------------------------------------------------------
cmp_emit_op_const1:
    STA TMP2             ; opcode 退避

    LDY #23
    LDA #0
ceoc_zero:
    STA (CMP_OP_HEAD), Y
    DEY
    BPL ceoc_zero

    ; TMP0 = TMP1 << 4
    LDA TMP1
    STA TMP0
    LDA TMP1+1
    STA TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1
    ASL TMP0
    ROL TMP0+1

    LDY #0
    LDA TMP0
    STA (CMP_OP_HEAD), Y
    INY
    LDA TMP0+1
    STA (CMP_OP_HEAD), Y

    LDY #20
    LDA TMP2
    STA (CMP_OP_HEAD), Y
    INY
    LDA #IS_CONST
    STA (CMP_OP_HEAD), Y

    CLC
    LDA CMP_OP_HEAD
    ADC #24
    STA CMP_OP_HEAD
    BCC ceoc_hi_ok
    INC CMP_OP_HEAD+1
ceoc_hi_ok:
    INC CMP_OP_COUNT
    BNE ceoc_ret
    INC CMP_OP_COUNT+1
ceoc_ret:
    RTS

; -----------------------------------------------------------------------------
; cmp_finalize: parse 完了後、literals を最終位置へ memcpy し、header を書く
; -----------------------------------------------------------------------------
cmp_finalize:
    ; src = CMP_LIT_STAGE
    LDA #<CMP_LIT_STAGE
    STA TMP0
    LDA #>CMP_LIT_STAGE
    STA TMP0+1
    ; dst = CMP_OP_HEAD
    LDA CMP_OP_HEAD
    STA TMP1
    LDA CMP_OP_HEAD+1
    STA TMP1+1
    ; size = CMP_LIT_COUNT * 16
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

    ; ヘッダ 16B を書く
    LDA CMP_OP_COUNT
    STA HDR_NUM_OPS
    LDA CMP_OP_COUNT+1
    STA HDR_NUM_OPS+1

    ; literals_off = CMP_OP_HEAD - OPS_BASE
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

    LDA #0
    STA HDR_NUM_CVS
    STA HDR_NUM_CVS+1
    STA HDR_NUM_TMPS
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
