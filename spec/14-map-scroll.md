# 14. Scrolling maps, sprites with runtime tiles, and the town demo

[← README](./README.md) | [← 13-compiler](./13-compiler.md)

This chapter documents the VM features added for `examples/town.php` (a
Dragon Quest-style town you walk around in) and the constraints that shaped
them. Everything here was measured on the on-NES compiler path (L3S).

## Intrinsics added

| Intrinsic | Opcode | Args | What it does |
|---|---|---|---|
| `nes_scroll($x, $y)` | 0xE7 | both runtime | Sets the BG scroll. `$x` 0-511 (bit 8 selects the right nametable), `$y` 0-239 (nametables are 30 rows = 240 px tall and wrap there). In forced blanking the shadow is updated directly; in sprite_mode a scroll entry is pushed on the NMI queue so it takes effect in the same VBlank as the nametable writes queued before it |
| `nes_sprite_tile($idx, $tile)` | 0xE6 | both runtime | `OAM[$idx*4+1] = $tile`. `nes_sprite_at` only accepts a literal tile, so use this when the tile depends on direction / NPC type (saves one `if` branch per variant, which matters under the op cap) |
| `nes_map_cfg($mw, $mode)` | 0xE5 | both runtime | Map width in metatiles and the draw mode for `nes_map_rect` (bit 0-1: 0 = full 2×2, 1 = top tile row only, 2 = bottom row only; bit 2 = skip attributes). Also copies the 16-byte type→palette table from bank 3 offset 4080 (`MAP_PALTAB_EXT`) into RAM |
| `nes_rom_copy($dst, $src, $len)` | 0xE3 | all runtime | Copies `$len` bytes from PRG-ROM bank 2 (the `GAMEDATA` segment = `build/data.bin`, per-example `examples/NAME.data.bin`) offset `$src` into PRG-RAM bank 3 offset `$dst`. Used once at boot to expand map / objects / messages (8 KB ≈ 0.15 s) |
| `nes_chr_copy($tile, $src, $n)` | 0xE2 | all runtime | Copies `$n` 16-byte tiles from PRG-ROM bank 2 offset `$src` into CHR-RAM at BG tile `$tile`. In sprite_mode it uses the same brief blanking as `nes_cls` (one black frame). This is how Japanese glyphs reach the pattern table |
| `nes_obj_draw($cpx, $cpy, $n)` | 0xE0 | all runtime | Places `$n` object records (bank 3 offset 4096, 5 bytes each: `x, y, type, msg, pal`) as 16×16 sprites in OAM slots 4+4i, relative to camera pixel `($cpx, $cpy)`; off-screen objects and chests (`type = 0xFF`) are hidden. The high byte of `$n` (if non-zero) is a screen-y threshold: sprites at or below it are hidden too (the town passes `$NPC_N + 145*256` when opening the message window so only sprites overlapping the window vanish). Replaces a ~30-op-per-NPC PHP loop |
| `$r = nes_obj_at($x, $y)` | 0xDF | expression | Returns 0 if no object record sits on map cell `(x, y)`, else `1 + msg`. Uses the count of the last `nes_obj_draw`. The record's `pal` byte holds two sprite palettes: bits 0-1 for the top two sprites (head), bits 2-3 for the bottom two (body), so a character can use four colours (blonde hair + pink dress). The town calls it for the cell in front of the hero and, when that cell is a COUNTER tile with nobody on it, once more for the cell beyond (talking across counters) |
| `nes_cam_move($dx, $dy, $frames)` | 0xE1 | all runtime | Starts a camera tween: every NMI adds `(dx, dy)` to the scroll and subtracts it from all world sprites (slots 4-63), for `$frames` frames, hiding sprites that leave the screen. Bit 8 of `$frames` = "hero mode": move sprites 0-3 by `(dx, dy)` instead (used when the camera is clamped at a map edge). Returns immediately (after waiting for a previous tween), so PHP can decide the next step while the screen moves |
| `nes_cam_wait()` | 0xDE | none | Spins until the current tween has finished |
| `nes_map_rect($mx, $my, $w, $h)` | 0xE4 | `$h` **must be a plain `$var`** | Draws a rectangle of metatiles from the map in PRG-RAM bank 3 (1 byte per cell at `my * mw + mx`) into the nametables. Cell byte: low 5 bits = metatile type `t` → CHR tiles `0x88 + t*4` (TL, TR, BL, BR); bit 5 is free for the game (the town uses it as "walkable"). Nametable column = `(mx*2) & 63`, row = `(my % 15) * 2`, attribute block `(mx & 31, my % 15)` with palette `PALTAB[t]`. The 4th argument is passed through `extended_value`, which has no type byte, so the compiler requires a CV there |

`nes_put`, `nes_puts` and `nes_attr` now accept x up to 63 (nes_attr: block x up to 31).
Columns 32-63 land in nametable 1 (`$2400`, `$27C0`). `nes_puts` wraps a string
that crosses column 63 into the same row of the other nametable, so a message
window row can be written with one call while scrolled. The attribute shadow
grew to 128 bytes (`$0608-$0687`, 64 per nametable).

MMC1 is configured for **vertical mirroring** (control register `$1E`, bits 1-0 =
`10`): nametables 0/1 sit side by side, so horizontal scrolling is seamless and
vertical scrolling wraps at 240 px inside one nametable.

## How the town scrolls (standard NES technique, smoothed by the NMI)

- The view is 16×15 metatiles. The camera (`cx`, `cy`) keeps the hero centred and
  clamps at the map edges. One step = two 8 px halves; each half is a
  `nes_cam_move(dx*2, dy*2, 4)` tween (2 px per frame, 8 frames per step, the
  Dragon Quest pace), driven entirely by the NMI so the VM's speed does not
  matter. The hero's walk frame toggles between halves via `nes_sprite_tile`.
- **Horizontal**: the incoming metatile column lies in the other nametable,
  outside the visible 256 px, so it is drawn whole (`nes_map_rect` with `w = 1`,
  `h = 15`) before the tween starts. While walking, the *next* column is
  prefetched during the step (still hidden), so continuous walking never waits;
  a direction change writes the column and waits 2 frames for the queue.
- **Vertical**: there is no hidden row (30 rows = the whole screen), so each
  half draws only the tile row that currently sits in the top or bottom 8 px
  overscan band (hidden on TVs and in FCEUX's default 224-line view). Because a
  nametable row wraps from the top band to the bottom band (240 px), the row
  written at the start of a half stays hidden for the first 4 frames of the
  tween, so no wait is needed. Mode 1/2 of `nes_map_cfg` selects the row;
  attributes are written with the second row. Moving down: draw top row of the
  incoming metatile row → tween 8 px → draw bottom row + attributes → tween 8 px.
- The second half's tween is started before the input for the next step is
  read, so the VM's ~30 ms of input/collision work overlaps the motion. Measured:
  9 frames per horizontal step, 10 per vertical step, both at 2 px per frame.
- `nes_map_rect` writes each tile row as one queue entry (up to 32 bytes,
  split at the nametable boundary) and each tile column as one entry with the
  vertical-increment flag (bit 7 of the queue entry's address high byte makes
  the NMI set PPUCTRL increment = 32), so a row flushes in one VBlank.
- NPCs walk in place with two frames, DQ1 style, at zero PHP cost: every 24
  frames (`ANIM_PERIOD`, about 0.4 s) the NMI (`nmi_obj_anim`) flips `ANIM_PHASE` and adds or subtracts
  `$20` on the tile byte of OAM slots 4-63. Frame B of every NPC therefore
  lives at frame A + `$20` in sprite pattern set 1 (`$B0-$C7`; frame A is
  `$90 + type*4`). `nes_obj_draw` reads `ANIM_PHASE` when it places sprites so
  the phase survives a redraw, and the routine is skipped while `OAM_BUSY` is
  set or until the program has called `nes_obj_draw` once (`OBJ_COUNT = 0`).
  The hero is animated by the program instead: `$f` toggles each half step and
  selects `$80/$A8` (front), `$84/$AC` (back) or `$88/$8C` (side, mirrored).

## NMI queue flush budget

`flush_nmi_queue` charges each entry **6 units + 1 per data byte** (an entry's
fixed handling is ≈90 cycles, a byte 15 cycles) against a budget of 90 units
(≈1350 cycles) per VBlank, and checks the cost *before* processing an entry, so
an entry never straddles the end of VBlank. OAM DMA (513 cycles) plus register
saves and `apply_scroll` take ≈620 of the 2273 VBlank cycles. PPUDATA writes that
spill past VBlank corrupt random nametable / attribute bytes because rendering
rewrites the PPU's `v` register; this bit three times while developing the
town (33-byte string entries, a 210-byte column, and 15 one-byte attribute
entries followed by a 20-byte column).

`nes_pokestr_ext` now stages its copy through the TMP page (`$0500-$05FF`)
instead of `$0600`, which holds `INT_PRINT_BUFFER`, the attribute shadow and
`MAP_PALTAB`.

## Game data: `examples/town.data.bin` (PRG-ROM bank 2)

Bulk data never goes through PHP: arrays cost 1 op per element (a 32×28 map =
896 ops) and string escapes cost 4 source bytes per byte. Instead the exporter
writes a binary blob that the Makefile bakes into PRG-ROM bank 2 (`GAMEDATA`
segment; examples without a `.data.bin` get an empty segment). `town_map.php`
shrinks to the map size, hero start, object count and one `nes_rom_copy(0, 0,
8192)` that expands the first 8 KB into PRG-RAM bank 3 at boot:

| Bank 3 offset | Contents |
|---|---|
| 0 .. | Map, 1 byte per metatile: `0x40 + type`, or `0x60 + type` when walkable (bit 5). Max 4080 bytes |
| 4080 | `PALTAB`: 16 bytes, type → BG palette (read by `nes_map_cfg`) |
| 4096 .. | Object records, 5 bytes: `x, y, type, msg, pal`. `type = 0xFF` is a chest (no sprite, message on A) |
| 4864 .. | Messages, 84 bytes each: `[glyph ROM offset lo, hi][glyph count][pad]` + 3 lines × 26 bytes of **tile numbers**, 0-terminated (max 25 chars) |

| ROM bank 2 offset | Contents |
|---|---|
| 8192 .. | Glyph bitmaps, 16 bytes per tile (bitplane 0 = glyph, bitplane 1 = 0), grouped per message; up to 512 glyphs |

### Japanese text (kanji included)

Message lines are stored as tile numbers. ASCII 0x20-0x7E uses the resident
font. Every other character is looked up in a BDF font (misaki 8×8, Unicode
encoded: `chr-edit/misaki_bdf_2021-05-05/misaki_gothic.bdf`), de-duplicated
within the message and assigned a **glyph slot** `0xC0 + i` (56 slots =
tiles 0xC0-0xF7; a 3 × 25 message rarely has more distinct glyphs). When the window opens, the engine
reads the message header and calls `nes_chr_copy(0xC0, offset, count)` once,
so only the glyphs of that message live in CHR-RAM. A whole town's dialogue can
therefore use any number of distinct kanji; the limits are 21 chars per line
and 512 glyph tiles (8 KB) in the ROM bank (line length is 25 chars). Full-width spaces map to ASCII
space; characters missing from the BDF become `?` with an export warning.

## Map editor

`map-edit/index.html` is a standalone editor (same spirit as `chr-edit`): paint
metatiles, place NPCs / chests / the hero, type each object's message (Japanese
is fine once a BDF is loaded), then "出力" and save both `town_map.php` and
`town.data.bin` into `examples/`. `map-edit/export.js` holds the exporter and
the BDF parser and also runs under node:

```
node map-edit/gen.js map-edit/town.json examples/town_map.php examples/town.data.bin \
     chr-edit/misaki_bdf_2021-05-05/misaki_gothic.bdf
```

Load `chr/font.chr` in the editor to see the real tiles; the model, the CHR and
the BDF are cached in localStorage, and the model can be saved/loaded as JSON
(`map-edit/town.json` is the sample town). The exporter refuses walkable tiles
on the outer border because the engine skips bounds checks to save ops.

`tools/pack_src.php` inlines `require 'file.php';` (relative to the including
file) and strips `//` comments and indentation, keeping line numbers, so the
16 KB source cap is spent on code. `Makefile` lists `examples/town_map.php` as
an extra dependency of `build/town.src.bin`.

## Measured op costs (on-NES compiler)

The op array holds **617 ops** (`$6010-$7CFF`, 12 bytes each; `$7D00-$7FFF` is the
literal staging area); `town.php` uses about 530. Measured per statement:

| Statement | Ops |
|---|---|
| `$a = 1;` / `$a = $b;` | 1 |
| `$a = $b + $c;` (each extra operator +1) | 2 |
| `f($a + 1, $b, $c + 2);` (call + 1 per expression argument) | 3 |
| `if (cond) { ... }` | 2 + body |
| `while (cond) { ... }` | 3 + body |
| `$x = nes_peek_ext($o + 2);` | 3 |
| **each `&&` / `\|\|`** | **≈ 5** |
| array literal | 1 + one per element |

Compiler gotchas found while writing the town: `elseif` nests two levels per
branch (the 7-level nest limit bites after three `elseif`s — use a state
variable and flat `if`s); an expression that *starts* with a parenthesised
sub-expression followed by an operator (`($a + 1) & 63`) is rejected, while
`63 & ($a + 1)` is accepted; `$t = f() - 1` style calls inside binops should be
split into two statements. The VM executes roughly 2,950 ops/s
(≈0.34 ms/op).

## ROM layout: 128 KB, RUNTIME bank

The fixed code bank (16 KB at `$C000`) filled up, so the ROM is now 8 × 16 KB
(iNES PRG count 8): bank 0 PHPSRC, 1 CHRDATA, 2 GAMEDATA, **3 RUNTIME**, 4-6 empty,
7 CODE (fixed). PRG-ROM bank 0 is only needed while compiling, so after
`compile_and_emit` the reset code maps bank 3 at `$8000`, and the large
runtime-only handlers (`nes_map_rect`, `nes_obj_draw`, `nes_obj_at`) live in the
`RUNTIME` segment there. Handlers that temporarily map bank 1/2 (`chr_bulk_transfer`,
`nes_rom_copy`, `nes_chr_copy`) restore `PRG_RUNTIME_BANK` afterwards and must
stay in the fixed bank, as must anything the NMI calls.

## Related documents

- [04-opcode-mapping](./04-opcode-mapping.md) — opcode numbers
- [06-display-io](./06-display-io.md) — PPU state machine, NMI queue
- [11-chr-banks](./11-chr-banks.md) — tile numbers (town metatiles at 0x88, window frame at 0xF8)
- [13-compiler](./13-compiler.md) — grammar and limits
