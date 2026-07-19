# 03. 6502 VM Fetch-Dispatch Design

[← README](./README.md) | [← 02-ram-layout](./02-ram-layout.md) | [→ 04-opcode-mapping](./04-opcode-mapping.md)

The VM core is 6502 assembly written in ca65. Target line count: ~1200 lines.

## High-level structure

```
Reset handler (RESET)
  ├ Init zero page & stack
  ├ PPU warm-up (wait two VBLs)
  ├ Load palette
  ├ Clear nametable
  ├ Read the op_array header to set VM_PC/VM_LITBASE/VM_CVBASE/VM_TMPBASE
  ├ Start the VM main loop in forced blanking ($2001 = 0)
  └ After ZEND_RETURN, enable $2001 and loop forever (waiting for NMI)

VM main loop (main_loop:)
  ├ fetch:    read the opcode byte at VM_PC + ZOP_OPCODE (=8)
  ├ dispatch: branch to a handler via jump table
  ├ handler:  operand resolver + body
  └ advance:  VM_PC += ZOP_SIZE (=12), back to main_loop

NMI handler
  └ (almost empty in MVP; OAM DMA / nametable diff transfer for extension goals)
```

## Main loop (fetch-dispatch)

```asm
main_loop:
    ; Read the opcode (zend_op offset 8)
    LDY #ZOP_OPCODE          ; = 8
    LDA (VM_PC),Y       ; A = opcode byte (e.g. 0x88 = ZEND_ECHO)
    ; (Implementation: serial compare + JMP handler. No jump table.)
```

- The implementation is a long chain of `CMP #OPCODE / BNE :+ / JMP handle_xxx` (`main_loop:` is ~210 lines). It worked better with our ROM placement during MVP. A jump table would cost an extra 256 entries × 2B = 512B
- Each handler ends with `JMP advance`, which advances VM_PC by ZOP_SIZE (12) and `JMP main_loop`s

### advance

```asm
advance:
    LDA VM_PC
    CLC
    ADC #ZOP_SIZE         ; = 12
    STA VM_PC
    BCC :+
    INC VM_PC+1
:
    JMP main_loop
```

---

## Jump table (alternative)

256 entries × 2B (lo/hi) = **512B** in ROM.

```asm
.segment "RODATA"
handler_lo:
    .byte <handle_zend_nop      ; 0x00
    .byte <handle_zend_add      ; 0x01
    .byte <handle_unimpl        ; 0x02 (ZEND_SUB, MVP unimplemented)
    ...
    .byte <handle_zend_echo     ; 0x88 (example, ZEND_ECHO=136)
    ...
    .byte <handle_zend_return   ; 0x3e (example)
    ...
    ; The remaining slots all point at handle_unimpl

handler_hi:
    .byte >handle_zend_nop
    ...
```

- All unimplemented opcodes point at `handle_unimpl` (display the opcode number and `UNIMPL` on screen, then halt)
- A ca65 macro like `OP_ENTRY ZEND_ECHO, handle_zend_echo` would help maintenance

### PHP 8.4 opcode hardcoding

For exact opcode numbers, see [04-opcode-mapping](./04-opcode-mapping.md). MVP only needs two (`ZEND_ECHO`, `ZEND_RETURN`).

---

## Operand resolver

Each handler starts by extracting op1/op2 as 4B tagged values into `OP1_VAL` / `OP2_VAL` via shared routines:

```
resolve_op1:
    LDY #ZOP_OP1_TYPE   ; = 9 (op1_type offset)
    LDA (VM_PC),Y
    CMP #0x01           ; IS_CONST
    BEQ resolve_const
    CMP #0x10           ; IS_CV
    BEQ resolve_cv
    CMP #0x02           ; IS_TMP_VAR
    BEQ resolve_tmp
    CMP #0x04           ; IS_VAR
    BEQ resolve_var
    ; IS_UNUSED: store IS_UNDEF in OP1_VAL and return
    ...
```

### IS_CONST resolution

```
; op1.constant lives at zend_op offset 0-3 (4B)
; Treat it as a byte offset into the literals array
LDY #0
LDA (VM_PC),Y            ; A = op1.constant lo
STA TMP0
INY
LDA (VM_PC),Y            ; A = op1.constant mid
STA TMP0+1
; (hi/ext should be 0; ignore)

; literals[] base + TMP0 = address of the zval
CLC
LDA VM_LITBASE
ADC TMP0
STA TMP1
LDA VM_LITBASE+1
ADC TMP0+1
STA TMP1+1

; Load the 4B tagged zval at TMP1 (literals are stored as 4B tagged)
; (type is the low byte of u1.type_info at offset 8)
LDY #8
LDA (TMP1),Y
STA OP1_VAL              ; type ID into OP1_VAL byte 0
; For IS_LONG/IS_STRING, copy the low 2B of value to payload lo/hi
LDY #0
LDA (TMP1),Y
STA OP1_VAL+1            ; payload lo
INY
LDA (TMP1),Y
STA OP1_VAL+2            ; payload hi
RTS
```

### IS_CV resolution

```
; op1.var = CV slot number × 4 (Zend convention)
; The RAM address of slot n is VM_CVBASE + n. Note that the var field carries
; a byte offset directly in many Zend implementations rather than slot/4.
; See 04-opcode-mapping for the exact PHP 8.4 semantics.
LDY #0
LDA (VM_PC),Y            ; op1.var lo (byte offset)
CLC
ADC VM_CVBASE
STA TMP0
LDA #0
ADC VM_CVBASE+1
STA TMP0+1
; TMP0 now holds the RAM address of the CV slot (a 4B tagged value)
; Copy directly into OP1_VAL
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

### Code volume over speed

Specializing every handler for each operand combination (CONST-UNUSED, CV-CONST, CV-CV, ...) would be fast but explode the code size. The MVP **calls `resolve_op1` / `resolve_op2` from every handler** and specializes only after a bottleneck appears.

---

## Example handler: ZEND_ECHO

```asm
handle_zend_echo:
    ; Resolve op1
    JSR resolve_op1

    ; Confirm OP1_VAL.type is IS_STRING (6)
    LDA OP1_VAL
    CMP #6
    BNE echo_type_error

    ; OP1_VAL payload lo/hi is the ROM offset to a zend_string
    LDA OP1_VAL+1
    STA TMP0
    LDA OP1_VAL+2
    STA TMP0+1

    ; Add ROM_BASE (e.g. $8000) to make TMP0 absolute
    CLC
    LDA TMP0
    ADC #<ROM_BASE
    STA TMP0
    LDA TMP0+1
    ADC #>ROM_BASE
    STA TMP0+1

    ; Read len from zend_string offset 16 (2B significant)
    LDY #16
    LDA (TMP0),Y
    STA TMP1             ; len lo
    INY
    LDA (TMP0),Y
    STA TMP1+1           ; len hi

    ; val[] starts at offset 24
    LDA TMP0
    CLC
    ADC #24
    STA TMP0
    BCC :+
    INC TMP0+1
:

    ; Write TMP1 bytes to the PPU nametable
    JSR ppu_write_string_forced_blank

    ; ZEND_ECHO doesn't push (void)
    JMP advance
```

`ppu_write_string_forced_blank` lives in [06-display-io](./06-display-io.md).

---

## Example handler: ZEND_RETURN

```asm
handle_zend_return:
    ; ZEND_RETURN op1 is the return value (ignored in MVP)
    ; Enable PPU and halt

    LDA #%00011110       ; PPUMASK: BG + sprite on
    STA $2001

halt_loop:
    JMP halt_loop        ; Spin forever, NMI handles things
```

In extension goals NMI handles dynamic echo and OAM DMA, so this becomes a `WAI`-equivalent NOP loop.

---

## Unimplemented opcode: handle_unimpl

```asm
handle_unimpl:
    ; Display "UNIMPL <opcode>" on screen and halt
    LDY #20
    LDA (VM_PC),Y        ; A = opcode number
    PHA
    ; ... write the string "UNIMPL " and the opcode number in hex to the nametable
    PLA

    LDA #%00011110
    STA $2001
unimpl_halt:
    JMP unimpl_halt
```

Lets you see at a glance which opcode is missing during debugging.

---

## Reset handler (overview)

```asm
reset:
    SEI                  ; Disable interrupts
    CLD                  ; Decimal mode off
    LDX #$FF
    TXS                  ; Reset stack pointer
    INX
    STX $2000            ; PPUCTRL = 0
    STX $2001            ; PPUMASK = 0 (forced blanking)
    STX $4010            ; Disable DMC

    ; PPU warm-up (wait two VBLs)
    BIT $2002
vblankwait1:
    BIT $2002
    BPL vblankwait1
vblankwait2:
    BIT $2002
    BPL vblankwait2

    ; Clear RAM ($0000-$07FF)
    JSR clear_wram

    ; Load palette
    JSR load_palette

    ; Clear nametable
    JSR clear_nametable

    ; Initialize VM from op_array header
    JSR vm_init_from_op_array

    ; Enter VM main loop (still in forced blanking)
    JMP main_loop
```

`vm_init_from_op_array`:
- Read the op_array header at the ROM head (e.g. `$8000`)
- Pull `num_opcodes`, `literals_off`, `num_literals`, `num_cvs`, `num_tmps`, `php_version`
- If `php_version` ≠ 8.4, halt immediately (error)
- VM_PC = address of op[0]; VM_LITBASE = ROM base + literals_off; VM_SP = `$0300`; VM_CVBASE = `$0400`; VM_TMPBASE = `$0500`
- Initialize CV/TMP slots to IS_UNDEF

---

## Related documents

- [02-ram-layout](./02-ram-layout.md) — Zero-page VM register assignments
- [04-opcode-mapping](./04-opcode-mapping.md) — Status of each opcode
- [06-display-io](./06-display-io.md) — Implementation of `ppu_write_string_forced_blank`
