# nesphp

> 日本語版は [`./README-ja.md`](./README-ja.md) を参照。

A PHP VM that ships PHP source straight onto a Famicom (6502) and **lets the NES itself compile and execute it**. Romance over utility.

- **L3S (self-hosted)**: PHP source is burned raw into the ROM. At power-on the 6502 lex/parse/codegen → emits NESPHP-compressed `zend_op 12B` / 4B tagged zval literals into PRG-RAM → existing VM executes. **This is the only path that produces a `.nes`**
- **L3 (host-compile) is oracle-only**: `serializer.php` is still alive. `make build/NAME.host.ops.bin` produces a 12B opcode binary used to cross-check L3S output (op sequence only — its literals are still 16B zvals, which the VM's resolvers no longer read since the 4B tagged zval migration), and no Makefile target bakes it into a `.nes`
- **Mapper**: MMC1 (mapper 1, SXROM-equivalent) — **PRG-ROM 64KB (4 × 16KB) + CHR-RAM 8KB + PRG-RAM 32KB (4 × 8KB)**, NES 2.0 header
- **Verified on**: PHP 8.4 (version-locked) + cc65 + fceux/Mesen + real hardware (EverDrive N8 + red-and-white Famicom)

Detailed design lives under [`spec/`](./spec/) (TOC: [`spec/README.md`](./spec/README.md)). The romance is that **knowledge of PHP syntax exists only on the NES side**.

---

## Quick start

```bash
# Deps: PHP 8.4, cc65 (brew install cc65), fceux (brew install fceux)
make                      # Default: build/hello.nes
make build/poll.nes       # Any examples/NAME.php → build/NAME.nes
make run:hello            # Build + launch in fceux
make run:poll              # Run any example by name
make clean
```

`make run:NAME` covers **build → emulator launch in a single command**. Override the emulator with `make run:hello EMULATOR=other_emu`.

### Build pipeline (L3S, the default)

```
[host]
  examples/foo.php
      │
      ▼  tools/pack_src.php  (just prepends a u16 length, ~15 lines)
  build/foo.src.bin
      │
      ▼  ca65 + ld65  (.incbin into the .segment "PHPSRC")
  build/foo.nes
      │
      ▼  Power on (NES side)
  reset → compile_and_emit (vm/compiler.s)
        │  lex → parse → emit 12B zend_op / 4B tagged zval
        ▼
  op_array assembled in PRG-RAM bank 0 ($6000-$7FFF) → main_loop runs it
```

The host side does nothing more than "prepend u16 length + check the 16382B size cap". Content (including non-ASCII bytes inside string literals or comments) passes through transparently — the NES lexer reads them. `<?php` tags and string literals stay raw in the ROM, so **`vm/compiler.s` on the NES is the single PHP parser**.

When you need an L3 (host-compile) oracle, `make build/foo.host.ops.bin` produces a Zend-compatible opcode binary (used to cross-check L3S output; not baked into `.nes`). Details: [`spec/05-toolchain.md`](./spec/05-toolchain.md) and [`spec/13-compiler.md`](./spec/13-compiler.md).

---

## What you can write in PHP

### Supported PHP subset

| Category | Coverage |
|---|---|
| Integer literals | Decimal / hex `0x..` / binary `0b..`, narrowed to 16-bit signed (`-32768..32767`) |
| Arrays | Integer keys only: `$a = [1,2,3]` literal (nested OK: `[[1,2],[3,4]]`), `$a[i]` read (chainable: `$a[i][j]`), `$a[i] = v` write, `$a[] = v` push, `count($a)`. `foreach` / associative arrays unsupported. 8KB pool (PRG-RAM bank 1, 4B tagged zval per element), **shared-pointer semantics** (`$b = $a; $b[0]=99;` propagates to `$a[0]`) |
| Strings | Double-quoted literals only, no concatenation (`.`). Non-ASCII bytes pass through, supports `\xHH` / `\\` / `\"` escapes. Decoded bytes live in STR_POOL (PRG-RAM bank 2, 8KB) |
| Variables | CV / TMP / VAR slots, `$a = ...` / `$a = $b + 1` |
| Arithmetic | `+` / `-` / `*` / `/` / `%` (16-bit signed, divide-by-zero falls back to 0) |
| Bitwise | `&` / `\|` / `<<` / `>>` (16-bit; `>>` is arithmetic right shift) |
| Logical | `&&` / `\|\|` (short-circuit; result is IS_LONG 0 or 1) |
| Comparison | `===` / `!==` / `==` / `!=` / `<` / `<=` / `>` / `>=` (`===` and `==` share an implementation; `>` / `>=` fold to `<` / `<=` via operand swap) |
| Increment | `$x++` / `$x--` / `++$x` / `--$x` (statement and expression positions) |
| Parens | `(expr)` overrides precedence |
| Control flow | `if` / `if-else` / `if-elseif-else` / `while` / `while(true)` / `for (init; cond; upd)` with single-statement bodies |
| Comments | `//` / `#` / `/* */` (non-ASCII OK) |
| Output | `echo` (works transparently in forced_blanking and through the NMI sync queue in sprite_mode) |
| Input (legacy) | `fgets(STDIN)` → 1-character string for the pressed button (blocking) |
| Input (modern) | `nes_btn()` (zero args, returns current state as a bitmask) + `nes_vsync()` |
| Functions | **Intrinsics only** (table below); no user-defined functions |

The full grammar EBNF and token list are in [`spec/13-compiler.md`](./spec/13-compiler.md).

### What we don't do (intentionally)

Associative arrays (string keys) / `foreach` / objects / exceptions / generators / closures / doubles / 64-bit ints / string concatenation (`.`) / dynamic string construction / user-defined functions / unary `-` / `!` / `^` (BW_XOR). See "What we don't do" in [`spec/00-overview.md`](./spec/00-overview.md) and the constraints section in [`spec/13-compiler.md`](./spec/13-compiler.md).

---

## Intrinsic table

The on-NES compiler folds named function calls (`INIT_FCALL + SEND_* + DO_*` sequences) into a single custom opcode.

| Function | Args | Behavior | Opcode |
|---|---|---|---|
| `echo $v` | IS_STRING / IS_LONG | Output to nametable at the current cursor | `ZEND_ECHO` 136 (0x88) |
| `fgets(STDIN)` | — | Returns the pressed controller button as a 1-char string (`"A"/"B"/"S"/"T"/"U"/"D"/"L"/"R"`), blocking | 0xF0 |
| `nes_put($x, $y, $c)` | int, int, char literal or runtime int | Place 1 character (tile number) at nametable (x, y) | 0xF1 |
| `nes_puts($x, $y, "str")` | int, int, string literal | Write a string starting at nametable (x, y) (no wrap, len ≤255) | 0xF3 |
| `nes_cls()` | — | Fill nametable 0 ($2000-$23FF) with spaces and reset cursor | 0xF4 |
| `nes_sprite_at($idx, $x, $y, $tile)` | int, int, int, int literal | Update OAM[$idx] (0-63) y / tile / x (does not touch attr). First call enables rendering + NMI | 0xF2 |
| `nes_sprite_attr($idx, $attr)` | int, int | Set the attribute byte for OAM[$idx]. bit 0-1=palette / bit 5=priority / bit 6=hflip / bit 7=vflip | 0xFC |
| `nes_chr_bg($n)` | int literal 0-3 | Copy 4KB CHR set $n from PRG-ROM (CHRDATA) into the BG pattern table (CHR-RAM $0000) | 0xF6 |
| `nes_chr_spr($n)` | int literal 0-3 | Copy 4KB CHR set $n from PRG-ROM (CHRDATA) into the sprite pattern table (CHR-RAM $1000) | 0xF5 |
| `nes_bg_color($c)` | int literal 0x00-0x3F | Set the universal background color (PPU $3F00) | 0xF7 |
| `nes_palette($id, $c1, $c2, $c3)` | 4 int literals | Set palette colors 1-3. id 0-3 = BG, 4-7 = sprite | 0xF8 |
| `nes_attr($x, $y, $pal)` | int, int, int (runtime OK, clamped to 0-3) | BG attribute table: assign palette index per 2×2 tile (16×16 px) block | 0xF9 |
| `nes_vsync()` | — | Spin until the next VBlank (NMI). Auto-enables sprite_mode if not already on | 0xFA |
| `nes_btn()` | — | Returns the current controller state as IS_LONG (low byte = bitmask: A=0x80, B=0x40, Sel=0x20, Start=0x10, U=0x08, D=0x04, L=0x02, R=0x01) | 0xFB |
| `nes_rand()` | — | Advance a 16-bit Galois LFSR by one step, return IS_LONG. Mask before use (`nes_rand() & 0x3F` etc.) | 0xFD |
| `nes_srand($seed)` | int | Set the LFSR state to $seed. $seed = 0 is replaced by 1 internally (avoids the degenerate state) | 0xFE |
| `nes_putint($x, $y, $value)` | int, int, int | Write a **5-char right-justified unsigned int** to nametable (x, y) (HUD score). Range 0..65535 | 0xFF |
| `nes_peek($offset)` | int 0-255 | USER_RAM[$offset] → IS_LONG (byte) | 0xEC |
| `nes_peek16($offset)` | int 0-255 | USER_RAM[$offset \| ($offset+1)<<8] → IS_LONG (16-bit LE) | 0xED |
| `nes_poke($offset, $byte)` | int, int | USER_RAM[$offset] = $byte (low byte only) | 0xEE |
| `nes_pokestr($offset, $string)` | int, string | Bulk-copy raw string bytes to USER_RAM[$offset..] | 0xEF |
| `nes_peek_ext($offset)` | int 0-8191 | Read 1 byte from USER_RAM_EXT (PRG-RAM bank 3, 8KB) | 0xE8 |
| `nes_peek16_ext($offset)` | int 0-8190 | Read 2 LE bytes from USER_RAM_EXT | 0xE9 |
| `nes_poke_ext($offset, $byte)` | int, int | USER_RAM_EXT[$offset] = byte | 0xEA |
| `nes_pokestr_ext($offset, $string)` | int, string | Bulk-copy raw string bytes to USER_RAM_EXT (via internal RAM staging) | 0xEB |

USER_RAM ($0700-$07FF, 256B) is a generic byte region in internal RAM, four times more compact than array elements (4B tagged zval each, plus a 4B header per array). USER_RAM_EXT (PRG-RAM bank 3, 8KB) is for larger tables / grids (e.g. the locked-cell tile grids in the tetris examples). Details in [`spec/02-ram-layout.md § USER_RAM`](./spec/02-ram-layout.md).

Opcode rationales and folding patterns: [`spec/04-opcode-mapping.md`](./spec/04-opcode-mapping.md). `nes_chr_*` details: [`spec/11-chr-banks.md`](./spec/11-chr-banks.md). Input API usage: [`spec/06-display-io.md`](./spec/06-display-io.md).

### Real-time input pattern

```php
<?php
$x = 120; $y = 120;
nes_sprite_at(0, $x, $y, 88);
while (true) {
    nes_vsync();                     // 60fps pacing
    $b = nes_btn();                  // Current button bitmask
    if ($b & 0b00000010) { $x = $x - 1; }  // Left
    if ($b & 0b00000001) { $x = $x + 1; }  // Right
    if ($b & 0b00001000) { $y = $y - 1; }  // Up
    if ($b & 0b00000100) { $y = $y + 1; }  // Down
    nes_sprite_at(0, $x, $y, 88);
}
```

### Rendering state constraints

Display intrinsics have two modes:

- **forced_blanking** (initial): `echo` / `nes_put` / `nes_puts` / `nes_cls` write the nametable directly. Rendering is briefly turned ON only while `fgets` waits for input
- **sprite_mode** (after the first `nes_sprite_at`): rendering is always ON, the NMI handler runs OAM DMA every VBlank. The **Phase 3 NMI sync write queue** lets `echo` / `nes_put` / `nes_puts` work transparently (actual PPU writes are deferred to the next VBlank). `nes_cls` uses the **Phase 3.1 brief force-blanking** path (a 1-2 frame black flash transition)

Once you enter sprite_mode you cannot leave. Typical pattern: "intro `echo` → `nes_sprite_at` to enter the game loop (sprites + dynamic text + slide transitions can coexist)". See [`spec/06-display-io.md`](./spec/06-display-io.md). Coexistence demos: `examples/livetext.php` and `examples/livereset.php`.

---

## Bundled examples

| File | What it does | Features used |
|---|---|---|
| [`examples/hello.php`](./examples/hello.php) | Display `HELLO, NES!` | `echo` |
| [`examples/arith.php`](./examples/arith.php) | Display the result of 16-bit integer arithmetic | CV/TMP, `+` `-` |
| [`examples/loop.php`](./examples/loop.php) | Print `01234` | `while`, `<`, 16-bit comparison |
| [`examples/iftest.php`](./examples/iftest.php) | Verify `if` + comparisons | `if`, `===`, `!==`, single-statement bodies |
| [`examples/for.php`](./examples/for.php) | `for` loop + `++` / `--` | `for`, `PRE_INC`, `POST_INC`/`DEC` |
| [`examples/comments.php`](./examples/comments.php) | All of `//` `#` `/* */` are accepted | Comment parser |
| [`examples/bintest.php`](./examples/bintest.php) | Mixed binary / hex / decimal + `&` `\|` | `0b..`, `0x..`, bitwise |
| [`examples/logtest.php`](./examples/logtest.php) | `&&` `\|\|` `<<` `>>` behavior | Short-circuit, shift |
| [`examples/strescape.php`](./examples/strescape.php) | `"\xHH"` / `"\\"` / `"\""` escapes | Arbitrary byte embedding (custom tile indices) |
| [`examples/arrtest.php`](./examples/arrtest.php) | Array literal + `$a[i]` + `count($a)` + `for` | `ZEND_INIT_ARRAY` / `ZEND_FETCH_DIM_R` / `ZEND_COUNT` |
| [`examples/arrwrite.php`](./examples/arrwrite.php) | `$a[i]=v` / `$a[]=v` / nested `[[1,2],[3,4]]` / `$m[i][j]` | `ZEND_ASSIGN_DIM` + `ZEND_OP_DATA`, FETCH_DIM_R chain |
| [`examples/button.php`](./examples/button.php) | Display the pressed button character (blocking) | `fgets(STDIN)` |
| [`examples/poll.php`](./examples/poll.php) | Move `X` continuously with the D-pad at 60fps | `nes_vsync` + `nes_btn` + `&` |
| [`examples/move.php`](./examples/move.php) | Move `X` per tile with the D-pad | `nes_put`, `===` |
| [`examples/sprite.php`](./examples/sprite.php) | Move `A` per pixel with the D-pad | `nes_sprite_at`, NMI |
| [`examples/multi.php`](./examples/multi.php) | 8 sprites moving in tandem with different colors | `nes_sprite_at` (runtime $idx), `nes_sprite_attr`, `nes_palette` |
| [`examples/random.php`](./examples/random.php) | 8 sprites doing a random walk (LFSR-driven directions) | `nes_rand`, `nes_srand`, array self-reference |
| [`examples/elsetest.php`](./examples/elsetest.php) | `else` / `elseif` chains, `<=` / `>` / `>=`, parenthesized expressions | Parser extension W3 |
| [`examples/score.php`](./examples/score.php) | HUD where the score increments by 7 every second while a sprite moves | `nes_putint`, sprite_mode + NMI sync putint |
| [`examples/tetris.php`](./examples/tetris.php) | Full Tetris v1 (kept for reference): 7 piece types (each colored) + 4 rotations (A=clockwise / B=counter-clockwise) + line clears + score + GAME OVER → restart + brick walls | shape table (28 entries × 16-bit) bulk-loaded into USER_RAM via `nes_pokestr`. Per-cell locked tile numbers stored in USER_RAM_EXT (bank 3). PUSH START locks in the random seed |
| [`examples/tetris2.php`](./examples/tetris2.php) | Tetris v2: rewrite of v1 — real spawn-overlap GAME OVER check, cleaner line-clear compaction, unified collision loop, differential redraw of the falling piece | Same USER_RAM / USER_RAM_EXT layout as v1, tile numbers stored directly in ext RAM |
| [`examples/tetris3.php`](./examples/tetris3.php) | Tetris v3: from-scratch NES-style implementation — 10×20 field + 2 hidden rows, center-pivot rotations, NEXT preview, LINES / LEVEL with speed-up, 40/100/300/1200 scoring, DAS auto-repeat, soft drop | Independent of v1/v2 (shares only the CHR piece tiles) |
| [`examples/elephpant.php`](./examples/elephpant.php) | Mario-style platformer demo: a 16×16 elePHPant with inertia, variable-height jumps, dash, walk animation, floating blocks | 2×2 sprite assembly, `nes_sprite_attr` h-flip, custom CHR tiles (elePHPant / clouds / ? block), fixed-point physics |
| [`examples/fontdemo.php`](./examples/fontdemo.php) | Display all font glyphs (uppercase / lowercase / digits / symbols) | Font sampler for the bold arcade-style digits and uppercase |
| [`examples/peek_test.php`](./examples/peek_test.php) | Smoke test for peek/poke/pokestr | String copy + 1-byte read/write into USER_RAM |
| [`examples/peekext_test.php`](./examples/peekext_test.php) | Smoke test for peek_ext / poke_ext / pokestr_ext | Bulk copy + read/write into USER_RAM_EXT (bank 3) |
| [`examples/putint.php`](./examples/putint.php) | 5-char right-justified score display via `nes_putint` | `nes_putint` smoke test |
| [`examples/shifttest.php`](./examples/shifttest.php) | `<<` `>>` behavior | Shift operators |
| [`examples/multest.php`](./examples/multest.php) | `*` `/` `%` (16-bit signed) | Arithmetic |
| [`examples/parentest.php`](./examples/parentest.php) | Parenthesized expressions override precedence | Syntax |
| [`examples/arrlit_test.php`](./examples/arrlit_test.php) | Nested array literal `[[1,2],[3,4]]` | Arrays |
| [`examples/arrself.php`](./examples/arrself.php) | Self-referencing array writes (`$a[$i] = $a[$i] + 1`) | Verifies shared-pointer behavior |
| [`examples/simple_random.php`](./examples/simple_random.php) | Minimal LFSR demo | `nes_rand` `nes_srand` |
| [`examples/slides.php`](./examples/slides.php) | Slide presentation that advances one line per button press | `nes_puts`, `nes_cls` |
| [`examples/presen.php`](./examples/presen.php) | Multi-slide long-form presentation | `nes_puts`, CHR bank switching |
| [`examples/presen_cv.php`](./examples/presen_cv.php) | Presentation with CV-driven state machine | CV + `if` + `while` |
| [`examples/chrdemo.php`](./examples/chrdemo.php) | BG pattern table / CHR bank switching | `nes_chr_bg`, `nes_chr_spr` |
| [`examples/livetext.php`](./examples/livetext.php) | Drawing text dynamically while a sprite is moving | `nes_sprite_at` + `nes_puts` coexistence |
| [`examples/livereset.php`](./examples/livereset.php) | Clear and switch slides while a sprite is on screen | `nes_sprite_at` + `nes_cls` coexistence |
| [`examples/color.php`](./examples/color.php) | Colorful presentation: per-line color | `nes_palette` + `nes_attr` + `nes_bg_color` |
| [`examples/err_syntax.php`](./examples/err_syntax.php) | Intentional syntax error → on-screen error report | Compiler error reporting |

Acceptance criteria and `xxd` patterns per example: [`spec/09-verification.md`](./spec/09-verification.md).

---

## Replacing artwork via custom CHR

`chr/make_font.php` generates `chr/font.chr` (32KB = 4 × 8KB banks); edit that script and re-run `php chr/make_font.php`, then `make` to rebuild. Since the move to CHR-RAM, the ROM bakes only the **first 16KB** into PRG-ROM bank 1 (the `CHRDATA` segment) as four 4KB CHR sets. At boot the first 8KB (sets 0-1) is copied into CHR-RAM; `nes_chr_bg($n)` / `nes_chr_spr($n)` (n = 0-3) re-copy a 4KB set at runtime.

Default contents:
- **Set 0** (boot-time BG pattern table): ASCII font — 5×7 glyphs, with digits and uppercase as chunky 7×7 arcade-style bold glyphs — plus custom tiles: Japan flag (0x01-0x04), tetromino piece tiles (0x05-0x0B), brick wall (0x0C), elePHPant sprite (0x10-0x15), cloud (0x16-0x19), ? block (0x1A-0x1D)
- **Set 1** (boot-time sprite pattern table): an inverse copy (use `nes_chr_bg(1)` for outlined text)
- **Sets 2-3**: copies of sets 0-1 (intended for swap-in for presentations)

Detailed instructions for editing every bank / pattern table: [`spec/11-chr-banks.md`](./spec/11-chr-banks.md).

---

## License

MIT License. See [LICENSE](./LICENSE).

### PHP compatibility note

This project references Zend VM opcode numbers and struct layouts (`zend_op`, `zval`, `zend_string`) from PHP 8.4 source for binary interoperability. No PHP source code is included or redistributed.

### Trademarks

"NES", "Famicom", and "Nintendo" are trademarks of Nintendo. This project is not affiliated with, endorsed by, or sponsored by Nintendo.
