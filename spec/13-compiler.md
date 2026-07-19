# 13. On-NES compiler (self-hosted, L3S)

[← README](./README.md) | [← 12-zend-diff](./12-zend-diff.md)

This document is the single source of truth for the **PHP-source-compiled-by-the-6502-at-boot** configuration (the self-hosted variant). `vm/compiler.s`, the host-side `tools/pack_src.php`, and the parts of the VM core (`vm/nesphp.s`) related to string literal processing all reference this spec.

## Position: fidelity L3S

Adds another row to the fidelity table in [00-overview](./00-overview.md):

| Level | Description |
|------|------|
| L3 | Host-side `serializer.php` bakes NESPHP-compressed `zend_op 12B` (handler/lineno dropped + each znode_op compressed 4B→2B) / Zend-compatible `zval 16B` / `zend_string 24B` into the ROM. The NES VM references field offsets through the `ZOP_*` symbols |
| **L3S** | **PHP source is burned into the ROM. At boot the 6502 compiler emits `zend_op 12B` / `zval 16B` into PRG-RAM. No `zend_string` struct — the `value` field directly carries (ROM offset, length)** |

L3S deliberately deviates from L3 in exactly one point: "no `zend_string`". See [12-zend-diff](./12-zend-diff.md) deviation 10.

## Romance axis

> The L3 romance ("opcodes the real php command emitted") survives via `make build/X.host.nes`. The L3S **new romance** is "**PHP source is burned into the ROM, and at power-on the 6502 itself lex/parse/codegens and runs**". The host-side `pack_src.php` is degraded to "prepend file length, ASCII-check" so that **the knowledge of PHP syntax exists only on the NES side**.

---

## End-to-end flow

```
[Host]
  examples/NAME.php
    │
    ▼ tools/pack_src.php (15 lines)
    │   - <?php tag preserved
    │   - ASCII check only
    │   - Prepend u16 src_len
    │
  build/NAME.src.bin
    │
    ▼ ca65 + ld65
    │   - src.bin → .segment "PHPSRC"
    │   - VM + compiler.s → .segment "CODE"
    │
  build/NAME.nes


[NES at boot]
  reset → PPU init → JSR compile_and_emit
    │
    ▼ compile_and_emit (vm/compiler.s)
    │   - cmp_init:          init ZP state
    │   - cmp_skip_php_tag:  consume the leading `<?php`
    │   - cmp_parse_program: emit opcodes and zvals per grammar
    │   - cmp_finalize:      memcpy literals to their final spot, write the header
    │
  op_array assembled in PRG-RAM $6000-$7FFF
    │
    ▼ Existing VM init / main_loop
  PHP program runs
```

---

## ROM layout (relative to $8000)

Byte layout `pack_src.php` produces in src.bin:

```
offset   size  meaning
0        2     src_len (u16, little-endian). ASCII byte count after $8002
2        N     PHP source (raw ASCII, including <?php tag, src_len bytes)
```

N's cap is "PRG bank 0 remaining" = 16384 − 2 = 16382 bytes. Anything more is a `pack_src.php` compile error.

**What's NOT in there**:
- ❌ zend_string pool (early prototypes had it, removed)
- ❌ Function-name table / identifier intern table
- ❌ lineno table
- ❌ Any host-side pre-digest data

---

## nesphp's interpretation of 16B zval (L3S)

`_zval_struct`'s 16B field offsets exactly match [01-rom-format](./01-rom-format.md). Only the **meaning** changes for L3S:

| offset | size | L3 (host serializer) | L3S (NES compiler) |
|--------|------|---------------------|----------------------|
| 0-1    | 2    | When IS_STRING: offset to a ROM-resident `zend_string` | **When IS_STRING: OPS_BASE-relative offset to the val[] in ROM** |
| 2-3    | 2    | Unused (zero-fill) | **When IS_STRING: string length (unsigned 16-bit)** |
| 4-7    | 4    | Unused (zero-fill) | Unused (zero-fill) |
| 8      | 1    | u1.type_info low 1B = type ID | Same |
| 9-15   | 7    | Zero-fill | Zero-fill |

Other types (IS_LONG etc.) are identical to L3.

### Meaning of value (when IS_STRING)

```
L3 (host):  value.str → zend_string (24B header) → len at offset 16, val[] at offset 24
L3S:        value low 2B → ROM offset of val[] (relative to OPS_BASE)
            value next 2B → length
            (no zend_string struct exists)
```

The VM only needs to read offset+length, eliminating the cycles to chase header/hash/refcount; `echo_string` and `vec_string` get dramatically shorter ([12-zend-diff](./12-zend-diff.md) deviation 10).

---

## 4B tagged value (runtime) extension

The 4B tagged value in [02-ram-layout](./02-ram-layout.md) gets a **new meaning for byte 3** in L3S:

```
byte 0: type ID              (Zend-compatible)
byte 1: payload lo
byte 2: payload hi
byte 3: When IS_STRING → length lo  ← new in L3S
        Other types     → 0
```

The IS_CONST path of resolve_op1 / resolve_op2 reads zval offset 2 and stores it in OP1_VAL+3. For IS_LONG etc. zval offset 2 is fixed at 0, so byte 3 stays 0.

Slot-to-slot copies (`ZEND_ASSIGN` / `ZEND_QM_ASSIGN`) copy all 4 bytes, so the length information propagates automatically through slots.

---

## Supported grammar (as of 2026-04-19, M-A' + P1 + P2 + P3 + P4 + Q1-Q4 + R1-R3 implemented)

```ebnf
program      ::= "<?php" stmt* EOF
stmt         ::= echo_stmt | call_stmt | assign_stmt | inc_stmt | while_stmt
               | if_stmt | for_stmt
echo_stmt    ::= "echo" expr ";"
call_stmt    ::= IDENT "(" args? ")" ";"
assign_stmt  ::= CV "=" expr ";"
             |   CV "[" expr "]" "=" expr ";"  (array index write)
             |   CV "[" "]" "=" expr ";"        (array append)
             |   CV ("++" | "--") ";"      (post-inc/dec as stmt)
inc_stmt     ::= ("++" | "--") CV ";"      (pre-inc/dec as stmt)
while_stmt   ::= "while" "(" expr ")" body
if_stmt      ::= "if" "(" expr ")" body
for_stmt     ::= "for" "(" init? ";" cond? ";" update? ")" body
init         ::= assign_stmt body (without trailing ';' consumption) | inc_stmt | …
update       ::= expr                       (side-effect: $i++, --$j, etc.)
body         ::= "{" stmt* "}" | stmt      (single stmt allowed)
expr         ::= cmp_expr (("&&" | "||") cmp_expr)*
cmp_expr     ::= add_expr (cmp_op add_expr)?
cmp_op       ::= "===" | "!==" | "==" | "!=" | "<"
add_expr     ::= primary (("+" | "-" | "&" | "|" | "<<" | ">>") primary)*
primary      ::= INT | STRING | CV | "true" | call_expr
             |   ("++" | "--") CV           (prefix inc/dec in expr)
             |   CV ("++" | "--")           (postfix inc/dec in expr)
             |   CV ("[" expr "]")+         (chained read, nestable: $a[i][j][k])
             |   "[" (expr ("," expr)*)? "]"  (array literal, nestable, max 15 elems)
call_expr    ::= IDENT "(" args? ")"        (fgets(STDIN) / nes_btn() / count($a) etc.)
args         ::= arg ("," arg)*
arg          ::= expr | "STDIN"
CV           ::= "$" IDENT
INT          ::= [0-9]+ | "0" ("x"|"X") [0-9a-fA-F]+ | "0" ("b"|"B") [01]+
STRING       ::= '"' (char | escape)* '"'
escape       ::= "\x" hex2                  ; arbitrary byte (0x00-0xFF)
             |   "\\"                        ; literal `\`
             |   "\""                        ; literal `"`
hex2         ::= [0-9a-fA-F]{2}
char         ::= [^"\\]                      (non-ASCII bytes allowed)
IDENT        ::= [a-zA-Z_] [a-zA-Z0-9_]*    (ASCII only)
COMMENT      ::= "//" [^\n]* "\n"
             |   "#" [^\n]* "\n"
             |   "/*" ... "*/"              (non-ASCII OK)
```

### Token kinds

| kind       | input | note |
|------------|------|------|
| `TK_EOF`   | (end) | |
| `TK_ECHO`  | `echo` | keyword (cln_ident classifies) |
| `TK_WHILE` | `while` | keyword |
| `TK_IF`    | `if` | keyword |
| `TK_FOR`   | `for` | keyword |
| `TK_TRUE`  | `true` | keyword, emitted as `IS_TRUE` zval |
| `TK_IDENT` | `[a-zA-Z_]\w*` | non-keyword identifiers (function names etc.) |
| `TK_STRING`| `"..."` | Decoded contents go into the **PRG-RAM bank 2 STR_POOL ($6000-$7FFF, 8KB)**; the zval carries an OPS_BASE-relative offset (0..$1FFF). Supports `\xHH` / `\\` / `\"` (other `\` escapes are compile errors). Non-ASCII bytes pass through |
| `TK_INT`   | `[0-9]+` / `0x..` / `0b..` | decimal / hex / binary, narrowed to 16-bit signed |
| `TK_CV`    | `$name` | compile variable |
| `TK_SEMI` / `TK_LPAREN` / `TK_RPAREN` / `TK_COMMA` / `TK_LBRACE` / `TK_RBRACE` | `; ( ) , { }` | |
| `TK_ASSIGN` | `=` | |
| `TK_PLUS` / `TK_MINUS` | `+` `-` | unary `-` not supported |
| `TK_INC` / `TK_DEC` | `++` / `--` | lexer lookaheads after `+`/`-` |
| `TK_LT` | `<` | |
| `TK_EQ2` / `TK_EQ3` | `==` / `===` | lexer lookaheads after `=` |
| `TK_NEQ2` / `TK_NEQ3` | `!=` / `!==` | bare `!` is an error |
| `TK_AMP` / `TK_PIPE` | `&` / `\|` | bitwise AND / OR |
| `TK_AMPAMP` / `TK_PIPEPIPE` | `&&` / `\|\|` | **logical AND / OR (short-circuit)**. Normalizes both operands to bool and returns 0/1 |
| `TK_SL` / `TK_SR` | `<<` / `>>` | 16-bit logical-left / arithmetic-right shift. Bare `>` is unsupported and errors |
| `TK_LBRACKET` / `TK_RBRACKET` | `[` / `]` | array literals / element access |

### Milestone progression

| Milestone | Content | Status |
|---------------|------|------|
| **M-A'** | `<?php`, `echo "..."`, `;`, implicit return | ✅ |
| **P1** | Intrinsic calls (nes_cls/puts/chr_bg/chr_spr/bg_color/palette), integer literals, STDIN | ✅ |
| **P2** | CV, `=`, `+` `-`, echo $var, CV as intrinsic arg, **on-screen error display** | ✅ |
| **P3 (M-C)** | `while { }`, `if { }`, comparisons (`===` `!==` `==` `!=` `<`), `$k = fgets(STDIN)`, `true`, backpatch stack | ✅ |
| **P4 (comments + non-ASCII)** | `//`, `#`, `/* */`; non-ASCII bytes inside string literals pass through | ✅ |
| **Q1-Q4** | Remaining intrinsics (nes_put / nes_sprite (1-sprite version, later expanded by W1 to nes_sprite_at) / nes_attr), hex literals `0x..`, `++` / `--` (PRE/POST INC/DEC), `for` loop, single-statement if/while bodies | ✅ |
| **R1** | Real-time input: `nes_vsync()` (VBlank sync + auto-enable sprite_mode) | ✅ |
| **R2** | `nes_btn()` becomes 0-arg, returns the controller state (low 1B = bitmask) as IS_LONG | ✅ |
| **R3** | Bitwise operators `&` / `\|` (`ZEND_BW_AND` / `ZEND_BW_OR`), binary literal `0b..` | ✅ |
| **S1-S4** | Logical operators `&&` / `\|\|` (short-circuit, JMPZ/JMPNZ + QM_ASSIGN pattern), shifts `<<` / `>>` (`ZEND_SL` / `ZEND_SR`) | ✅ |
| **T1** | `\xHH` / `\\` / `\"` escapes inside string literals. Decoded bytes go to PRG-RAM bank 2 STR_POOL ($6000-$7FFF, 8KB); the zval points to a pool offset. Authentic PHP-compatible syntax for arbitrary bytes (so we can target CHR tile indices for non-ASCII text directly) | ✅ |
| **U1** | Integer-keyed array MVP: `[expr,...]` literal + `$a[idx]` read + `count($a)`. IS_ARRAY=7, 2KB runtime array pool ($7000-$77FF). ZEND_INIT_ARRAY / ZEND_ADD_ARRAY_ELEMENT / ZEND_FETCH_DIM_R / ZEND_COUNT opcodes | ✅ |
| **V1-V4** | Arrays: **write `$a[i] = v`** + **append `$a[] = v`** (ZEND_ASSIGN_DIM + ZEND_OP_DATA, 2-op sequence), **nested read `$a[i][j]...`** (FETCH_DIM_R chain), **nested literal `[[1,2],[3,4]]`** (CMP_ARR_* saved on the stack). Associative arrays / foreach unsupported | ✅ |
| **W1** | Multi-sprite: `nes_sprite_at($idx, $x, $y, $tile)` (4 args, $idx runtime-int OK), `nes_sprite_attr($idx, $attr)`. Repurpose NESPHP_NES_SPRITE (0xF2) from "OAM[0] fixed" to "OAM[$idx]" by reusing the result slot as the third input ($y). Add NESPHP_NES_SPRITE_ATTR (0xFC) | ✅ |
| **W2** | `nes_rand()` (returns IS_LONG) / `nes_srand($seed)`. 16-bit Galois LFSR (period 65535). Also fixed the ASSIGN_DIM bug in the `$xs[$i] = $xs[$i] + 1` pattern (now parses RHS before emitting ASSIGN_DIM, so no sub-ops sneak in between) | ✅ |
| **W3** | Parser extension: `else` / `elseif` chains, `<=` (new ZEND_IS_SMALLER_OR_EQUAL handler), `>` / `>=` (operand swap to fold into `<` / `<=`), parenthesized `(expr)`. Also fixed `cmp_parse_expr` to save/restore CMP_LHS_VAL/TYPE / CMP_INTRINSIC_ID across recursive calls (closes a latent bug where `1 + (2 << 3)` etc. clobbered the outer binop state) | ✅ |
| **W4** | `nes_putint($x, $y, $value)` (NESPHP_NES_PUTINT 0xFF). 5-char right-justified unsigned int display (HUD score), all 3 args runtime-int. Uses Y for the loop counter to avoid div_tmp0_by_10's X clobber | ✅ |
| **W5** | Arithmetic operator extensions: `*` (ZEND_MUL 3) / `/` (ZEND_DIV 4) / `%` (ZEND_MOD 5). Signed 16-bit, divide-by-0 silent 0 fallback. Introduces `parse_mul_expr` so `* / %` outranks `+ -`. Both `parse_add_expr` and `parse_mul_expr` save/restore CMP_LHS / CMP_INTRINSIC_ID (same motive as W3's parse_expr fix). Also fixed the negative-number X clobber in `print_int16` | ✅ |
| Next | `foreach`, unary `-` / `!`, `^` (BW_XOR) | Not started |
| Out of scope | Associative arrays, objects, foreach, doubles | L3 policy |

### Numeric literals

PHP-faithful three notations (all `IS_LONG`, narrowed to 16-bit signed):

| Notation | Examples | Meaning |
|------|-----|------|
| Decimal | `42`, `255`, `0` | `[0-9]+` |
| Hex | `0x0F`, `0xFF`, `0X80` | `0x` / `0X` prefix + `[0-9a-fA-F]+` |
| Binary | `0b1010`, `0b10000000`, `0B11` | `0b` / `0B` prefix + `[01]+` |

**Range**: signed 16-bit (`-32768 .. 32767`). Out-of-range is undefined (the lexer doesn't detect overflow; only the lower 16 bits remain).

**Recommended use**:
- **Button masks**: binary (`0b10000000` = A) is visually clearest
- **NES color codes**: hex (`0x0F` = black, `0x30` = white)
- **Coordinates / counters**: decimal

Examples:
```php
$b = nes_btn();
if ($b & 0b10000000) { /* A */ }
nes_bg_color(0x0F);                   // black
$i = 0; while ($i < 10) { $i = $i + 1; }
```

### Emitted opcodes (numbers per PHP 8.4, [04-opcode-mapping](./04-opcode-mapping.md))

| Construct | Emitted opcode |
|------|-------------|
| `echo expr;` | `ZEND_ECHO` (op1 = expr result) |
| Implicit `return` | `ZEND_RETURN` op1 = IS_LONG(1) literal |
| `$x = expr;` | `ZEND_ASSIGN` (op1 = CV, op2 = expr result) |
| `$a + $b` / `$a - $b` | `ZEND_ADD` / `ZEND_SUB` (result = new TMP) |
| `$a & $b` / `$a \| $b` | `ZEND_BW_AND` / `ZEND_BW_OR` (result = new TMP, IS_LONG) |
| `$a << $b` / `$a >> $b` | `ZEND_SL` / `ZEND_SR` (result = new TMP, 16-bit shift) |
| `$a && $b` / `$a \|\| $b` | Short-circuit via JMPZ/JMPNZ + QM_ASSIGN + JMP. result = new TMP (IS_LONG 0 or 1). 5 opcodes / operator |
| `$a === $b` etc. | `ZEND_IS_IDENTICAL` / `ZEND_IS_NOT_IDENTICAL` / `ZEND_IS_EQUAL` / `ZEND_IS_NOT_EQUAL` / `ZEND_IS_SMALLER` (result = new TMP) |
| `$x++;` / `$x--;` (stmt) | `ZEND_POST_INC` / `ZEND_POST_DEC` result_type = IS_UNUSED |
| `++$x;` / `--$x;` (stmt) | `ZEND_PRE_INC` / `ZEND_PRE_DEC` result_type = IS_UNUSED |
| `$x++` / `$x--` (expr) | `ZEND_POST_INC` / `ZEND_POST_DEC` result = new TMP (old value) |
| `++$x` / `--$x` (expr) | `ZEND_PRE_INC` / `ZEND_PRE_DEC` result = new TMP (new value) |
| `while (c) {}` | `ZEND_JMPZ c, end` (backpatched); body; `ZEND_JMP top` |
| `if (c) {}` | `ZEND_JMPZ c, end` (backpatched); body |
| `for (init; cond; upd) body` | init; `JMPZ cond, end`; `JMP body-start`; upd; `JMP loop_top`; body; `JMP upd-start`; end (double-JMP scheme) |
| `nes_xxx(...)` (10 kinds) | The corresponding `NESPHP_NES_*` (0xF1-0xF9) / `NESPHP_FGETS` (0xF0) |
| `fgets(STDIN)` standalone | `NESPHP_FGETS` result_type = IS_UNUSED |
| `$k = fgets(STDIN)` | `NESPHP_FGETS` result = TMP, `ZEND_ASSIGN $k, TMP` |
| `nes_vsync();` | `NESPHP_NES_VSYNC` (no return value, auto-enables sprite_mode → wait NMI) |
| `nes_btn();` standalone | `NESPHP_NES_BTN` (0 args, result_type = IS_UNUSED, side-effect = read_controller) |
| `nes_btn()` (expr) | `NESPHP_NES_BTN` result = TMP (IS_LONG = buttons bitmask). Caller checks bits with `$b & mask` |
| `[expr, expr, ...]` | `ZEND_INIT_ARRAY` (op1 = elem count raw, result = new TMP) + `ZEND_ADD_ARRAY_ELEMENT` per element (op1 = array TMP, op2 = element). Result is an IS_ARRAY TMP holding a pool pointer |
| `$a[idx]` | `ZEND_FETCH_DIM_R` (op1 = CV array, op2 = index, result = new TMP). Pool elements are stored as 4B tagged zvals, read out as-is (16B zvals are literal-only) |
| `count($a)` | `ZEND_COUNT` (op1 = array, result = new TMP, IS_LONG = element count) |
| `$a[i] = v;` | `ZEND_ASSIGN_DIM` (op1=CV array, op2=index) + `ZEND_OP_DATA` (op1=value). Handler writes a 16B zval into array[i] across the 2-op set, count = max(count, i+1) |
| `$a[] = v;` | Same as above but op2_type = IS_UNUSED (append). slot = current count, count++ after the write |
| `$a[i][j]...` | Chain of `ZEND_FETCH_DIM_R` as needed. Reuse the intermediate TMP as the next op1 |
| `[[1,2],[3,4]]` | Outer INIT_ARRAY → inner INIT_ARRAY + ADD × 2 → outer ADD → ... (recursive; CMP_ARR_* are saved on the stack) |

### Comparison-expression precision

`expr` is left-associative two-tier; **comparisons cannot chain** (`$a < $b < $c` is a compile error). Precedence: `+ -` > `== === != !== <`. The comparison result is a `IS_TRUE` / `IS_FALSE` written to a TMP by `ZEND_IS_*`; `if` / `while` consume that TMP as JMPZ's op1.

### Code generation for while / if

Backpatch stack (16B in ZP = up to 8 levels of nesting) keeps "PRG-RAM absolute addresses where the op2 field needs filling later". At block end `cmp_bp_pop_patch` writes the current `CMP_OP_COUNT` at that location as a 16-bit value.

```
while (cond) { body }                if (cond) { body }
                                     
LOOP_TOP:    (save op_count)         JMPZ cond, END   (backpatch push)
  JMPZ cond, END  (backpatch push)   body
  body                               END:   (backpatch pop + write CMP_OP_COUNT)
  JMP LOOP_TOP    (fill saved value)
END:   (backpatch pop)
```

The `LOOP_TOP` for `while` is saved on the 6502 hardware stack via PHA × 2 (nesting). `JMP` carries the op_index in op1 directly as 16-bit (op1_type = IS_UNUSED).

---

## WRAM sharing contract (compile vs runtime phases)

We share the 2KB WRAM ($0000-$07FF) by separating compile-time and runtime in time. After `compile_and_emit` returns, the VM main_loop runs on the existing layout.

### ZP used only during compile (~55 bytes at P3)

| label | size | purpose |
|-------|------|------|
| `CMP_SRC_PTR` | 2 | Current source read pointer (within ROM $8002-$BFFF) |
| `CMP_SRC_END` | 2 | Source one-past-last |
| `CMP_LINE` / `CMP_COL` | 2 each | Line / column (1-origin, for error display) |
| `CMP_OP_HEAD` | 2 | PRG-RAM address of the next zend_op to emit ($6010..) |
| `CMP_LIT_HEAD` | 2 | PRG-RAM address of the next zval to emit (temporary, $7000..) |
| `CMP_OP_COUNT` / `CMP_LIT_COUNT` | 2 each | Counts emitted so far |
| `CMP_TMP_COUNT` | 1 | Allocated TMP slot count (for arithmetic / comparisons / fgets result) |
| `CMP_CV_COUNT` | 1 | Allocated CV slot count |
| `CMP_TOK_KIND` | 1 | Current token kind |
| `CMP_TOK_PTR` | 2 | Token start ROM address (STRING/IDENT/CV) |
| `CMP_TOK_LEN` | 1 | Token length (1B, max 255) |
| `CMP_TOK_VALUE` | 2 | TK_INT: parsed 16-bit value |
| `CMP_INTRINSIC_ID` | 1 | Intrinsic number (also reused to save the binary op opcode) |
| `CMP_ARG_COUNT` | 1 | Arg count for the current call |
| `CMP_ARG_LITS` | 8 | 4 args × 2B; per-arg operand value |
| `CMP_ARG_TYPES` | 4 | Per-arg operand type |
| `CMP_ASSIGN_SLOT` | 1 | LHS CV slot during assignment |
| `CMP_EXPR_TYPE` / `CMP_EXPR_VAL` | 1 / 2 | parse_expr's returned operand |
| `CMP_LHS_TYPE` / `CMP_LHS_VAL` | 1 / 2 | binary op LHS save area |
| `CMP_BP_TOP` | 1 | Backpatch stack pointer |
| `CMP_BP_STACK` | 16 | 8 entries × 2B = patch-target PRG-RAM addresses |

Unused after compile — the VM doesn't touch them.

### CV symbol table (WRAM $0700-)

- 4B per entry: `[len, name_ptr_lo, name_ptr_hi, pad]`
- `cmp_cv_intern` does linear lookup + new alloc
- Up to 64 slots (= the full 256B region; matches the VM-side CV slot cap)
- At runtime, the same `$0700-$07FF` is repurposed as **USER_RAM** (a 256B generic byte region for peek/poke). No aliasing — temporally separated

### Workspace (PRG-RAM, spread across multiple banks)

**Bank 0** ($6000-$7FFF, mapped by default):

```
$6000-$600F  header (16B)
$6010-...    op_array (12B × num_ops, max ~617 op)
$????-$7CFF  literals (16B × num_lits, max ~48 zval, memcpy'd right after op_array)
$7D00-$7FFF  CMP_LIT_STAGE (768B, compile-only, temporary zval buffer)
```

**Bank 1** ($6000-$7FFF, atomically swapped at array-handler entry/exit): ARR_POOL 8KB

**Bank 2** ($6000-$7FFF, atomically swapped at string-handler / `cln_string` entry/exit): STR_POOL 8KB (string literal pool)

**Bank 3** ($6000-$7FFF, atomically swapped inside `nes_*_ext` intrinsics): USER_RAM_EXT 8KB (peek/poke_ext generic byte region)

- **op_array**: grows from `$6010`. Cap is CMP_LIT_STAGE = $7D00 (op_finish does a 16-bit compare; overflow → compile error)
- **literals**: cmp_finalize bulk-memcpys CMP_LIT_STAGE zvals to $6010 + ops × 12
- **STR_POOL** (bank 2): cln_string writes decoded bytes here; the IS_STRING zval value carries an OPS_BASE-relative STR_POOL offset (0..$1FFF). Runtime references it directly (no memcpy). Pool overflow ($8000 reached) → compile error
- **ARR_POOL** (bank 1): runtime allocates array headers (4B count, capacity) + capacity × 16B zvals append-style. No GC

### Sharing TMP0/TMP1/TMP2

`TMP0`, `TMP1`, `TMP2` (2 bytes each, ZP) are scratch for both compile and runtime. compile_and_emit completes before the runtime starts, so the overlap is fine (values stay within their respective routines).

### 16-bit slot resolution for CV/TMP

The `op.var` field stores `slot * 16` as 16-bit (Zend convention). The VM's resolver divides by 4 to get the RAM offset (`slot * 4`).

When **slot ≥ 16**, `slot * 16 ≥ 256` and a single byte isn't enough. `vm/nesphp.s`'s `cv_addr_y` / `tmp_addr_y` helpers read 16 bits from (VM_PC, Y), (VM_PC, Y+1) and divide by 4 in 16-bit. res_cv / res_tmp / wr_cv / wr_tmp / assign_to_cv / incdec_cv_addr all funnel through them.

### TMP_COUNT resets between statements

`cmp_dispatch_stmt` PHAs `CMP_TMP_COUNT` on entry and PLAs at exit (`cds_done`). TMP slots emitted within a statement (cond expr, binary results, fgets result, etc.) die at the statement boundary, so they're reusable across statements. This keeps long programs working past the 64-slot cap.

---

## Constraints

1. **PHP source must start with `<?php`**. No omission allowed. No trailing whitespace required (the lexer separates by whatever follows: echo / IDENT)
2. **Non-ASCII**: **bytes inside string literals and comments pass through transparently**. Anywhere else, a non-ASCII byte raises a NES-side compile error (ERR L/C screen). pack_src.php doesn't pre-check. UTF-8 bytes inside strings (e.g. "あ" = 3B) flow as tile IDs through `echo` / `nes_puts` to the PPU — the user is expected to provide matching CHR tiles
3. **Strings are double-quoted only**. Escapes are `\xHH` (arbitrary byte), `\\`, `\"` (other escapes are compile errors). Decoded bytes accumulate in the PRG-RAM bank 2 STR_POOL ($6000-$7FFF, 8KB). Pool overflow → compile error
4. **Strings ≤ 255 bytes** (`CMP_TOK_LEN` is 1 byte today). UTF-8 Japanese (1 char = 3B) means up to ~85 chars
5. **Comments supported** (P4): `//`, `#`, `/* */`. Unclosed block comment → compile error
6. **Source length cap 16382 bytes** (PRG bank 0 is 16KB minus the 2B header)
7. **PRG-RAM 32KB (4 × 8KB banks)** is the cap for compile output. Bank 0 (op_array + literal zvals, ~617 op + ~48 zval = 8KB), bank 1 (ARR_POOL 8KB), bank 2 (STR_POOL 8KB; string literals also live in PRG-RAM here), bank 3 (USER_RAM_EXT 8KB)
8. **CV up to 64 slots**, **TMP up to 64 slots** (reset between statements, reusable), **function args ≤ 4**, **no nested calls** (call expr only `fgets` / `nes_btn` / `nes_rand` / `nes_peek` / `nes_peek16`)
9. **Comparison expressions don't chain** (`$a < $b < $c` is a compile error)
10. **`!` / unary `-` not supported**, **`^` (BW_XOR) not supported**, **string concat `.` not supported**
11. **if / while / for body**: either `{ ... }` or a single statement
12. **Nesting depth**: backpatch stack 8 levels, 6502 HW stack 256B (a `for` consumes 4B per nest), CV table 64 entries
13. **Supported intrinsics** (20 total): `nes_cls` / `nes_put` / `nes_puts` / `nes_putint` / `nes_sprite_at` / `nes_sprite_attr` / `nes_chr_bg` / `nes_chr_spr` / `nes_bg_color` / `nes_palette` / `nes_attr` / `fgets` / `nes_vsync` / `nes_btn` / `nes_rand` / `nes_srand` / `nes_peek` / `nes_peek16` / `nes_poke` / `nes_pokestr`
14. **Integer literals**: decimal (`42`), hex (`0xFF` / `0X0A`), binary (`0b1010` / `0B11`). 16-bit signed narrow, no overflow detection
15. **Bitwise**: `&` (BW_AND) / `|` (BW_OR) / `<<` (SL) / `>>` (SR, arithmetic right = sign-preserving). `^` (BW_XOR) / `~` (BW_NOT) unsupported
16. **Logical**: `&&` / `||` short-circuit, result is IS_LONG 0 or 1. `!` (NOT) unsupported
17. **Arithmetic**: `+` / `-` / `*` / `/` (signed truncate-toward-zero) / `%` (sign of dividend, PHP/C convention)
18. **`nes_rand() % N`**: rand returns unsigned 16-bit but PHP's `%` takes the dividend's sign, so a high bit makes it negative. The idiom is `(nes_rand() & 0x7FFF) % N` to mask to a positive value

---

## Error handling (since P2, implemented)

When compile fails, `show_compile_error` writes to nametable `$2160` (row 11, col 0):

```
ERR L<line> C<col>
```

Then sets the BG-enable bit in `PPUMASK` so the message displays, then halts. `CMP_LINE` / `CMP_COL` are bumped by `cmp_advance1` (LF → `line++` / `col=1`, otherwise `col++`). `cmp_advance_n` (used to skip the 5-char `<?php`) does an approximate `col += A` (assumes no LF in the chunk).

Implementation: `show_compile_error` in `vm/compiler.s`. Reuses `print_int16` (`vm/nesphp.s:1521`) to ASCII-ize numbers and stream them into `PPUDATA`.

Error-message **categorization (error codes)** doesn't exist yet (single message). Future work could attach short codes per syntax violation.

**Host-side pre-flight lint** (future): a simple syntax check (unclosed double quotes etc.) inside `pack_src.php` to catch errors early at ROM-build time. The on-NES error halt remains as a safety net.

---

## Compile-speed estimate

Estimates on a 6502 @ 1.79MHz for 1KB of PHP source:

- cmp_lex_next: ~200 cycles per token
- String scan: ~15 cycles per byte
- emit_op24 / emit_zval: ~500 cycles per call

Roughly ~80ms total for 1KB source, ~250ms for 4KB. The lag from power-on to VM main_loop is "a brief flash" perceptually.

---

## Related documents

- [00-overview](./00-overview.md) — 3-layer architecture and fidelity (L3S addition planned)
- [01-rom-format](./01-rom-format.md) — ROM binary layout (note in §4 that L3S omits zend_string)
- [02-ram-layout](./02-ram-layout.md) — 4B tagged value (byte 3 = length when IS_STRING)
- [04-opcode-mapping](./04-opcode-mapping.md) — Intrinsic table (P1 implementation targets)
- [07-roadmap](./07-roadmap.md) — Milestone progression
- [12-zend-diff](./12-zend-diff.md) — Zend comparison (deviation 10: zend_string omission)
- `vm/compiler.s` — Compiler implementation
- `tools/pack_src.php` — Source packer
