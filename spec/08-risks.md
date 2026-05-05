# 08. Major risks and mitigations

[← README](./README.md) | [← 07-roadmap](./07-roadmap.md) | [→ 09-verification](./09-verification.md)

## Risk catalog

| # | Risk | Impact | Mitigation |
|---|--------|------|--------|
| 1 | Zend opcode numbers shifting between PHP versions | Serializer-emitted binaries don't run | Version-lock to PHP 8.4. Parse the `(PHP X.Y.Z)` line at the top of opcache dumps and abort the serializer on mismatch. The VM verifies `php_version_major/minor` from the op_array header at boot |
| 2 | `zend_op` layout shifts with PHP build settings (ZTS/NTS, 32/64-bit, debug/release) | The 12B compressed layout breaks | Support **only NTS x64 PHP 8.4 release builds** (macOS `brew install php`). Documented in `spec/README.md` |
| 3 | 2KB RAM is too small | VM exhausts RAM early | Concentrate VM registers on the zero page, zero dynamic allocation, fixed RAM map per [02-ram-layout](./02-ram-layout.md). 16B zvals only in ROM; RAM keeps a narrowed 4B tagged form |
| 4 | PHP 64-bit ints, doubles, arrays, objects | Can't honor semantics | **Drop them**. IS_LONG narrows to 16-bit; doubles/arrays/objects abort the serializer. Listed in [00-overview](./00-overview.md) "What we don't do" |
| 5 | Variable-length strings and GC | Need heap management | MVP keeps `zend_string` immutable, ROM-only. When `ZEND_CONCAT` lands, use a single fixed 256B buffer (no GC) ([06-display-io](./06-display-io.md)) |
| 6 | Tempted to implement all 200+ Zend opcodes | Implementation explodes | MVP locks itself to 2 opcodes; extensions cap at ~20. Anything else falls back to handle_unimpl ([04-opcode-mapping](./04-opcode-mapping.md)) |
| 7 | opcache text-dump format drifts between PHP releases | Serializer parser breaks | After MVP, promote to the custom `nesphp_dump.so` extension and kill the text parser. Until then, keep the regex loose-coupled |
| 8 | PPU timing (writes mid-render glitch the screen) | Screen glitches | MVP writes only during forced blanking (`$2001=0`). Extensions promote to VBlank transfer ([06-display-io](./06-display-io.md)) |
| 9 | DPCM controller glitch | Sporadic input corruption | Use NESdev Wiki's retry-equipped read routine as-is |
| 10 | Zend is a register machine, 6502 is bare-metal | Translation logic gets tangled | Handlers call `resolve_op1/op2` resolvers based on op1_type/op2_type — fetch any operand kind through one path. Code volume over speed |
| 11 | Custom extension breaks on PHP ABI updates | Phase 2 needs rebuilding | Compile-time guard via `PHP_API_VERSION`. Document the verified PHP version in `nesphp_dump/README.md` |
| 12 | Bank switching needed? | Anything > 32KB doesn't run | NROM 32KB suffices for MVP. If extensions overflow, promote to UxROM (VM in fixed bank, op_array in switched bank) |
| 13 | Real hardware vs. emulator drift | Won't run on hardware | Mainly debug in Mesen (high accuracy), final-check on FCEUX and Everdrive |
| 14 | Non-ASCII characters in PHP source | Don't fit in NES font, garbled | Serializer detects non-ASCII literals and aborts |
| 15 | Zend TMP_VAR / VAR / CV offset interpretation drifts between PHP versions | Operand resolver breaks | Implement the resolver in `spec/03-vm-dispatch.md` against PHP 8.4; version lock rejects others |
| 16 | String pool exceeds PRG-ROM capacity | Build fails | Serializer checks size and aborts on overflow. Promote to UxROM in the future |
| 17 | 6502 16-bit math is slow (`ZEND_MUL` etc.) | Real-time breaks down | Implement multiply/divide last; skip divide if necessary |

---

## Drilling into the highest-priority risks

### Strict PHP version-locking

The biggest risk in this project isn't **"code written for PHP 8.3 doesn't run on 8.4"** kinds of interop problems — it's **"the 8.4 build was working until 8.5 renumbered opcodes"**.

#### Defense in depth

1. **Serializer-side**: invoke `php -v` from within and abort if not 8.4
2. **opcache dump parser**: check the `(PHP X.Y.Z)` comment line at the top of the dump
3. **VM-side (ROM)**: check `php_version_major/minor` in the op_array header at boot, halt screen on mismatch
4. **Documentation**: stated in the verification line of `spec/README.md`. CI should pin 8.4.x

### Walking the 2KB RAM tightrope

The RAM map in [02-ram-layout](./02-ram-layout.md) has slack through MVP + extension stage 1, but extension stage 5 (sprites) makes the 256B OAM shadow mandatory. Going further (arrays etc.) is guaranteed to break.

**Policy**: **never** implement arrays. Express patterns instead with "PHP using multiple variables" and "function-call-based hardware control".

### Unsupported-opcode UX

When a user writes `echo [1, 2, 3];` with arrays, we make sure the failure point is unambiguous:

1. The serializer detects `ZEND_INIT_ARRAY`
2. Compile error as an unsupported opcode: `hello.php:1: unsupported opcode ZEND_INIT_ARRAY (arrays are not supported in nesphp)`
3. Build aborts

We never let "build passes but doesn't run on NES" happen.

---

## Risks we accept

These are **risks we don't fix** (to preserve the romance):

- **Useless for production**: most PHP features are missing, so it's pointless for web work
- **No speed**: interpreted on a 6502 — about 1000 opcodes per second. ~10 million× slower than serious PHP
- **PHP's deeper semantics (type juggling etc.) aren't reproduced**: only the minimum needed

They're accepted under the "this is a joke project" premise.

---

## Related documents

- [00-overview](./00-overview.md) — Detailed list of "What we don't do"
- [02-ram-layout](./02-ram-layout.md) — Concrete budget for the 2KB RAM
- [05-toolchain](./05-toolchain.md) — How PHP version-locking is implemented
- [09-verification](./09-verification.md) — Tests that detect each risk
