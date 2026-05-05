# 07. Roadmap (implementation steps)

[← README](./README.md) | [← 06-display-io](./06-display-io.md) | [→ 08-risks](./08-risks.md)

## Progress summary

| Phase | Artifact | Status |
|---|---|---|
| MVP: echo only | `hello.nes` | ✅ **Done** |
| Extension stage 1: integers + variables | `arith.nes` | ✅ **Done** |
| Extension stage 2: control flow | `loop.nes` | ✅ **Done** |
| Extension stage 4: controller input | `button.nes` | ✅ **Done** |
| Extension stage 5A: nametable character motion | `move.nes` | ✅ **Done** |
| Extension stage 5B: hardware sprite motion | `sprite.nes` | ✅ **Done** |
| Extension stage 5C: presentation `nes_puts` / `nes_cls` | `slides.nes` | ✅ **Done** |
| Extension stage 5D: CNROM + PPUCTRL bit 4 CHR switching | `chrdemo.nes` | ✅ **Done** |
| Extension stage 3: NMI-synchronous echo / nes_put / nes_puts | `livetext.nes` | ✅ **Done** |
| Extension stage 3.1: nes_cls in sprite_mode (brief force-blanking) | `livereset.nes` | ✅ **Done** |
| Extension stage 5E: palette + attribute + custom tiles | `color.nes` | ✅ **Done** |
| Phase 2: custom Zend extension | `nesphp_dump.so` | Not started |
| Multi-sprite support | — | Not started (currently sprite 0 only) |

---

## L3S (on-NES compiler) parallel track ([13-compiler](./13-compiler.md))

Since 2026-04 we've spun up a separate track that **burns PHP source into ROM and lets the NES itself lex/parse/codegen**. It exists independently of the host-compile track (above); today the default build (`make build/X.nes`) is L3S, and `make build/X.host.ops.bin` is the host oracle.

| Phase | Content | Artifact | Status |
|---------|------|--------|------|
| M-A' | Lexer (incl. `<?php`) + `echo "..."` + new string mechanism | `hello.nes` (self-hosted) | ✅ **Done** |
| P1 | 6 intrinsics + integer literals + standalone fgets | `presen.nes` | ✅ **Done** |
| P2 | CV + assign + `+ -` + on-screen error display | `arith.nes` (self-hosted), `err_syntax.nes` | ✅ **Done** |
| P3 (M-C) | `while { }` + `if { }` + `===/!==/==/!=/<` + `$k = fgets(STDIN)` + `true` + backpatch | `loop.nes`, `button.nes`, `iftest.nes` (self-hosted) | ✅ **Done** |
| P4 | Comments (`// # /* */`), non-ASCII bytes inside string literals (UTF-8 Japanese etc.) pass through | `comments.nes` | ✅ **Done** |
| Q1-Q4 | Remaining 3 intrinsics (nes_put / nes_sprite (1-sprite version, later expanded by W1 to nes_sprite_at) / nes_attr), hex literals, `++` / `--` (PRE/POST INC/DEC), `for` loop, single-statement `if` / `while` bodies | `move.nes` `sprite.nes` `livetext.nes` `livereset.nes` `color.nes` `for.nes` | ✅ **Done** |
| R1 | `nes_vsync()` + `nes_btn($mask)` (early version, mask AND scheme) | — | ✅ **Done** |
| R2 | `nes_btn()` becomes 0-arg, returns the controller state as IS_LONG | `poll.nes` | ✅ **Done** |
| R3 | Bitwise operators `&` `\|` (ZEND_BW_AND/OR), binary literals `0b..` | `bintest.nes` | ✅ **Done** |
| **All examples passing** | All **18 examples in this repo run on-NES self-host** (err_syntax intentionally verifies compile-error path) | — | ✅ **Done** |
| W1 | Multi-sprite: `nes_sprite_at($idx, $x, $y, $tile)` (4 args, runtime-int $idx), `nes_sprite_attr($idx, $attr)` (palette / flip / priority). NESPHP_NES_SPRITE (0xF2) made arbitrary-OAM-index, NESPHP_NES_SPRITE_ATTR (0xFC) added | Migrate existing `sprite.nes` `livetext.nes` `livereset.nes` `poll.nes` to nes_sprite_at, add `multi.nes` | ✅ **Done** |
| W2 | `nes_rand()` / `nes_srand($seed)` (16-bit Galois LFSR, period 65535). Found and fixed the ASSIGN_DIM bug in the `$xs[$i] = $xs[$i] + 1` pattern (parse RHS before emitting ASSIGN_DIM) | `random.nes` (8 sprites random walk) | ✅ **Done** |
| W3 | Parser extension: `else` / `elseif` chains, `<=` / `>` / `>=`, parenthesized expressions `(expr)`. Includes a latent bug fix for `cmp_parse_expr` saving/restoring CMP_LHS / CMP_INTRINSIC_ID | `elsetest.nes` `parentest.nes` | ✅ **Done** |
| W4 | `nes_putint($x, $y, $value)`: 5-char right-justified unsigned int display (HUD score). Goes through the NMI sync queue in sprite_mode | `putint.nes` `score.nes` | ✅ **Done** |
| W5 | Arithmetic operator extensions `*` / `/` / `%` (signed 16-bit, divide-by-0 falls back to 0). Introduced `parse_mul_expr` for proper precedence. Also fixed the negative-number X-clobber bug in print_int16 | `multest.nes` | ✅ **Done** |
| W6 | `nes_peek` / `nes_peek16` / `nes_poke` / `nes_pokestr`: byte-level data access in USER_RAM ($0700-$07FF, 256B; reuses the post-compile CV table region). Avoids the 16B/entry zval overhead so a 28-rotation Tetris shape table fits in 56 bytes | `peek_test.nes`, `tetris.nes` (Phase 5b) | ✅ **Done** |
| **Tetris Phase 5b** | 7 piece types + 4 rotations + line clears + score + simple game over. **peek/poke + USER_RAM** holds the shape table at low overhead. Fixed several bugs uncovered during compile (16-bit-ize CV/TMP slot resolution / reset TMP_COUNT between statements / op_array bound check / positive mask `& 0x7FFF` for `nes_rand % N`) | `tetris.nes` | ✅ **Done** |
| W7 | **SXROM-spec compliance** (PRG-ROM 64KB / CHR-RAM 8KB / PRG-RAM 32KB). The 8KB CHR-RAM is bulk-transferred from PRG_BANK1 at boot (~50 ms); `nes_chr_bg/spr` switched to bulk transfer. ARR_POOL escapes to bank 1, growing 720B → 8KB (11×). New 4 intrinsics `nes_peek_ext / peek16_ext / poke_ext / pokestr_ext` provide 8KB of USER_RAM_EXT (initially bank 2; relocated to bank 3 by W8) | `peekext_test.nes`, `tetris.nes` (Phase 5c) | ✅ **Done** |
| **Tetris Phase 5c** | Full repaint after line clear (single-loop: clear with `nes_put(' ')` first → overlay only the cells that need `\x05`) and on-screen GAME OVER. The ARR_POOL expansion finally gave op_array enough room | `tetris.nes` | ✅ **Done** |
| W8 | **STR_POOL bank 2** (128B → 8KB, 64×). Resolved the tetris title corruption / `color.php` ERR L78 C27 caused by string-literal overflow. Migrated **iNES → NES 2.0 header** so FCEUX honors PRG-RAM banking. USER_RAM_EXT moved to bank 3 | `color.nes`, all `tetris.nes` paths, smoke 40/41 | ✅ **Done** |
| Next | Tetris Phase 5d (NEXT preview / speed up) / `!` / unary `-` / `^` (BW_XOR) / `foreach` / APU intrinsic (nes_beep) / cross-bank op_array dispatch (when op_array > 8KB) | — | Not started |
| Out of scope | Associative arrays, objects, exceptions, doubles | — | L3 policy |

The design rationale and stumbling blocks per phase are recorded in [10-devlog](./10-devlog.md).

## MVP (display `echo "HELLO, NES!";` on the NES)

### Step 1: repo skeleton

Create the following directories:

```
nesphp/
  spec/         Spec docs (this folder)
  extractor/    Shell wrapper for opcache dump
  serializer/   serializer.php and composer.json
  vm/           nesphp.s (ca65) and nesphp.cfg
  chr/          font.chr
  examples/     hello.php etc.
  build/        Intermediate artifacts and .nes (gitignored)
  Makefile      One-command build (make / make clean / make verify)
  README.md     Project description (with the 3-layer diagram)
```

### Step 2: Bare NES Hello World (no PHP yet)

First make a `.nes` in ca65 that statically displays `HELLO WORLD`. At this stage:

- PPU init / palette / nametable clear ([06-display-io](./06-display-io.md))
- iNES header / NROM mapper / reset vector
- Build font.chr (CHR-ROM) and place it
- Establish the `ca65 + ld65` build
- Confirm `HELLO WORLD` displays in Mesen

Template: [bbbradsmith/NES-ca65-example](https://github.com/bbbradsmith/NES-ca65-example)

**Why isolate this step**: standing up the NES build infrastructure before PHP is involved makes later debugging much easier.

### Step 3: Verify the opcache dump

```bash
cat > examples/hello.php <<'EOF'
<?php echo "HELLO, NES!";
EOF

php -dopcache.enable_cli=1 -dopcache.opt_debug_level=0x10000 \
    examples/hello.php 2> build/ops.txt > /dev/null

cat build/ops.txt
```

Expected output:
```
$_main:
     ; (lines=2, ...)
0000 ECHO string("HELLO, NES!")
0001 RETURN int(1)
```

Record the PHP version (`php -v` for 8.4.x) in the verified-versions section of `spec/README.md`.

### Step 4: Freeze the L3 format

`spec/01-rom-format.md` is the single source of truth for the implementation. Lock the spec at this step so both serializer and VM consult only that file.

### Step 5: Serializer v0

Implement the MVP-minimum in `serializer/serializer.php`:

- Parse `ops.txt`, support only ZEND_ECHO and ZEND_RETURN, only `string("...")` and `int(N)` literals
- Emit `ops.bin` based on `spec/01-rom-format.md` and `spec/04-opcode-mapping.md`
- Hardcode numbers like ZEND_ECHO=0x88 (=136), ZEND_RETURN=0x3e (=62) from PHP 8.4's `zend_vm_opcodes.h`
- Abort if PHP version isn't 8.4

Test: `hexdump -C build/ops.bin` matches the hex dump example in `spec/01-rom-format.md`.

### Step 6: VM loop (ca65)

Translate the design from `spec/03-vm-dispatch.md` straight into `vm/nesphp.s`:

- Zero-page VM_PC / VM_SP / VM_LITBASE / VM_CVBASE / VM_TMPBASE
- 256-entry jump table (unimplemented entries point at handle_unimpl)
- Implement only `handle_zend_echo` and `handle_zend_return`
- `resolve_op1` / `resolve_op2` generic operand resolvers
- `ppu_write_string_forced_blank` writes to the nametable
- At boot, read the op_array header and check php_version, halt on mismatch

### Step 7: Integrated build

Connect (1) extract → (2) serialize → (3) assemble → (4) link as a `Makefile` pattern rule ([05-toolchain](./05-toolchain.md)).

```bash
make                     # Default: build/hello.nes
make build/foo.nes       # examples/foo.php → build/foo.nes
make verify              # L3 romance verification
make clean               # Remove build/
```

### Step 8: Verify in Mesen

Open `build/hello.nes` and confirm `HELLO, NES!` shows.

### Step 9: Romance verification

Run the "L3 romance verification" section in `spec/09-verification.md`:

- `strings build/hello.nes | grep HELLO` → finds `HELLO, NES!`
- `xxd build/hello.nes | grep '88 01 00 00'` → finds the ZEND_ECHO byte sequence
- `xxd build/hello.nes | grep '3e 01 00 00'` → finds the ZEND_RETURN byte sequence

That marks **MVP complete**.

### Step 10 (Phase 2): custom Zend extension `nesphp_dump.so`

- Write `nesphp_dump/config.m4` and `nesphp_dump/nesphp_dump.c` (~300 lines of C)
- Call `zend_compile_file()`, walk the `zend_op_array*` directly, emit binary that matches `spec/01-rom-format.md`
- Delete the text parser layer in serializer.php and use the extension output
- Confirm byte-equality with the text path
- Final form: "the PHP engine emits `zend_op`, the extension binary-encodes it, the 6502 interprets it directly" — peak romance

---

## Extension goals (post-MVP)

### Stage 1: integers + locals

New opcodes:
- `ZEND_ASSIGN`, `ZEND_ADD`, `ZEND_SUB`, `ZEND_IS_SMALLER`

```php
<?php
$a = 1;
$a = $a + 1;
echo $a;
```

Goal: get this running. Uses 1 CV slot (`$0400`) and 2-3 VM stack entries.

### Stage 2: control flow

New opcodes:
- `ZEND_JMP`, `ZEND_JMPZ`, `ZEND_JMPNZ`
- `ZEND_IS_EQUAL`, `ZEND_IS_NOT_EQUAL`

```php
<?php
$i = 0;
while ($i < 10) {
    echo "X";
    $i = $i + 1;
}
```

Goal: get this running. The serializer resolves `ZEND_JMP`'s `op1.jmp_offset` to a NES ROM op index.

### Stage 3: dynamic echo (NMI sync) ✅ Done

`echo` was forced-blanking-only after step 2; the NMI-synchronous write queue (`$0300-$03FF` 256B ring buffer) now lets `echo` / `nes_put` / `nes_puts` work transparently in sprite_mode.

Implementation: see "NMI-synchronous write queue" in [06-display-io](./06-display-io.md). Design history: Phase 3 in [10-devlog](./10-devlog.md). `examples/livetext.php` demos dynamic text drawing while sprites move.

Open issue: `nes_chr_bank` / `nes_chr_bg` still tear (CHR-switch commands will be added to the NMI queue later).

### Stage 3.1: nes_cls in sprite_mode ✅ Done

The 1024B clear of `nes_cls` doesn't fit a single VBlank, so the NMI sync queue can't handle it. We use a **brief force-blanking** approach: temporarily set `PPUMASK = 0` + disable NMI to stop rendering, clear, then re-enable rendering on the next VBlank. The visible effect is a 1-2 frame black flash that reads naturally as a slide transition. `examples/livereset.php` demos slide clear + repaint while sprites are visible.

### Stage 4: stdin = controller

Use `fgets(STDIN)` in PHP; the serializer folds the `INIT_FCALL "fgets"` pattern into `BUILTIN_READ_INPUT` and the VM reads `$4016` from the controller.

```php
<?php
while (true) {
    $k = fgets(STDIN);
    if ($k === "A") echo "A";
}
```

Goal: get this running.

### Stage 5: sprites

The serializer folds the built-in `nes_sprite_set($id, $x, $y, $tile)` and the VM writes to the OAM shadow + does OAM DMA in NMI.

```php
<?php
$x = 120;
$y = 120;
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 1;
    if ($k === "R") $x = $x + 1;
    if ($k === "U") $y = $y - 1;
    if ($k === "D") $y = $y + 1;
    nes_sprite_set(0, $x, $y, 0xA0);
}
```

This satisfies the README's extension goal ("move on-screen text or sprites with the controller").

### Stage 6: bank switching (if needed)

If PRG-ROM exceeds 32KB, promote to UxROM with VM in the fixed bank and op_array/literals in the switched bank.

---

## Schedule sense

| Stage | Effort |
|---------|------|
| MVP (steps 1-9) | 1-2 weeks |
| Phase 2 (custom extension) | A few days |
| Stage 1 (integers + variables) | 1 week |
| Stage 2 (control flow) | 1 week |
| Stage 3 (dynamic echo) | A few days |
| Stage 4 (controller) | A few days |
| Stage 5 (sprites) | 1 week |

Total: 2-3 months to clear all extension goals (assuming ~10 hours/week as a weekend project).

---

## Related documents

- [09-verification](./09-verification.md) — Acceptance criteria per step
- [08-risks](./08-risks.md) — Risks you may hit at each stage
- [05-toolchain](./05-toolchain.md) — Build pipeline details
