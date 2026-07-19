# 00. Project Overview

[← README](./README.md)

## Goal

This project is **romance, not utility**. The whole goal is "running on a Famicom (6502) the very Zend opcodes that our `php` command actually emitted".

## Definition of success

- Feed the toolchain a `.php` containing `<?php echo "HELLO, NES!";` and out comes a `.nes`
- Mesen boots that ROM and prints `HELLO, NES!` on screen
- `strings hello.nes` finds `HELLO, NES!` (PHP source string lives raw inside the NES ROM)
- In L3S, the PHP source itself is burned into the ROM, and the on-NES compiler builds `zend_op`s in PRG-RAM at boot. The compiled bytecode is **not** present in the ROM (the L3 host-compile path's oracle `make build/X.host.ops.bin` does bake it though)

Detailed acceptance criteria: [09-verification](./09-verification.md).

## 3-layer architecture

```
[Host (macOS)]                                  [Target (NES)]
 input.php
   │
   ▼  ★ This is the real php command
 php -dopcache.enable_cli=1
     -dopcache.opt_debug_level=0x10000 ...
   │  (Phase 2: a custom extension nesphp_dump.so)
   ▼
 Zend opcode dump (text or binary)
   │
   ▼  serializer.php : Zend op_array → L3 ROM binary
   │    - Pack zend_op into 12B (drop handler / lineno, compress each znode_op 4B→2B)
   │    - Lay literals out as 16B zval array (Zend-compatible)
   │    - Lay zend_string out as 24B header + content
   │    - Resolve CONST offsets to NES-ROM-relative offsets
 ops.bin (L3 ROM image)
   │
   ▼  ca65 + ld65 (.incbin "ops.bin")
 nesphp.nes ──────────────────────────▶  6502 VM
                                          - Advance PC to op[i]
                                          - Branch on opcode byte (jump table)
                                          - Switch operand interpretation by op1_type
                                          - CONST → literals[] → zend_string → PPU
```

### Layer responsibilities

| Layer | Role |
|----|------|
| Layer 0 (Zend) | The real php compiles the PHP source officially and emits `zend_op_array`. **Zero modifications** |
| Layer 1 (extract) | Pull `zend_op_array` out via opcache text dump (MVP) or a custom extension (Phase 2) |
| Layer 2 (serializer) | Pack the Zend layout for the NES ROM: pointer resolution + handler removal + version lock. **The byte layout stays Zend-compatible** |
| Layer 3 (6502 VM) | ca65 assembly. Branch on the opcode byte, interpret operands by op1_type / op2_type |

Details: [05-toolchain](./05-toolchain.md).

### L3S (self-hosted) variant

**L3S folds host-side layers 0-2 into the NES side**. PHP source is burned into the ROM as raw text; at power-on the 6502 itself runs lex/parse/codegen:

```
[Host (macOS)]                                  [Target (NES)]
 input.php
   │
   ▼ tools/pack_src.php (~15 lines, super thin)
   │    Just prepends a u16 length
 input.src.bin
   │
   ▼ ca65 + ld65
   │    Burns src.bin into .segment "PHPSRC"
 output.nes ────────────────────────────▶  reset
                                              │
                                              ▼ compile_and_emit (6502)
                                              │  - lex <?php echo "..." ;
                                              │  - emit 12B zend_op / 4B tagged zval
                                              │    (no zend_string struct; the zval
                                              │     directly carries (STR_POOL offset, length))
                                              │
                                              ▼ VM main_loop runs it
```

Layers 0-2 collapse into `vm/compiler.s` on the NES side. Why we drop `zend_string` and the byte-level spec live in [13-compiler](./13-compiler.md) and [12-zend-diff](./12-zend-diff.md) deviation 10.

## Fidelity levels: L3 / L3S

| Level | Description | Adopted? |
|------|------|------|
| L1 | Translate to a custom nesphp-bc. Opcode numbers, operand encoding, zval — all custom | × (insufficient romance) |
| **L3** | **Burn `zend_op` into ROM in NESPHP-compressed form (12B: drop handler/lineno + compress each znode_op 4B→2B). Keep literals as Zend-compatible 16B zval. The 6502 VM reads Zend field offsets directly**. The host-side `serializer.php` compiles PHP source into opcodes and bakes them into ROM | **○** (host-compile path) |
| **L3S** | **Evolution of L3. PHP source goes into ROM raw; the 6502 lex/parse/codegens at boot, emitting 4B tagged zval literals into PRG-RAM. The `zend_string` struct is dropped — (STR_POOL offset, length) is embedded directly in the zval**. Details: [13-compiler](./13-compiler.md) | **○** (self-hosted, default of `make build/X.nes`) |
| L4 | L3 + 16B zval lives in RAM, full 64-bit IS_LONG | × (2KB RAM is not enough) |

L3 and L3S **coexist**. The host-side `serializer.php` stays as a verification oracle (`make build/X.host.ops.bin`); its 16B-literal output is an op-sequence oracle only — since the 4B literal migration the VM's resolvers no longer read the 16B layout, so no Makefile target bakes it into a `.nes`. Details: [01-rom-format](./01-rom-format.md), [02-ram-layout](./02-ram-layout.md), [13-compiler](./13-compiler.md).

## What we don't do (consciously dropped)

These are physically or implementation-cost prohibitive, so the serializer hard-fails as soon as it sees them:

- **Arrays (`HashTable`)**: 56B + 36B per bucket — won't fit in Famicom RAM
- **Objects**: contain a `HashTable`, same blocker
- **`double` (IEEE 754)**: softfloat routines run 1-2KB — better off without
- **Full 64-bit `IS_LONG`**: **narrow to 16-bit**, the serializer rejects out-of-range literals at compile time
- **Exception handling / generators / closures**
- **A custom bytecode via nikic/php-parser**: ruins the romance; not adopted

## Prior art

- [Ice-Forth](https://github.com/RussellSprouts/ice-forth) — A self-hosted Forth on the NES. ~6000 lines of 6502. The L3 nesphp VM at ~1200 lines is firmly within reason
- [Family BASIC](https://en.wikipedia.org/wiki/Family_BASIC) — Nintendo's official NES BASIC. Concrete proof that BASIC ran in 2KB RAM + cartridge RAM

## What to read next

→ [01-rom-format](./01-rom-format.md): ROM binary format (Zend-compatible layout details)
