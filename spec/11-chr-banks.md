# 11. CHR bank switching (CNROM + PPUCTRL)

[← README](./README.md) | [← 10-devlog](./10-devlog.md)

For presentations and switching the "overall look" of the screen, nesphp has a
**two-level CHR switching mechanism**. The motivation is less about romance and
more practical: "I want each slide to be flashy with a different tile set."

## The two levels

| Level | Means | Granularity | Switch cost | Implementation |
|---|---|---|---|---|
| **(A)** | `PPUCTRL` bit 4 | Selects between two pattern tables in the same bank | 1 instruction (STA $2000) | `NESPHP_NES_CHR_BG` |
| **(B)** | CNROM bank register | Switches between four 8KB CHR banks | 1 instruction (bus-conflict-safe STA) | `NESPHP_NES_CHR_BANK` |

Combining both gives **up to 4 × 2 = 8 pattern tables**. All of them are static
(burned into ROM), so to swap content per slide, prepare CHR data under `chr/`
and rebuild via `make_font.php`.

## Mapper: MMC1 (mapper 1, SXROM-equivalent + CHR-RAM)

### iNES header (NES 2.0)

```
4E 45 53 1A   "NES" + EOF
04            byte 4 = PRG-ROM = 4 * 16KB = 64KB
00            byte 5 = CHR-ROM = 0 (CHR-RAM mode)
10            byte 6 (Flags 6): mapper LSB nibble = 1 (MMC1)
08            byte 7 (Flags 7): bit 2-3 = NES 2.0 marker
00            byte 8 = mapper bits 8-11 + submapper
00            byte 9 = PRG/CHR ROM size upper nibble
09            byte 10: PRG-RAM size = 64 << 9 = 32 KB (volatile)
07            byte 11: CHR-RAM size = 64 << 7 = 8 KB
00 00 00 00   bytes 12-15 (padding)
```

The single source of truth is `vm/nesphp.s` `.segment "HEADER"` and `vm/nesphp.cfg`.

### Evolution: CNROM → MMC1 / SXROM (CHR-RAM)

| | CNROM (oldest) | MMC1 SNROM (older) | **MMC1 SXROM + CHR-RAM (current)** |
|---|---|---|---|
| CHR | 32KB CHR-ROM | up to 128KB CHR-ROM | **8KB CHR-RAM** (8KB transferred from PRG bank 1 to PPU $0000-$1FFF at boot) |
| CHR switch granularity | 8KB at once | 4KB × 2 | **bank switching is meaningless under CHR-RAM** ($A000/$C000 regs are repurposed as PRG-RAM bank select on SXROM) |
| PRG-ROM | none | 16KB units ($8000 switched, $C000 fixed) | **64KB**: bank 3 ($C000 fixed) = VM CODE, banks 0/1/2 ($8000 switched) = PHPSRC / CHRDATA / spare |
| PRG-RAM (WRAM) | none | 8KB ($6000-$7FFF, single bank) | **32KB = 4 × 8KB banks** (selected by $A000 reg bits 2-3): bank 0 = op_array+literals, bank 1 = ARR_POOL, bank 2 = STR_POOL, bank 3 = USER_RAM_EXT |

### CHR layout

In MMC1's 4KB CHR banking mode, 32KB CHR-ROM is addressed as eight 4KB banks.
The physical layout of font.chr (8KB × 4) is unchanged, but **mapping to PPU
is now in 4KB units**:

```
CHR-ROM (32KB) = 8 × 4KB banks
├── 4KB bank 0: normal font (old CNROM bank 0 PT0)
├── 4KB bank 1: inverse font (old CNROM bank 0 PT1)
├── 4KB bank 2: normal font (old CNROM bank 1 PT0)
├── 4KB bank 3: inverse font (old CNROM bank 1 PT1)
├── 4KB banks 4-5: (old CNROM bank 2)
└── 4KB banks 6-7: (old CNROM bank 3)
```

Two MMC1 CHR registers map them into PPU space:
- **CHR bank 0 register ($A000)** → which 4KB bank lands at PPU $0000-$0FFF
- **CHR bank 1 register ($C000)** → which 4KB bank lands at PPU $1000-$1FFF

### Backward compatibility

`nes_chr_bank($n)` keeps the same API as the CNROM era. Internally it sets
**CHR bank 0 = N×2 and CHR bank 1 = N×2+1** simultaneously (equivalent to old
8KB bank N):

```asm
; Internal behavior of nes_chr_bank(1)
LDA #2           ; 1 * 2
MMC1_WRITE $A000  ; CHR bank 0 = 4KB bank 2
LDA #3           ; 1 * 2 + 1
MMC1_WRITE $C000  ; CHR bank 1 = 4KB bank 3
```

`chr/make_font.php` produces it. To put unique tiles per bank, edit the
`$banks` array and re-run `php chr/make_font.php`.

### MMC1 serial write protocol

MMC1 registers take **5-bit serial** writes. Bits 0 through 4 are written by
five consecutive STAs to the same address range; the fifth latches the value:

```asm
.macro MMC1_WRITE addr
    STA addr      ; bit 0
    LSR A
    STA addr      ; bit 1
    LSR A
    STA addr      ; bit 2
    LSR A
    STA addr      ; bit 3
    LSR A
    STA addr      ; bit 4 → latch
.endmacro
```

Four address ranges select which register:

| Address | Register | Purpose |
|---|---|---|
| $8000-$9FFF | Control | mirroring, PRG bank mode, CHR bank mode |
| $A000-$BFFF | CHR bank 0 | 4KB bank number for PPU $0000-$0FFF |
| $C000-$DFFF | CHR bank 1 | 4KB bank number for PPU $1000-$1FFF |
| $E000-$FFFF | PRG bank | 16KB bank number for $8000-$BFFF + WRAM enable |

Unlike CNROM, no bus conflicts occur (MMC1 has its own dedicated shift register IC).

## `NESPHP_NES_CHR_BG` (0xF6): switch BG 4KB CHR bank

### Call

```php
nes_chr_bg(0);  // BG → 4KB bank 0 (normal font)
nes_chr_bg(1);  // BG → 4KB bank 1 (inverse font)
nes_chr_bg(2);  // BG → 4KB bank 2 (custom)
// ... up to 7 (32KB / 4KB = 8 banks)
```

The argument is a compile-time integer literal (0-7).

### VM implementation

Serial 5-bit write to the MMC1 CHR bank 0 register ($A000):

```asm
LDA OP1_VAL+1
AND #$07
MMC1_WRITE $A000
```

The selected bank is mapped to PPU $0000-$0FFF. PPUCTRL bit 4 = 0 (set at
reset), so BG fetches its tiles from there. **Sprites at $1000 are completely
unaffected**.

## `NESPHP_NES_CHR_SPR` (0xF5): switch sprite 4KB CHR bank

### Call

```php
nes_chr_spr(0);  // sprite → 4KB bank 0 (normal font)
nes_chr_spr(4);  // sprite → 4KB bank 4 (custom)
```

The argument is a compile-time integer literal (0-7).

### VM implementation

Serial 5-bit write to the MMC1 CHR bank 1 register ($C000):

```asm
LDA OP1_VAL+1
AND #$07
MMC1_WRITE $C000
```

The selected bank is mapped to PPU $1000-$1FFF. PPUCTRL bit 3 = 1 (set at
reset), so sprites fetch from there. **BG at $0000 is completely unaffected**.

### BG / sprite separation via PPUCTRL

`PPUCTRL = %00001000` is set at reset:
- bit 4 = 0: BG uses PPU $0000-$0FFF (= controlled by CHR bank 0 register)
- bit 3 = 1: sprite uses PPU $1000-$1FFF (= controlled by CHR bank 1 register)

This setup lets `nes_chr_bg` and `nes_chr_spr` operate **fully independently**,
structurally eliminating the CNROM-era issue of "bank switching corrupts
sprites".

The default state has CHR bank 0 = CHR bank 1 = 0 (both pointing at 4KB bank 0
= the normal font), so **the visual is identical to before**.

### Serializer folding (same pattern for both)

```
INIT_FCALL_BY_NAME 1 "nes_chr_bg"    →  ZEND_NOP
SEND_VAL_EX int(N) 1                 →  ZEND_NOP
DO_FCALL_BY_NAME                     →  NESPHP_NES_CHR_BG
                                        op1_type = IS_CONST
                                        op1 = zval offset of int literal
```

`nes_chr_spr` has the same structure (only `NESPHP_NES_CHR_SPR` differs).

## Typical usage

### Pattern 1: switch BG to inverse (sprite stays)

```php
nes_chr_bg(1);  // BG → 4KB bank 1 (inverse font)
nes_puts(4, 4, "HIGHLIGHTED");
nes_chr_bg(0);  // BG → 4KB bank 0 (back to normal)
nes_puts(4, 6, "NORMAL TEXT");
// Sprite watches $1000 (CHR bank 1 register), so unaffected
```

### Pattern 2: switch BG and sprite independently

```php
// BG uses decorative font bank, sprite is pinned to normal font bank
nes_chr_bg(2);    // BG → 4KB bank 2 (custom font)
nes_chr_spr(0);   // sprite → 4KB bank 0 (normal font)
// → Only BG redesigned; sprite continues displaying 'X' stably
```

### Pattern 3: slide transition

```php
nes_chr_bg(4);   // BG → title font (4KB bank 4)
nes_cls();
nes_puts(4, 4, "SLIDE TITLE");
$k = fgets(STDIN);
nes_chr_bg(0);   // BG → body font (4KB bank 0)
nes_cls();
nes_puts(4, 4, "BODY CONTENT");
```

## Building custom CHR

### File layout and regeneration

`chr/font.chr` is a **committed binary** that gets overwritten every time
`chr/make_font.php` runs. Edit procedure:

```bash
vim chr/make_font.php          # rewrite banks / tiles
php chr/make_font.php          # regenerate chr/font.chr (32KB)
make                           # incremental rebuild (CHR change propagates to all .nes)
```

The Makefile lists `chr/font.chr` as a dependency, so regenerating it relinks
all existing examples with the new CHR.

### Tile byte layout (recap)

1 bank = 8KB = 2 pattern tables × 4KB:

```
offset from bank start   contents
$0000-$0FFF              Pattern Table 0 (256 tiles)
$1000-$1FFF              Pattern Table 1 (256 tiles)
```

1 tile = 16 bytes:
- Bytes 0-7: bitplane 0 (8 rows × 8 pixels, MSB on the left)
- Bytes 8-15: bitplane 1 (same)

Final pixel color = `(bitplane1 << 1) | bitplane0` (palette index 0-3).
The default nesphp palette (`palette_data`, see [06-display-io](./06-display-io.md))
is `$0F, $30, $10, $00` for every row, meaning "color 0 = black / color 1 =
white / color 2 = dark gray / color 3 = transparent".

**For monochrome use** (standard font): write only bitplane 0, bitplane 1 = 0.
**For two-color use** (edged fonts, shadowed logos, etc.): set bitplane 1 for
pixels that should be color 2 and combine with color 1 for either-or pixels.

### Structure of `chr/make_font.php`

```php
function build_bank(array $font5x7, array $customTiles = []): string
{
    $bank = str_repeat("\x00", 8192);
    // ... fill ASCII 0x20-0x7F glyphs into pattern tables 0 and 1
    // ... write each tile in $customTiles (0x00-0x1F) as bp0/bp1
    return $bank;
}

$bank0 = build_bank($font5x7, $customTiles);
$banks = [
    0 => $bank0,        // ← default: all 4 banks identical
    1 => $bank0,
    2 => $bank0,
    3 => $bank0,
];

$chr = '';
for ($i = 0; $i < 4; $i++) { $chr .= $banks[$i]; }
file_put_contents(__DIR__ . '/font.chr', $chr);
```

The main extension point is the `$banks` array.

### `$customTiles` array: place graphics in tiles 0x00-0x1F

The ASCII font occupies tiles 0x20-0x7F, so **tiles 0x00-0x1F (32 tiles) are
unused**. The `$customTiles` array in `chr/make_font.php` lets you place
custom graphics there. `build_bank()` takes this array as its second argument
and writes bitplane 0 / bitplane 1 for each tile.

```php
$customTiles = [
    0x01 => [
        'bp0' => [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],  // color 1
        'bp1' => [0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00],  // color 2
    ],
    // ... 0x02, 0x03, 0x04, etc. in the same way
];

$bank0 = build_bank($font5x7, $customTiles);
```

- `bp0` (bitplane 0): set bits become color 1
- `bp1` (bitplane 1): set bits become color 2
- Both set → color 3, both 0 → color 0 (background / transparent)

#### Concrete example: Japanese flag (2×2 tiles = 16×16 pixels)

The Japanese flag in `examples/color.php` is built from 4 tiles (0x01-0x04):

```
Tile arrangement:
  [0x01][0x02]    top-left   top-right
  [0x03][0x04]    bottom-left bottom-right
```

Each tile uses two bitplanes:
- **bitplane 0 (color 1 = white)**: paint the entire flag → `bp0` is 0xFF for every row
- **bitplane 1 (color 2 = red)**: only the red disc → `bp1` carries the disc pattern

On the PHP side, `nes_palette` sets color 1 = `$30` (white) and color 2 = `$16`
(dark red). Tile numbers are placed directly via `nes_put($x, $y, 1)` etc. into
a 2×2 arrangement.

#### Available tile numbers

| Range | Use |
|---|---|
| 0x00 | blank (default nametable value, safer not to use) |
| 0x01-0x04 | Japanese flag (`examples/color.php`) |
| **0x05-0x0B** | Tetris piece tiles × 7 (I/O/T/S/Z/L/J, `examples/tetris.php`) |
| **0x0C** | Tetris brick wall (`examples/tetris.php`) |
| 0x0D-0x1F | Available for custom tiles (19 tiles) |
| 0x20-0x7E | ASCII font (auto-generated by make_font.php) |
| 0x7F | DEL (unused, available for custom) |
| 0x80-0xFF | Pattern table 1 side (unused, available for custom) |

#### Concrete example: Tetris pieces (tiles 0x05-0x0B) and brick wall (0x0C)

`examples/tetris.php` follows the BPS Famicom Tetris look: **only one palette
(palette 1) is used** (= avoiding color bleed). Each piece is identified by a
7×7 ring (border) + 3×3 core in the center; the seven pieces are distinguished
by ring/core color combinations:

```
col→ 0 1 2 3 4 5 6 7
row 0 R R R R R R R .
row 1 R . . . . . R .
row 2 R . C C C . R .
row 3 R . C C C . R .
row 4 R . C C C . R .
row 5 R . . . . . R .
row 6 R R R R R R R .
row 7 . . . . . . . .
```

- palette 1 = (`$0F` black bg, `$30` white = slot 1, `$16` red = slot 2, `$1A` green = slot 3)
- 0x05 I: ring=3 green / core=3 green (solid green)
- 0x06 O: ring=1 white / core=1 white (solid white)
- 0x07 T: ring=2 red / core=2 red (solid red)
- 0x08 S: ring=3 green / core=2 red (green ring + red core)
- 0x09 Z: ring=2 red / core=3 green (red ring + green core)
- 0x0A L: ring=1 white / core=2 red (white ring + red core)
- 0x0B J: ring=2 red / core=1 white (red ring + white core)

The brick wall (0x0C) is an 8×8 brick pattern using palette 0's default colors
(`$10` gray + `$00` dark gray): horizontal mortar at top/bottom + vertical
mortar + offset. The play field's attribute is set to palette 1, so the frame
is positioned (rows 3 / 26) such that it doesn't overlap the play field
attribute block, securing palette 0 (default) gray rendering.

### Example 1: Place an entirely different font in bank 1

```php
// Prepare your own alternate font bitmap
$fontDecorative = [ /* 96 entries of [r0..r7] */ ];

$bank0 = build_bank($font5x7);
$bank1 = build_bank($fontDecorative);

$banks = [0 => $bank0, 1 => $bank1, 2 => $bank0, 3 => $bank0];
```

From PHP, `nes_chr_bank(1)` switches to the decorative font.

### Example 2: Place logos or graphic tiles at custom tile numbers

Extend `build_bank` to slot custom tiles into the gaps among ASCII glyphs:

```php
function build_bank_with_logo(array $font5x7): string
{
    $bank = str_repeat("\x00", 8192);

    // ASCII font as usual
    foreach ($font5x7 as $i => $rows) {
        $t0 = (0x20 + $i) * 16;
        for ($y = 0; $y < 8; $y++) {
            $bank[$t0 + $y] = chr($rows[$y]);
        }
    }

    // Tiles 0x00-0x1F are unused, so logo parts go there
    // e.g. tile 0x01 = 8x8 fill
    $logoTile1 = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    for ($y = 0; $y < 8; $y++) {
        $bank[0x01 * 16 + $y] = chr($logoTile1[$y]);
    }

    return $bank;
}
```

On the PHP side, tile 0x01 isn't a printable ASCII character, so `nes_puts`
can't write it. But `nes_put($x, $y, 1)` (with the third argument as an int
literal) places the tile by direct number — the IS_LONG branch fires and the
low byte is used as the tile number.

### Example 3: Use bitplane 1 for two-color fonts

Shadowed glyphs, etc.:

```php
// Body in bitplane 0 (color 1 = white), shadow only in bitplane 1 (color 2 = dark gray)
for ($y = 0; $y < 8; $y++) {
    $bank[$t0 + $y]     = chr($rows[$y]);                    // body in white
    $bank[$t0 + 8 + $y] = chr($rows[$y] >> 1 | $rows[$y]);   // shadow shifted lower-right
}
```

To set color 2 to a different color (e.g. `$0F, $30, $26, $00`), edit
`palette_data` in `vm/nesphp.s`.

### Size limits

CNROM totaled **32KB CHR-ROM** (4 × 8KB). Beyond that, mapper promotion (GxROM
/ UxROM + CHR-RAM, etc.) becomes necessary. Future CHR-RAM support would let
us inject tiles from PRG at runtime.

## Limitations

| Limit | Reason | Mitigation |
|---|---|---|
| `nes_chr_bank` / `nes_chr_bg` tears during sprite_mode | Writes apply immediately and aren't VBlank-synced | Add CHR switch commands to the Phase 3 NMI queue (future) |
| No mid-frame switching | No scanline IRQ (MMC1 has no timer) | Promote to MMC3 |
| Sprite pattern table is outside `nes_chr_bg`'s scope | The intrinsic that touches bit 3 isn't implemented | Add `nes_chr_spr($n)` |
| Banks 1-3 default to a copy of bank 0 | That's how `chr/make_font.php` builds it | Edit `$banks` and regenerate |
| No runtime tile-data changes | CHR-**ROM** is unwriteable | Switch to a CHR-RAM configuration |

## Related documents

- [01-rom-format](./01-rom-format.md) — iNES header, PRG / CHR capacities
- [04-opcode-mapping](./04-opcode-mapping.md) — `NESPHP_NES_CHR_BANK` / `NESPHP_NES_CHR_BG` numbers
- [06-display-io](./06-display-io.md) — Meaning of every PPUCTRL bit, palette
- [10-devlog](./10-devlog.md) — Phase 5D design history
