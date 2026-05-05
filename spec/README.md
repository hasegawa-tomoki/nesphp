# nesphp spec

> 日本語版は [`./ja/README.md`](./ja/README.md) を参照。

A PHP VM that runs on the 6502 (Famicom / NES), executing Zend opcodes that the actual `php` command emitted. Romance over utility.

## Verified versions

- **PHP: 8.4.x** (version lock required, rationale in [05-toolchain](./05-toolchain.md))
- **Mapper: MMC1 (mapper 1, SXROM-equivalent)**, PRG-ROM 64KB (4 × 16KB) + CHR-RAM 8KB + PRG-RAM 32KB (4 × 8KB), NES 2.0 header. Details in [11-chr-banks](./11-chr-banks.md)
- cc65: `brew install cc65`
- Dev host: macOS (NTS x64 PHP build assumed)
- Emulator: fceux (`make run:NAME` to launch, override with `EMULATOR=`)

## Contents

| # | File | Topic |
|---|---|---|
| 0 | [00-overview](./00-overview.md) | Project policy, 3-layer architecture, why L3, what we don't do |
| 1 | [01-rom-format](./01-rom-format.md) | L3 ROM binary format (Zend-compatible), hex dump example |
| 2 | [02-ram-layout](./02-ram-layout.md) | WRAM map, zero page, 4B tagged value |
| 3 | [03-vm-dispatch](./03-vm-dispatch.md) | 6502 VM fetch-dispatch design, jump table |
| 4 | [04-opcode-mapping](./04-opcode-mapping.md) | Zend opcode → handler table (MVP + extensions) |
| 5 | [05-toolchain](./05-toolchain.md) | Extraction, serializer, build pipeline |
| 6 | [06-display-io](./06-display-io.md) | PPU display, controller input, sprites |
| 7 | [07-roadmap](./07-roadmap.md) | MVP / extension goals roadmap |
| 8 | [08-risks](./08-risks.md) | Major risks and mitigations |
| 9 | [09-verification](./09-verification.md) | Acceptance criteria and romance verification |
| 10 | [10-devlog](./10-devlog.md) | Per-phase design decisions and stumbles (chronological) |
| 11 | [11-chr-banks](./11-chr-banks.md) | MMC1 SXROM + CHR-RAM, CHR tile assignments (font / Tetris pieces / brick wall) |
| 12 | [12-zend-diff](./12-zend-diff.md) | Zend originals (`zend_op` / `zval` / `zend_string` / `zend_op_array`) and 10 nesphp deviations |
| 13 | [13-compiler](./13-compiler.md) | On-NES compiler (L3S: PHP source compiled by 6502 at boot) — single source of truth |

## Reading order

For first-time reading: `00-overview` → `01-rom-format` → `09-verification` covers design intent → reality → success criteria. To start implementing, also read `02-ram-layout`, `03-vm-dispatch`, `07-roadmap`.
