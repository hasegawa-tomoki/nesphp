# 09. Acceptance criteria and romance verification

[← README](./README.md) | [← 08-risks](./08-risks.md)

## MVP acceptance criteria

### Environment

- [ ] `brew install cc65 php` completed
- [ ] `php -v` shows `PHP 8.4.x`
- [ ] `ca65 --version` works

### Build

- [ ] `examples/hello.php` contains `<?php echo "HELLO, WORLD!";`
- [ ] `make` succeeds and produces `build/hello.nes`
- [ ] No errors during `make`

### Intermediate-artifact verification

- [ ] `build/ops.txt` (opcache output) contains:
  ```
  0000 ECHO string("HELLO, NES!")
  0001 RETURN int(1)
  ```
- [ ] The hex dump of `build/host.ops.bin` (host-compile path, `make build/hello.host.ops.bin`) matches the example in [01-rom-format](./01-rom-format.md):
  - op_array header (first 16B): `num_ops=2`, `num_literals=2`, `php_version=8.4`
  - op[0] (12B): `opcode=0x88 (ZEND_ECHO=136)`, `op1_type=0x01 (CONST)` (offset 8-11)
  - op[1] (12B): `opcode=0x3e (ZEND_RETURN=62)`, `op1_type=0x01`
  - literals[0]: `type=0x06 (IS_STRING)`
  - literals[1]: `type=0x04 (IS_LONG)`, `value=1`
  - In L3, a 24B zend_string header + content; in L3S, the zval directly carries (offset, length)
- Note: **The L3S `.nes` does not contain compiled bytecode** (only PHP source; bytecode is generated in PRG-RAM at boot). Verifications 1 and 5 work on the `.nes`; 2-4 require the host-compile path

### Emulator behavior

- [ ] Mesen opens `build/hello.nes` without crashing
- [ ] `HELLO, NES!` appears near the center
- [ ] Replace the string with `"NESPHP WORKS"`, rerun `make`, the display changes to `NESPHP WORKS` (= proves the serializer actually compiles)
- [ ] In Mesen's debugger, the PPU nametable shows ASCII tile numbers at the relevant positions

---

## L3 romance verification (mandatory)

Only when all of these pass can you claim "Zend's emitted opcodes are running on the NES".

### Verification 1: PHP source string lives raw inside the NES ROM

```bash
strings build/hello.nes | grep -i hello
```

Expected:
```
HELLO, NES!
```

**Meaning**: The PHP source string literal is baked into the NES ROM as raw bytes (via Zend's `zend_string`).

### Verification 2: ZEND_ECHO opcode bytes appear (host-compile path only)

```bash
make build/hello.host.ops.bin
xxd -g 1 build/hello.host.ops.bin | grep '88 01 00 00'
```

Expected: at least one match.

**Meaning**: Zend's `ZEND_ECHO` (number 0x88) and operand type bytes (`op1_type=IS_CONST=0x01`) are baked into the op_array (in the new 12B layout, offset 8-11 is the opcode + 3 type bytes). **The L3S `.nes` itself has no compiled bytecode**, so verify via the host-compile path.

### Verification 3: ZEND_RETURN opcode bytes appear (host-compile path only)

```bash
xxd -g 1 build/hello.host.ops.bin | grep '3e 01 00 00'
```

Expected: at least one match.

### Verification 4: literals' 16B zval layout is Zend-compatible (host-compile path only)

The 16B zval layout survives only in the host oracle `.host.ops.bin` — the L3S on-NES compiler emits 4B tagged literals into PRG-RAM instead ([13-compiler](./13-compiler.md)).

```bash
make build/hello.host.ops.bin
xxd build/hello.host.ops.bin | sed -n '3,5p'
```

Expected (literals_off = 0x28):
```
00000020: 00 00 00 00 3e 01 00 00 48 00 00 00 00 00 00 00  ....>...H.......
00000030: 06 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00  ................
00000040: 04 00 00 00 00 00 00 00 00 00 00 00 40 00 00 00  ............@...
```

- literal 0 starts at 0x28: `48 00 00 00 ...` = `value` (offset 0x48 of the ROM-resident `zend_string`), and `06 00 00 00` at zval offset 8 = the low byte of `u1.type_info` is `IS_STRING(6)`
- literal 1 starts at 0x38: `01 00 00 00 00 00 00 00` = `value.lval = 1`, `04 00 00 00` = `IS_LONG(4)`

These are **Zend-compatible 16B zval layouts** verbatim.

### Verification 5: changing the string changes the ROM

```bash
# Original
strings build/hello.nes | grep HELLO

# Change the string and rebuild
sed -i '' 's/HELLO, NES!/NESPHP WORKS/' examples/hello.php
make

strings build/hello.nes | grep -E 'HELLO|NESPHP'
# → NESPHP WORKS
```

Proves the serializer is actually replacing the literal.

---

## Phase 2 (custom Zend extension) acceptance criteria

- [ ] `phpize && ./configure && make` succeeds in `nesphp_dump/`
- [ ] `nesphp_dump.so` is produced
- [ ] `php -dzend_extension=./nesphp_dump/modules/nesphp_dump.so examples/hello.php > build/ops_direct.bin` succeeds
- [ ] `diff build/ops.bin build/ops_direct.bin` is byte-equal (or only intentional diffs)
- [ ] Even after deleting the text-parser layer in serializer.php, `build/hello.nes` builds with the same content
- [ ] `spec/05-toolchain.md` is updated to the extension-based flow

---

## Acceptance criteria for shipped demos

All build with `make build/NAME.nes` and run in Mesen.

### Stage 1: integers + locals (`arith.nes`) ✅

`examples/arith.php`:
```php
<?php
$a = 1;
$a = $a + 2;
echo $a;
```

- [x] Mesen displays `3`
- [x] `xxd -g 1 build/arith.nes | grep '01 08 01 02'` finds ZEND_ADD (0x01) + op1_type=IS_CV + op2_type=IS_CONST + result_type=IS_TMP_VAR
- [x] `xxd -g 1 build/arith.nes | grep '16 08 01 00'` finds ZEND_ASSIGN (0x16)

### Stage 2: control flow (`loop.nes`) ✅

`examples/loop.php`:
```php
<?php
$i = 0;
while ($i < 5) {
    echo $i;
    $i = $i + 1;
}
```

- [x] Mesen displays `01234`
- [x] `xxd -g 1 build/loop.nes | grep '2a 00 00 00'` finds ZEND_JMP (0x2A)
- [x] `xxd -g 1 build/loop.nes | grep '2c 02 00 00'` finds ZEND_JMPNZ (0x2C) + op2_type=IS_UNUSED
- [x] `xxd -g 1 build/loop.nes | grep '14 08 01 02'` finds ZEND_IS_SMALLER (0x14)

### Stage 4: controller input (`button.nes`) ✅

`examples/button.php`:
```php
<?php
echo "Press: ";
$k = fgets(STDIN);
echo $k;
```

- [x] Mesen shows `Press: `
- [x] Pressing A/B/Start/Select/U/D/L/R appends the corresponding character
- [x] `xxd -g 1 build/button.nes | grep 'f0 00 00 04'` finds NESPHP_FGETS (0xF0) + result_type=IS_VAR
- [x] fgets's `INIT_FCALL / FETCH_CONSTANT / SEND_VAL` are folded to NOP (0x00)

### Stage 5A: tile-character motion (`move.nes`) ✅

`examples/move.php`:
```php
<?php
$x = 16;
$y = 14;
nes_put($x, $y, "X");
while (true) {
    $k = fgets(STDIN);
    nes_put($x, $y, " ");
    if ($k === "L") $x = $x - 1;
    if ($k === "R") $x = $x + 1;
    if ($k === "U") $y = $y - 1;
    if ($k === "D") $y = $y + 1;
    nes_put($x, $y, "X");
}
```

- [x] `X` displays at the screen center
- [x] D-pad moves `X` one tile at a time (erase old + redraw new)
- [x] `xxd -g 1 build/move.nes | grep 'f1 08 08 00'` finds NESPHP_NES_PUT (0xF1)
- [x] `xxd -g 1 build/move.nes | grep '10 08 01 02'` finds ZEND_IS_IDENTICAL (0x10)

### Stage 5B: hardware sprite (`sprite.nes`) ✅

`examples/sprite.php`:
```php
<?php
$x = 120;
$y = 120;
nes_sprite_at(0, $x, $y, 65);
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 2;
    if ($k === "R") $x = $x + 2;
    if ($k === "U") $y = $y - 2;
    if ($k === "D") $y = $y + 2;
    nes_sprite_at(0, $x, $y, 65);
}
```

- [x] `A` (tile 65) shows as a sprite at the screen center
- [x] D-pad moves the sprite smoothly by 2 pixels
- [x] `xxd -g 1 build/sprite.nes | grep 'f2 08 08 00'` finds NESPHP_NES_SPRITE (0xF2)
- [x] The NMI handler runs OAM DMA ($4014) every VBlank

### Stage 5C: presentation (`slides.nes`) ✅

`examples/slides.php`:
```php
<?php
$p = 0;
while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;
    if ($p === 7) { $p = 1; }
    if ($p === 1) { nes_cls(); nes_puts(4, 4, "NESPHP PRESENTATION"); }
    if ($p === 2) { nes_puts(4, 7, "1. PHP ON FAMICOM"); }
    if ($p === 3) { nes_puts(4, 9, "2. ZEND OPCODE ON 6502"); }
    if ($p === 4) { nes_puts(4, 11, "3. L3 ROM LAYOUT"); }
    if ($p === 5) { nes_puts(4, 13, "4. ROMAN OVER UTILITY"); }
    if ($p === 6) { nes_puts(4, 16, "PRESS ANY KEY TO RESET"); }
}
```

- [x] Each press appends one slide line
- [x] On the sixth press the screen clears and redraws from the title
- [x] `strings build/slides.nes` finds every slide string (`NESPHP PRESENTATION` etc.)
- [x] `xxd -g 1 build/slides.nes | grep 'f3 01 01 00'` finds NESPHP_NES_PUTS (0xF3, op1/op2=IS_CONST)
- [x] `xxd -g 1 build/slides.nes | grep 'f4 00 00 00'` finds NESPHP_NES_CLS (0xF4, no args)

### Stage 3: NMI synchronous writes (`livetext.nes`) ✅

`examples/livetext.php`: a demo that calls nes_puts / nes_put while in sprite_mode. The sprite moves with the D-pad, and pressing A appends "HIT!" one row at a time.

- [x] Build succeeds, ROM size 65552 bytes
- [x] `nes_puts(3, $row, "HIT!")` invoked while in sprite_mode reflects on screen with each A press
- [x] The `X` sprite keeps moving with the D-pad (NMI is doing OAM DMA every frame)
- [x] Mixing sprite motion and HIT! writes never garbles the screen
- [x] `xxd -g 1 build/livetext.nes | grep 'f3 01 08 00'` finds NESPHP_NES_PUTS (op1=IS_CONST x=3, op2=IS_CV $row)
- [x] Mesen's PPU viewer shows NMI queue entries at `$0300-$03FF` briefly after pressing A

### Stage 3.1: nes_cls inside sprite_mode (`livereset.nes`) ✅

`examples/livereset.php`: cycles slides via `nes_cls()` while sprite_mode is active. A press clears the screen and runs the next slide's `nes_puts`, looping over 3 slides.

- [x] Build succeeds, ROM size 65552 bytes
- [x] Initial display "PHASE 3.1: CLS DEMO" + sprite `X` appears
- [x] D-pad moves the sprite (still in sprite_mode)
- [x] A press triggers a 1-2 frame black flash → the next slide displays
- [x] Mashing A loops slides while preserving sprite position
- [x] No screen corruption (via brief force-blanking)
- [x] `xxd -g 1 build/livereset.nes | grep 'f4 00 00 00'` finds NESPHP_NES_CLS

### Stage 5D: CHR bank + pattern-table switch (`chrdemo.nes`) ✅

`examples/chrdemo.php`: each button press advances a state machine that calls `nes_chr_bg(0/1)` and `nes_chr_spr(0/2)` in sequence; the same text shows as normal → inverse → normal, then the sprite side switches to CHR set 2 and back.

- [x] Build succeeds, ROM size 65552 bytes (16 + 32KB PRG + 32KB CHR)
- [x] `xxd -g 1 -l 16 build/chrdemo.nes` shows `02 04 30 00` (PRG=2, CHR=4, Flags6=0x30=mapper 3)
- [x] `xxd -g 1 build/chrdemo.nes | grep 'f5 01 00 00'` finds NESPHP_NES_CHR_BANK (0xF5)
- [x] `xxd -g 1 build/chrdemo.nes | grep 'f6 01 00 00'` finds NESPHP_NES_CHR_BG (0xF6)
- [x] Mesen's PPU viewer shows font tiles in both pattern table 0 and 1
- [x] Mesen's mapper viewer shows banks 0-3 (initially all copies of bank 0)
- [x] Existing examples (hello/arith/loop/button/move/sprite/slides) still build and run after the CNROM bump

### Stage 5E: palette + attribute + custom tiles (`color.nes`) ✅

`examples/color.php`: a colorful presentation demo using all three palette intrinsics (nes_bg_color / nes_palette / nes_attr) and a custom tile (the Japanese flag).

- [x] Build succeeds, ROM size 65552 bytes
- [x] `xxd -g 1 build/color.nes | grep 'f7 01 00 00'` finds NESPHP_NES_BG_COLOR (0xF7, op1=IS_CONST)
- [x] `xxd -g 1 build/color.nes | grep 'f8 01 01 01'` finds NESPHP_NES_PALETTE (0xF8, op1/op2/result=IS_CONST)
- [x] `xxd -g 1 build/color.nes | grep 'f9 01 01 00'` finds NESPHP_NES_ATTR (0xF9, op1/op2=IS_CONST)
- [x] Mesen displays colorful text on a black background (red title, white body, green emphasis, cyan footer)
- [x] The Japanese flag (2×2 = 16×16 px custom tile) renders correctly (red disc on white)
- [x] Mesen's PPU palette viewer shows BG palettes 0-3 with distinct color sets

---

## Real-hardware verification (optional)

- [ ] Load `build/hello.nes` into an Everdrive N8 Pro or compatible flash cart
- [ ] The same display as Mesen
- [ ] No real-hardware-only bugs (PPU timing, DPCM, etc.)

---

## Related documents

- [07-roadmap](./07-roadmap.md) — Implementation step ordering
- [01-rom-format](./01-rom-format.md) — Expected hex dump layout
- [08-risks](./08-risks.md) — Risks the verification aims to detect
