# 01. L3 ROM Binary Format

[← README](./README.md) | [← 00-overview](./00-overview.md) | [→ 02-ram-layout](./02-ram-layout.md)

This document is **the single source of truth that both the serializer (`serializer.php`) and the 6502 VM consult**. If the spec drifts, the build breaks; always update this file first when something changes.

## Policy

We strip `handler` (8B) and `lineno` (4B) from Zend's internal `zend_op` (32B) and compress each `znode_op` union (4B) down to the lower 2 bytes the VM actually reads. The result is a **12B struct** burned into PRG-RAM. Literals keep Zend's 16B `zval` layout verbatim. The 6502 VM references these via `ZOP_*` constants in `vm/nesphp.s`.

The older 24B layout (preserved Zend offsets, dropped `handler` only) was tight against the ROM size cap (8KB of PRG-RAM bank 0), so we re-compressed to 12B as described in §2.

For "why this shape" and "the 9 deviations from upstream Zend", see [12-zend-diff](./12-zend-diff.md). This file focuses on the **current byte-level strict spec**.

References (upstream definitions):
- [php-src Zend/zend_compile.h](https://github.com/php/php-src/blob/master/Zend/zend_compile.h) — `struct _zend_op`, `union znode_op`, `IS_CONST` etc.
- [php-src Zend/zend_types.h](https://github.com/php/php-src/blob/master/Zend/zend_types.h) — `struct _zval_struct`, `struct _zend_string`
- [php-src Zend/zend_vm_opcodes.h](https://github.com/php/php-src/blob/master/Zend/zend_vm_opcodes.h) — opcode numbers

---

## 1. op_array header (first 16 bytes)

```
offset  size  field               meaning
0       2     num_opcodes         op count
2       2     literals_off        ROM offset of the literals array (relative to op_array start)
4       2     num_literals        literal count
6       2     num_cvs             CV (compiled local) slot count
8       2     num_tmps            TMP slot count
10      1     php_version_major   version-lock check (must be 0x08)
11      1     php_version_minor   version-lock check (must be 0x04)
12      4     (reserved, zero-fill)
```

The 6502 VM reads this header at boot. If `php_version_major/minor` is not 8.4, it halts immediately (with an on-screen error).

---

## 2. zend_op (12B, NESPHP-compressed layout)

A custom layout that drops `handler` (8B) and `lineno` (4B) from Zend's `struct _zend_op` and compresses each `znode_op` union (4B) down to **its lower 2 bytes**. The VM is closed in a 16-bit address space, so the upper 2 bytes of each union are always zero — keeping them is wasteful.

```
offset  size  field              originally Zend           note
0       2     op1                znode_op union → lo 2B    constant / var / num / jmp_offset
2       2     op2                znode_op union → lo 2B
4       2     result             znode_op union → lo 2B
6       2     extended_value     uint32_t       → lo 2B
8       1     opcode             zend_uchar                ★ Zend-compatible numbering ([04-opcode-mapping](./04-opcode-mapping.md))
9       1     op1_type           zend_uchar                see operand type table below
10      1     op2_type           zend_uchar
11      1     result_type        zend_uchar
```

Offset constants are centralized as `ZOP_*` in `vm/nesphp.s`.

### Old layout (24B, pre-migration) — for reference

The naive layout we used while PRG-RAM bank 0 still hosted op_array + literals + STR_POOL + ARR_POOL together:

```
offset  size  field              Zend type                 note
0       4     op1                znode_op union            constant / var / num / jmp_offset
4       4     op2                znode_op union
8       4     result             znode_op union
12      4     extended_value     uint32_t
16      4     lineno             uint32_t                  debug-only
20      1     opcode             zend_uchar
21      1     op1_type           zend_uchar
22      1     op2_type           zend_uchar
23      1     result_type        zend_uchar
```

Old → new diff:
- Drop lineno (offset 16-19) → −4B
- Compress each znode_op 4B → 2B (the upper 2B were always 0) → −8B
- Total 24B → 12B (op_array halves; tetris.php went from 97.8% → 52.8%)
- The VM only references offsets via `ZOP_*` constants, so any future re-compression / expansion is a one-line constant change

### operand type (Zend `IS_CONST` etc., from `Zend/zend_compile.h`)

| Value | Name | Meaning |
|----|------|------|
| 0x00 | IS_UNUSED | Not used |
| 0x01 | IS_CONST | op*.constant is a byte offset into the literals array |
| 0x02 | IS_TMP_VAR | op*.var is a TMP slot number |
| 0x04 | IS_VAR | op*.var is a VAR slot number |
| 0x08 | IS_CV | op*.var is a CV (compiled variable) slot number |

### CONST operand pointer resolution

At Zend runtime `op1.constant` is **a byte offset into the host-memory literals array** (computed in the x64 process). The serializer rewrites it to **a byte offset relative to `literals_off` inside the NES ROM**.

- E.g. Zend's `op1.constant = 0` (first literal) → still `0` in the ROM (literals_off + 0 = literals[0])
- E.g. Zend's `op1.constant = 16` (second literal) → still `16` in the ROM (literals_off + 16 = literals[1])

The "meaning" is preserved; only the "thing it points at" is resolved for the NES side. Zend's literals array uses 16B units — same as the 6502 VM — so the offset is reusable as-is.

### Unsupported opcodes

The serializer hard-fails on unsupported opcodes. On the VM side everything falls back to `handle_unimpl` (display the opcode number on screen and halt).

---

## 3. literals[] (16B zval per element)

Keeps Zend's `struct _zval_struct` 16B layout verbatim:

```
offset  size  field              note
0       8     value union        IS_LONG:   lval (little-endian 8B, low 2B significant)
                                 IS_STRING: str (low 2B = ROM offset, rest zeros)
                                 IS_TRUE/FALSE/NULL: unused
8       4     u1.type_info       low 1B = type ID ([02-ram-layout](./02-ram-layout.md))
12      4     u2                 zero-fill (Zend stores cache slots etc.)
```

### type ID (Zend-compatible, from `zend_types.h`)

| Value | Name | Meaning |
|----|------|------|
| 0 | IS_UNDEF | Undefined |
| 1 | IS_NULL | null |
| 2 | IS_FALSE | false |
| 3 | IS_TRUE | true |
| 4 | IS_LONG | Integer (narrowed to 16-bit) |
| 5 | IS_DOUBLE | **Unsupported** (compile error at the serializer) |
| 6 | IS_STRING | String (offset to a ROM-resident zend_string) |
| 7 | IS_ARRAY | **Unsupported** (same) |
| 8 | IS_OBJECT | **Unsupported** (same) |

---

## 4. zend_string (24B header + content)

**Note**: this section describes the ROM layout for **the L3 (host `serializer.php`) path**. **L3S (the on-NES compiler path, [13-compiler](./13-compiler.md)) does not use zend_string** — string literals embed (ROM offset, length) directly inside the zval value field. See [13-compiler](./13-compiler.md) for L3S details and [12-zend-diff](./12-zend-diff.md) deviation 10 for design intent.

Keeps Zend's `struct _zend_string` head layout:

```
offset  size  field              note
0       4     gc.refcount        0 (immutable)
4       4     gc.type_info       GC_IMMUTABLE-ish (constant like 0x40)
8       8     h                  hash (zero-fill is fine)
16      8     len                low 2B significant, rest zero-fill
24      N     val[len]           ASCII string body
24+len  1     (null terminator)  for Zend C compatibility
```

- **The string body is ASCII-only.** UTF-8 / multi-byte triggers a compile error in the serializer
- Tile placement in CHR-ROM is "tile number = ASCII code", so `val[]` bytes can be written straight to the nametable ([06-display-io](./06-display-io.md))

---

## 5. Concrete hex dump example

Input: `<?php echo "HELLO, NES!";`

New format (12B/op):

```
Offset     Bytes                                             ASCII
---------  ------------------------------------------------  ----------------
00000000   4e 45 53 1a 04 00 10 08 00 00 09 07 00 00 00 00   NES.............   iNES header (NES 2.0, MMC1 / mapper 1, SXROM)
00000010   [ VM 6502 asm ~16KB ... ]                                             PRG bank 0
...
                                                             ↓ op_array section (PRG-RAM bank 0)
00006000   02 00 28 00 02 00 00 00 00 00 08 04 00 00 00 00   ..(.............    op_array header
                                                                                  num_ops=2
                                                                                  literals_off=$0028 (= 16B header + 2 ops × 12B = 40 = $28)
                                                                                  num_literals=2
                                                                                  num_cvs=0, num_tmps=0
                                                                                  php_version=8.4

00006010   00 00 00 00 00 00 00 00 88 01 00 00               ............        op[0] ZEND_ECHO
                                                                                   op1=$0000 (literal[0]),
                                                                                   opcode=0x88=136,
                                                                                   op1_type=CONST(1)

0000601C   10 00 00 00 00 00 00 00 3e 01 00 00               ........>...        op[1] ZEND_RETURN
                                                                                   op1=$0010 (literal[1]),
                                                                                   opcode=0x3e=62,
                                                                                   op1_type=CONST(1)

00003F40   50 3f 00 00 00 00 00 00 06 00 00 00 00 00 00 00   P?..............    literals[0] zval STRING
                                                                                  value.str → $3f50
                                                                                  u1.type = IS_STRING(6)

00003F50   01 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00   ................    literals[1] zval LONG 1
                                                                                  value.lval = 1
                                                                                  u1.type = IS_LONG(4)

00003F60   00 00 00 00 40 00 00 00 00 00 00 00 00 00 00 00   ....@...........    zend_string header
                                                                                  refcount=0,
                                                                                  gc.type_info=IMMUTABLE
                                                                                  hash=0
00003F70   0b 00 00 00 00 00 00 00 48 45 4c 4c 4f 2c 20 4e   ........HELLO, N    len=11, "HELLO, N
00003F80   45 53 21 00                                       ES!.                "ES!\0"
...
00010010   [ PRG bank 1 ($8000-$BFFF when bank 1 mapped) ]                       CHRDATA segment
                  4 × 4KB CHR sets (source for the boot-time bulk transfer)
                  set 0: normal font / set 1: inverse / set 2-3: extension slots
00018010   [ PRG bank 2 (16KB, reserved), PRG bank 3 ($C000-$FFFF, CODE fixed) ]
```

The header `04 00 10 08 00 00 09 07` is **NES 2.0** MMC1 (mapper 1, SXROM): PRG-ROM = 4 × 16KB = 64KB, CHR-ROM = 0 (declares CHR-RAM 8KB), Flags 7 = `08` (bit 2-3 = `10` → NES 2.0 marker), byte 10 = `09` (PRG-RAM = 64 << 9 = 32KB volatile), byte 11 = `07` (CHR-RAM = 64 << 7 = 8KB volatile). High nibble of Flags 6 = 1 → mapper 1.

PRG-RAM 32KB bank assignment: bank 0 = op_array + literals, bank 1 = ARR_POOL, bank 2 = STR_POOL, bank 3 = USER_RAM_EXT. Details in [11-chr-banks](./11-chr-banks.md) and [02-ram-layout § PRG-RAM](./02-ram-layout.md).

**Why NES 2.0 is required**: FCEUX treats iNES 1.0 PRG-RAM size as fixed at 8KB and ignores MMC1 bank switching. Declaring 32KB explicitly via NES 2.0 maps banks 1-3 as physically independent RAM pages.

### Highlights

- The `88` at offset `$3F24` is `ZEND_ECHO` (Zend PHP 8.4.6's value, 136)
- The `3e` at offset `$3F3C` is `ZEND_RETURN` (62)
- `strings hello.nes` finds `HELLO, NES!`
- literals[0]'s `50 3f 00 00` is the resolved offset reference to `$3f50`

---

## 6. Endianness / alignment

- Every field is **little-endian** (matching the 6502)
- Padding: 12B `zend_op` aligns on a 4B boundary
- The 8B union value in zval would prefer 8B alignment, but the 6502 has no alignment requirement, so it isn't strictly needed

---

## Related documents

- [02-ram-layout](./02-ram-layout.md) — the RAM-side representation that consumes this ROM format (4B tagged value)
- [03-vm-dispatch](./03-vm-dispatch.md) — how the 6502 VM reads this layout
- [04-opcode-mapping](./04-opcode-mapping.md) — opcode number list
- [09-verification](./09-verification.md) — how to verify the hex dump above actually appears
