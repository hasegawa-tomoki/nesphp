# 02. RAM Layout and 4B Tagged Value

[← README](./README.md) | [← 01-rom-format](./01-rom-format.md) | [→ 03-vm-dispatch](./03-vm-dispatch.md)

The L3 host-serializer ROM format preserves the Zend-compatible 16B zval ([01-rom-format](./01-rom-format.md)), but **everything the live VM touches is 4B**: the on-NES compiler (L3S, the default path) emits literals into PRG-RAM already narrowed to 4B tagged, and all RAM slots (stack / CV / TMP / ARR_POOL) hold 4B tagged values. We need this to honor the "2KB RAM, no heap" constraint.

## Policy

- ROM (L3 host oracle, `.host.ops.bin`): Zend-compatible 16B zval (faithful)
- PRG-RAM literals (L3S): 4B tagged zval, layout `[v0, v1, v2, type]` (narrowed at compile time; the type ID is still Zend-compatible)
- RAM (stack / CV / TMP): 4B tagged value
- No dynamic allocation. Every slot lives at a fixed offset

## WRAM map ($0000-$07FF, 2KB)

```
$0000-$007F  Zero page: VM registers (PC/SP/LITBASE/CVBASE/TMP etc.)
             + L3S compiler workspace (CMP_* family, only alive during compile)
$0080-$00FF  Zero page: controller state, NMI scratch, transient TMP
$0100-$01FF  6502 hardware stack (256B)
$0200-$02FF  OAM shadow (256B; for extended goals; unused in MVP)
$0300-$03FF  VM data stack (4B × 64 entries = 256B)
$0400-$04FF  CV slots (4B × up to 64 entries = 256B)
$0500-$05FF  TMP slots (4B × up to 64 entries = 256B)
$0600-$06FF  Text-row buffer / CONCAT scratch
             (during compile: print_int16 sink, used by error display)
$0700-$07FF  Compile-time: CV symbol table (4B × up to 64 = 256B)
             Runtime: USER_RAM (256B generic byte area for peek/poke)
```

The L3S on-NES compiler runs only briefly right after power-on; the VM runtime takes over afterward. Compile-time and runtime **share WRAM through temporal separation**. Details: [13-compiler](./13-compiler.md), section "WRAM sharing contract".

### 2KB total usage

- The MVP doesn't need to fill the stacks / CV / TMP. `examples/hello.php` runs with **a 1-deep VM data stack and zero CV/TMP**
- Extension goals (`while ($i < 10) { ... }`) use 1-2 CV, 2-4 TMP, 2-3 deep VM stack
- 64-deep VM stack + 32 CV + 64 TMP totals 640B, ~30% of the RAM budget

---

## Zero-page VM registers (implemented)

Putting them on the zero page lets us use `LDA (zp),Y` indirection and `LDX zp` immediates — fastest on the 6502. Declared with `.res` in `.segment "ZEROPAGE"`, ld65 places them automatically. Current layout:

| label | size | purpose |
|---|---|---|
| `VM_PC` | 2 | ROM address of the current zend_op (fetch source) |
| `VM_LITBASE` | 2 | ROM address of the literals array (= OPS_BASE + literals_off) |
| `VM_CVBASE` | 2 | RAM address of the CV slot array (= $0400) |
| `VM_TMPBASE` | 2 | RAM address of the TMP slot array (= $0500) |
| `PPU_CURSOR` | 2 | nametable write position (absolute PPU address based on $2000) |
| `OP1_VAL` | 4 | 4B tagged value resolve_op1 writes |
| `OP2_VAL` | 4 | 4B tagged value resolve_op2 writes |
| `RESULT_VAL` | 4 | 4B tagged value handlers write back via write_result |
| `TMP0` | 2 | General-purpose 16-bit work register |
| `TMP1` | 2 | General-purpose 16-bit work register |
| `TMP2` | 2 | General-purpose 16-bit work register |
| `DIV_COUNTER` | 1 | (reserved, unused) |
| `buttons` | 1 | Controller state (bit 7=A, 6=B, ..., 0=R) |
| `pi_count` | 1 | Bytes that `print_int16` emitted (echo_long uses it to advance PPU_CURSOR) |
| `sprite_mode_on` | 1 | State flag: `0 = forced_blanking` / `1 = sprite_mode` |

Total ~34 bytes — about 13% of the 256B ZP budget, with plenty of headroom remaining.

---

## 4B tagged value layout

```
byte 0: type ID    (Zend-compatible)
byte 1: payload lo
byte 2: payload hi
byte 3: payload ext (meaning depends on type, see table below)
```

### type ID (compatible with Zend `zend_types.h`)

| Value | Name | byte 1-2 meaning | byte 3 meaning |
|----|------|----------------|----------------|
| 0 | IS_UNDEF | 0 | 0 |
| 1 | IS_NULL | 0 | 0 |
| 2 | IS_FALSE | 0 | 0 |
| 3 | IS_TRUE | 0 | 0 |
| 4 | IS_LONG | **16-bit signed integer** | 0 (reserved for future sign extension) |
| 5 | IS_DOUBLE | **Unsupported** | — |
| 6 | IS_STRING | 16-bit OPS_BASE-relative offset to val[] | **L3S: string length (low 1B)**, L3: 0 |
| 7 | IS_ARRAY | **Unsupported** | — |
| 8 | IS_OBJECT | **Unsupported** | — |

**L3 (host serializer path)**: For IS_STRING, byte 1-2 is the offset to a ROM-resident `zend_string` struct. Length is read from offset 16 of `zend_string`. byte 3 unused (0).

**L3S (on-NES compiler path, [13-compiler](./13-compiler.md))**: For IS_STRING, byte 1-2 is the offset to val[] (raw bytes) in ROM. Length lives in byte 3 (255B cap). No `zend_string` struct.

### Narrowing rules (L3 host-serializer 16B format)

| ROM-side (16B zval) | RAM-side (4B tagged) |
|---|---|
| `IS_LONG` (8B lval) in -32768..32767 | Narrow to 16-bit |
| `IS_LONG` out of range | Compile error at the serializer (never seen at runtime) |
| `IS_STRING` value low 2B | Copy to bytes 1-2 (ROM offset) |
| `IS_STRING` value offset 2 (L3S only) | Copy to byte 3 (length) |
| `IS_TRUE/FALSE/NULL` | Copy only the type ID, payload is zero |

### Who narrows?

- **L3 host path**: the host serializer writes Zend-compatible 16B zvals into ROM (`.host.ops.bin`) and never narrows ahead of time, following the L3 policy of "ROM keeps Zend's layout as-is".
- **L3S (current default)**: the on-NES compiler narrows **at compile time** — literals land in PRG-RAM as 4B tagged `[v0, v1, v2, type]` (for IS_STRING: v0-v1 = STR_POOL offset, v2 = length). The VM's `resolve_op1` / `resolve_op2` read them as-is (type at offset 3, see [03-vm-dispatch](./03-vm-dispatch.md)); no fetch-time narrowing remains.

---

## Data stack ($0300-$03FF)

4B tagged value × 64 entries = 256B. `VM_SP` uses `$0300` as the bottom and `$03FF+1` as the cap, growing downward (or upward; choice TBD).

**Recommended**: grow upward. `push` = `STA ($02),Y : INY ×4`. Bottom at `$0300`, full at `$0400`.

### push/pop macros

```asm
; push A/X/Y (type/lo/hi) onto VM stack
.macro PUSH_LXH
    LDY #0
    STA (VM_SP),Y       ; type
    INY
    TXA
    STA (VM_SP),Y       ; lo
    INY
    TYA                 ; (reuse A)
    STA (VM_SP),Y       ; hi
    INY
    LDA #0
    STA (VM_SP),Y       ; ext
    LDA VM_SP
    CLC
    ADC #4
    STA VM_SP
    BCC :+
    INC VM_SP+1
:
.endmacro
```

(Pseudocode; align with [03-vm-dispatch](./03-vm-dispatch.md) for the actual implementation.)

---

## CV slots and TMP slots

- **CV** (`$0400-$04FF`): Zend's "compiled local variables". PHP's `$a`, `$b` etc. get assigned slot numbers. The serializer emits `num_cvs` in the op_array header; if the VM detects an out-of-range slot it panics
- **TMP** (`$0500-$05FF`): Zend's `IS_TMP_VAR` / `IS_VAR`. Short-lived intermediates

### Access

```
CV slot n  →  $0400 + n*4  
TMP slot n →  $0500 + n*4  
```

Each is one 4B tagged value. Maximum slot count is 64 (= 256B / 4).

### 16-bit slot resolution (important)

The `op.var` field in `zend_op` carries **`slot * 16`** as a 16-bit value (Zend convention). The VM divides by 4 to get `slot * 4` (the RAM offset).

**When slot ≥ 16**, `slot*16 ≥ 256` and a single byte can't hold it, so the resolution must be 16-bit. `vm/nesphp.s`'s `cv_addr_y` / `tmp_addr_y` helpers consolidate this calculation; res_cv / res_tmp / wr_cv / wr_tmp / assign_to_cv / incdec_cv_addr all go through them.

---

## USER_RAM ($0700-$07FF, 256B, runtime only)

After L3S compile finishes, the CV symbol table is no longer needed, so we reuse those 256B as a **generic byte region for peek/poke**.

| Use case | Example |
|---|---|
| Large constant tables | Tetris bulk-loads its 28-rotation shape table (56-byte string) via `nes_pokestr(0, $data)` |
| Game-state raw byte storage | `nes_poke(64, $byte)` / `$x = nes_peek(64)` |
| 16-bit tables | `nes_peek16($ofs)` reconstructs a little-endian 2-byte value |

**Why**: arrays (`$a = [...]`) carry 4-byte tagged-zval overhead per element (plus a 4B header per array), so byte-grained large data (like a 56-byte 28-entry shape table) still costs ~2× the memory and lives behind ARR_POOL bank switching. USER_RAM lets you do byte-level access with zero overhead in always-mapped internal RAM.

Details: [04-opcode-mapping § peek/poke](./04-opcode-mapping.md), [13-compiler](./13-compiler.md).

---

## PRG-RAM ($6000-$7FFF, SXROM 4 banks × 8KB = 32KB)

The cartridge's 32KB of PRG-RAM is multiplexed into an 8KB window ($6000-$7FFF) via bank switching. MMC1's `$A000` register bits 2-3 select the PRG-RAM bank (in CHR-RAM mode, bits 0-1 are no-ops). The ZP byte `cur_prg_ram_bank` tracks the current bank.

**iNES header requirement**: FCEUX honors bank switching only if the **NES 2.0 header** declares 32KB of PRG-RAM (Flags 7 bit 2-3 = `10`, byte 10 = `$09`). With an iNES 1.0 header, it treats PRG-RAM as a fixed 8KB and aliases banks 1-3 onto bank 0. Details: [01-rom-format § iNES header](./01-rom-format.md).

### Bank assignments

| bank | role | switch timing |
|---|---|---|
| **0** (default) | header + op_array + literals + CMP_LIT_STAGE | Always mapped during the dispatch loop |
| **1** | ARR_POOL 8KB (arrays only) | Atomic switch at array-handler entry/exit |
| **2** | STR_POOL 8KB (string literal pool) | Atomic switch in handlers that read strings / `cln_string` |
| **3** | USER_RAM_EXT 8KB (peek/poke_ext) | Atomic switch inside `nes_*_ext` intrinsics |

### Bank 0 contents (current 8KB layout)

```
$6000-$600F  header (16 B)
$6010-...    op_array (12B × num_ops, max ~617 op)
...-$7CFF    literals (memcpy'd right after op_array, 4B tagged zval each)
$7D00-$7FFF  CMP_LIT_STAGE (768 B, compile-only — free post-compile)
```

Compressing zend_op from 24B → 12B (drop lineno + compress each znode_op 4B→2B; spec/01) doubled the op cap from ~308 to ~617. tetris.php (op_array 6.1KB) went from 97.8% bank-0 occupancy to ~83%, restoring headroom.

### Bank 1 (ARR_POOL only)

```
$6000-$7FFF  ARR_POOL (8 KB, append-only growth, no GC)
```

Old 720B (split-shared inside bank 0) → 8 KB (dedicated). **About 11×** larger. Removed the memory pressure for array-heavy patterns like tetris's full repaint.

### Bank 2 (STR_POOL only)

```
$6000-$7FFF  STR_POOL (8 KB, string literal pool)
```

Old 128B (in bank 0, `$7F80-$7FFF`) → 8KB. **About 64×** larger. `cln_string` writes the bytes decoded from `\xHH` escapes here, and IS_STRING zvals carry the STR_POOL offset (OPS_BASE-relative, 0..$1FFF). At runtime, handlers that read strings (`echo` / `nes_put` / `nes_puts` / `nes_pokestr` / `nes_pokestr_ext` stage 1 / string equality) atomically swap bank 2 ↔ bank 0 around their access.

### Bank 3 (USER_RAM_EXT)

```
$6000-$7FFF  USER_RAM_EXT (8 KB, generic byte region)
```

Read/write via `nes_peek_ext` / `nes_peek16_ext` / `nes_poke_ext` / `nes_pokestr_ext`. 13-bit offsets (0-8191) — far larger than internal-RAM `nes_peek/poke` (256B). Since the source of `nes_pokestr_ext` (STR_POOL = bank 2) and the destination (USER_RAM_EXT = bank 3) cannot be mapped simultaneously, it uses a 2-stage copy through internal RAM `$0600-$06FF`.

### Bank-switching cost

MMC1 serial writes are 5 STA + 4 LSR = ~30 cycles. Switching at entry and exit is **~60 cycles per intrinsic call**. Even tetris-style scenarios that hit string and array handlers heavily slow down only ~10% (acceptable).

Details: [13-compiler § PRG-RAM bank layout](./13-compiler.md), [04-opcode-mapping § ext intrinsic](./04-opcode-mapping.md).

---

## Related documents

- [01-rom-format](./01-rom-format.md) — ROM-side 16B zval layout
- [03-vm-dispatch](./03-vm-dispatch.md) — How operand resolvers consume this layout
- [04-opcode-mapping](./04-opcode-mapping.md) — Slots used by each opcode
