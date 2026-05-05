# 06. PPU display and controller input

[← README](./README.md) | [← 05-toolchain](./05-toolchain.md) | [→ 07-roadmap](./07-roadmap.md)

## CHR-ROM and the font

- We use the first 2KB of the 8KB CHR-ROM (pattern table 0) for the font
- **Tile number = ASCII code** layout:
  - Tile `0x20` = space
  - Tile `0x41` = 'A'
  - Tile `0x48` = 'H'
  - …
- This lets us write `zend_string.val[]` bytes straight into the nametable (`LDA val_byte : STA PPUDATA`)
- Within the 8KB, 0x00-0x1F and 0x80-0xFF are unused (reserved for future sprites)

### How to make font.chr

- Use a free NES-style font (e.g. `8x8-ascii-bitmap-font`)
- 1 tile = 8×8 pixels = 16 bytes (CHR format)
- 96 tiles (0x20-0x7F) = 1536 bytes
- The remaining 6656 bytes are zero-filled

---

## PPU init sequence (inside the reset handler)

1. `$2000 = 0` (disable PPUCTRL)
2. `$2001 = 0` (disable PPUMASK = forced blanking)
3. `$4010 = 0` (disable DMC)
4. Wait two VBLs (`BIT $2002` → `BPL $-3` twice)
5. Clear RAM
6. **Init OAM shadow `$0200-$02FF` to y=$FF** (hide all 64 sprites off-screen)
7. Write the palette (32 bytes to `$3F00-$3F1F`)
8. Clear nametable (fill with space `$20`, 960 bytes + 64 attribute bytes)

---

## Implemented display-mode state machine

The current nesphp VM has 2 PPU states.

```
         [forced_blanking]                       [sprite_mode]
         PPUMASK = 0                             PPUMASK = %00011110 (BG+sprite)
         NMI off                                 NMI on
         Direct nametable writes                 echo/nes_put/nes_puts via NMI queue
                                                  nes_cls via brief force-blanking
                                                   (~1-2 frame black flash)
         Sprites not displayed                   OAM DMA every VBlank
               │                                        ▲
               │  ┌── fgets: temporarily on, wait, off ─┐
               │  │                                            │
               │  └────────────────────────────────────────────┘
               │                                        │
               │                                        │
               │      First nes_sprite_at call          │
               └────────────────────────────────────────┘
```

### forced_blanking (initial state, before sprite_mode)

- `PPUMASK = 0`, rendering off → screen is black
- `echo` / `nes_put` / `nes_puts` / `nes_cls` can hit `PPUADDR` / `PPUDATA` directly during forced blanking
- `fgets` runs the following sub-flow:
  1. `PPUSCROLL = 0,0` + `PPUMASK = %00001110` (rendering temporarily on)
  2. Wait for all buttons released → wait for new press
  3. `PPUMASK = 0` (back to forced blanking) + reset `PPUADDR = PPU_CURSOR`
  4. Write the ROM offset of the matching `button_str_X` to result
- From the user's perspective: "the screen is visible only while a button is held"

### sprite_mode (after the first nes_sprite_at)

The first `nes_sprite_at` call runs `enable_sprite_mode`:

1. Wait for VBlank (`BIT PPUSTATUS` / `BPL :-`)
2. First OAM DMA (`STA $4014`) so the hidden sprites (y=$FF) propagate
3. `PPUSCROLL = 0,0` (reset scroll)
4. `PPUCTRL = %10000000` (NMI enable, sprite/BG pattern table 0)
5. `PPUMASK = %00011110` (BG + sprite rendering, show the leftmost 8 pixels)
6. `sprite_mode_on = 1`

Going forward:

- `nes_sprite_at` writes (y, tile, x) starting at OAM shadow `$0200 + $idx*4` (doesn't touch attr; `nes_sprite_attr` does that). NMI DMAs all 64 sprites every VBlank
- `fgets` waits for buttons without disabling rendering (NMI keeps running, screen stays visible)
- `echo` / `nes_put` / `nes_puts` are powered by **Phase 3 (NMI sync write queue)**. Actual PPU writes happen inside the NMI handler during VBlank (see below)
- `nes_cls` is powered by **Phase 3.1 (brief force-blanking)**. Since 1024 bytes don't fit in the VBlank budget (~2273 cycles), we can't go through the NMI queue; instead we temporarily set `PPUMASK = 0` to stop rendering, clear, and resume rendering on the next VBlank. Visually you get a 1-2 frame black flash that reads naturally as a slide transition

### State transition constraints

- **Once you enter sprite_mode you cannot return to forced_blanking** (intentionally one-way in MVP; `sprite_mode_on` only flips 0 → 1 and never back)
- `echo` / `nes_put` / `nes_puts` **work in both modes since Phase 3** (in sprite_mode they go through the NMI sync queue)
- `nes_cls` **works in both modes since Phase 3.1** (brief force-blanking in sprite_mode: kill rendering, clear, resume next VBlank)

### NMI sync write queue (Phase 3)

We model nametable writes during sprite_mode as "enqueue when called → flush at the next VBlank". Lets us update the nametable without stopping rendering.

Queue: `NMI_QUEUE_ADDR = $0300`, a 256-byte ring buffer. Format:

```
[addr_hi addr_lo len data_0 ... data_{len-1}]  ← 1 entry
[addr_hi addr_lo len data_0 ... data_{len-1}]  ← next entry
...
```

- **`nmi_queue_write`** (zero page, 1B): the offset main appends to (producer)
- **`nmi_queue_read`** (zero page, 1B): the offset NMI processes next (consumer)
- **Both monotonically increase** as uint8s, wrapping at 256. `read == write` is empty; `(write - read - 1) & $FF` is the bytes in use
- Aligned to a **page boundary ($0300)** so X auto-wraps in `LDA NMI_QUEUE_ADDR, X` and entries that straddle the end stay accessible

Race-free design:

- `write` is updated only by main; `read` only by NMI
- main computes free space as `(read - write - 1) & $FF` and appends if >= 3 + len
- If NMI fires mid-append, NMI sees pre-commit `write`, ignores the new entry's space, and just flushes old entries while pulling `read` toward `write`
- The write_head main caches in X is unaffected by NMI (NMI doesn't reset)

`flush_nmi_queue` runs from inside the NMI handler and streams entries `read..write-1` to PPUADDR/PPUDATA. Even flushing all 256 bytes in one VBlank takes ~1300 cycles — within budget.

`enqueue_ppu_nt` is the producer-side helper. Caller fills TMP0/TMP1/TMP2 with (addr, src ptr, len) and JSRs. If there isn't enough space, it busy-waits for NMI to drain.

Handlers route through `ppu_write_bytes`, which checks `sprite_mode_on` and branches between "forced_blanking → direct PPUADDR/PPUDATA" and "sprite_mode → enqueue".

### Brief force-blanking for nes_cls (Phase 3.1)

`nes_cls` clears the entire 1024B nametable 0, which doesn't fit a VBlank budget (~2273 cycles), so the NMI queue isn't viable. In sprite_mode, `nes_cls` does:

1. Save `ppu_ctrl_shadow` to the 6502 stack
2. Clear `PPUCTRL` bit 7 (disable NMI temporarily) so an NMI can't fire mid-clear and overwrite PPUADDR via `flush_nmi_queue`
3. Set `PPUMASK = 0` to stop rendering → forced blanking
4. Run the existing 1024B clear loop
5. Wait for the next VBlank with `BIT PPUSTATUS` / `BPL` (NMI is disabled, so the flag isn't auto-cleared)
6. Manually run OAM DMA via `STA $4014` (compensates for the NMI-disabled OAM update window, once)
7. Reset scroll with `PPUSCROLL = 0, 0`
8. Resume rendering with `PPUMASK = %00011110`
9. Pop `ppu_ctrl_shadow` and restore `PPUCTRL` (re-enable NMI)
10. Reset `PPU_CURSOR` to `NAMETABLE_START` and `JMP advance`

The visible effect is "the screen blacks out for ~1-2 frames between the call and the next VBlank". Reads naturally as a slide-transition flash; lets you cleanly swap slides while sprites stay on screen. The forced_blanking path is unmodified — when `sprite_mode_on == 0`, classic fast direct writes still happen.

### NMI handler (current implementation)

```asm
nmi:
    PHA : TXA : PHA : TYA : PHA    ; Save A/X/Y
    LDA #>OAM_SHADOW               ; $02
    STA OAM_DMA                    ; $4014: OAM DMA stalls 512+ cycles
    BIT PPUSTATUS                  ; reset latch
    LDA #0
    STA PPUSCROLL : STA PPUSCROLL  ; scroll 0, 0
    PLA : TAY : PLA : TAX : PLA
    RTI
```

Just OAM DMA + scroll reset. No nametable transfers / general VBlank chores yet.

---

## Palette

Unified white-on-black. Both BG and sprites reference the same pattern table (pattern table 0).

`nes_chr_bg($n)` switches the BG-side 4KB CHR bank (0-7) and `nes_chr_spr($n)` switches the sprite-side 4KB CHR bank (0-7) independently (MMC1 4KB CHR banking). PPUCTRL bit 4 = 0 (BG → $0000) / bit 3 = 1 (sprite → $1000) keeps them fully separated. See [11-chr-banks](./11-chr-banks.md).

```asm
palette_data:
    .byte $0F, $30, $10, $00   ; BG palette 0  (bg=black, text=white)
    .byte $0F, $30, $10, $00   ; BG palette 1-3 (same)
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00   ; sprite palette 0
    .byte $0F, $30, $10, $00   ; sprite palette 1-3
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
```

Sprites use the font's 1bit glyph, so color 1 (white) shows and color 0 is transparent.

---

## Writing ASCII to the nametable (MVP: forced-blanking)

PPU VRAM `$2000-$23FF` is nametable 0 (32×30 tiles = 960 bytes).

### Procedure

1. Write the destination address to `PPUADDR` ($2006) high then low
2. Write tile numbers (ASCII codes) to `PPUDATA` ($2007). The VRAM-increment flag in `PPUCTRL` advances by +1 automatically

### `ppu_write_string_forced_blank`

```asm
; Inputs:
;   TMP0  ROM head address of zend_string.val[] (16 bits)
;   TMP1  len (low 2B)
; Side effects:
;   Updates PPU_CURSOR (continuation point for the next echo)
ppu_write_string_forced_blank:
    ; Set PPUADDR to PPU_CURSOR
    LDA $2002            ; reset latch
    LDA PPU_CURSOR+1     ; high
    STA $2006
    LDA PPU_CURSOR       ; low
    STA $2006

    ; Write len bytes to PPUDATA
    LDY #0
write_loop:
    LDA (TMP0),Y
    STA $2007
    INY
    CPY TMP1             ; len == Y ?
    BNE write_loop       ; (extend if len ≥ 256)

    ; Advance PPU_CURSOR
    LDA PPU_CURSOR
    CLC
    ADC TMP1
    STA PPU_CURSOR
    BCC :+
    INC PPU_CURSOR+1
:
    RTS
```

### Cursor initial position

Initialize `PPU_CURSOR` as `$2000 + row*32 + col`. In MVP, starting around row 10 col 6 (`$20C6`) keeps things readable.

### Caveats

- Hitting `PPUADDR`/`PPUDATA` outside forced blanking (`$2001 = 0`) corrupts PPU internal state
- The MVP runs the entire VM main loop in forced blanking, so this is fine
- When extension goals require dynamic echo (display updates while running), promote to NMI-synchronous

---

## Extension goal: NMI-synchronous transfer

### Problem

If the VM keeps running (in a while loop, etc.), the screen stays black during forced blanking. To show output during VM execution, we need to echo with rendering enabled.

### Solution: text-row buffer + NMI transfer

1. The `ZEND_ECHO` handler writes to a **text-row buffer in RAM** (`$0600-$06FF`) and never touches the PPU
2. The NMI handler copies the buffer to the nametable during VBlank
3. Clear the buffer after copying

### NMI handler (extended)

```asm
nmi:
    PHA
    TXA
    PHA
    TYA
    PHA

    ; OAM DMA (for sprites)
    LDA #$02
    STA $4014

    ; Transfer the text-row buffer into the nametable
    JSR flush_text_buffer

    ; Update PPU_CURSOR
    ; (Scroll etc. unnecessary in MVP)

    PLA
    TAY
    PLA
    TAX
    PLA
    RTI
```

You can transfer ~2000 bytes per VBlank (CPU cycle budget ~2273). The MVP's 32×30 = 960 chars fit in a single frame with room to spare.

---

## Real-time input API (`nes_vsync` + `nes_btn`)

`fgets(STDIN)` is a release→press blocking spec that returns one character "the moment of the press". The L3S compiler also provides a **poll-style API**:

### Intrinsics

| Function | Behavior |
|------|------|
| `nes_vsync()` | Spin until the next VBlank (NMI). If sprite_mode is off, automatically calls `enable_sprite_mode` to enable NMI + rendering. Use it when you want 1 frame = 1/60s as your sync unit |
| `nes_btn()` | **0 args**. Returns the current controller state as IS_LONG (low 1B = bitmask). Caller does bit ops (`&` / `\|`) for button checks |

### Bitmask reference

```
A     = 0x80   (bit 7)
B     = 0x40
Select= 0x20
Start = 0x10
Up    = 0x08
Down  = 0x04
Left  = 0x02
Right = 0x01
```

Use `&` to check a single bit, OR multiple bits to detect "A or L" simultaneously:
```php
$b = nes_btn();
if ($b & 0x82) { /* A or L */ }
```

### Typical game loop

```php
<?php
$x = 120; $y = 120;
nes_sprite_at(0, $x, $y, 88);
while (true) {
    nes_vsync();                   // wait one frame
    $b = nes_btn();                // poll the controller once
    if ($b & 0x02) { $x = $x - 1; }  // L
    if ($b & 0x01) { $x = $x + 1; }  // R
    if ($b & 0x08) { $y = $y - 1; }  // U
    if ($b & 0x04) { $y = $y + 1; }  // D
    nes_sprite_at(0, $x, $y, 88);  // apply
}
```

Hold a direction → coordinates change every frame = 60 px/sec continuous motion. Game-style UX that wasn't possible with the release-press `fgets` (`examples/poll.php`).

### VM-side implementation

`handle_nesphp_nes_vsync` (`vm/nesphp.s`) first checks `sprite_mode_on`; if 0, calls `enable_sprite_mode` to turn on NMI. Then:

```asm
LDA vblank_frame         ; 8-bit counter incremented in NMI
STA TMP0
:
LDA vblank_frame
CMP TMP0
BEQ :-                   ; value changed = NMI fired once
```

`handle_nesphp_nes_btn` updates the controller state via `read_controller` and writes `buttons` (ZP) into the result slot's IS_LONG low byte (0 args). Callers check bits with `ZEND_BW_AND` (the `&` operator).

### When to use which

- **`fgets(STDIN)`**: Modal UI (menus, slide transitions); confirms on a single press
- **`nes_vsync()` + `nes_btn()`**: game loops, animations, hold-to-repeat motion

You can mix both in one program (once a `nes_sprite_at` puts you in sprite_mode, NMI keeps running so both `fgets` and `nes_vsync` work).

---

## Extension goal: controller input (`fgets(STDIN)` mapping)

### How it looks in PHP

```php
<?php
while (true) {
    $key = fgets(STDIN);
    if ($key === "A") echo "A pressed";
    // ...
}
```

### Serializer fold

In opcache dumps:

```
INIT_FCALL 1 "fgets"
SEND_VAL CONST "STDIN"  (a resource constant in practice)
DO_FCALL
ASSIGN CV($key) TMP#N
```

The serializer detects this 3-instruction sequence (`INIT_FCALL`+`SEND_VAL`+`DO_FCALL`) and embeds the special built-in ID `BUILTIN_READ_INPUT` in `ZEND_DO_FCALL`'s `op1.extended_value`.

### VM-side

```asm
handle_do_fcall:
    ; op1.extended_value carries the built-in ID
    LDY #12
    LDA (VM_PC),Y
    CMP #BUILTIN_READ_INPUT
    BEQ do_read_input
    CMP #BUILTIN_SPRITE_SET
    BEQ do_sprite_set
    ; Other built-ins unsupported
    JMP handle_unimpl

do_read_input:
    JSR read_controller
    ; A holds the ASCII for the pressed button (U/D/L/R/A/B/S/T, none=0)
    ; Push it as a 1-character IS_STRING into the result slot
    ...
    JMP advance
```

### Controller read (NESdev Wiki retry version)

DPCM glitch protection — loop until the same result reads twice in a row:

```asm
read_controller:
read_loop:
    LDA #$01
    STA $4016            ; latch the controller
    LDA #$00
    STA $4016            ; start reading

    LDX #$08             ; 8 buttons
read_bit:
    LDA $4016
    LSR A                ; bit 0 → C
    ROL ctrl_temp        ; shift C into ctrl_temp
    DEX
    BNE read_bit

    ; DPCM-interference guard: read twice and trust if they match
    LDA ctrl_temp
    CMP ctrl_prev
    BNE read_loop
    STA ctrl_current

    ; Use the button-mapping table to convert a bit to ASCII
    ; Priority: A > B > Start > Select > Up > Down > Left > Right
    ...
    RTS
```

### Button → ASCII mapping

| Bit position (NES standard) | Button | ASCII |
|---------------------|--------|-------|
| 0 | A | `A` (0x41) |
| 1 | B | `B` (0x42) |
| 2 | Select | `S` (0x53) |
| 3 | Start | `T` (0x54) |
| 4 | Up | `U` (0x55) |
| 5 | Down | `D` (0x44) |
| 6 | Left | `L` (0x4C) |
| 7 | Right | `R` (0x52) |

Returns "the highest-priority new press in the last frame, as an ASCII character". If nothing is pressed, returns `IS_NULL` (PHP can wait with a `while`).

---

## Multi-sprite: `nes_sprite_at` / `nes_sprite_attr`

### PHP side

```php
<?php
// Update arbitrary OAM slot (0-63). $idx accepts runtime int
for ($i = 0; $i < 8; $i = $i + 1) {
    nes_sprite_at($i, 32 + $i*16, 100, 0xA0);
}

// Set the attribute separately (palette / flip / priority)
nes_sprite_attr(0, 0b01000001);   // bit 6=hflip, bit 0-1=palette 1
```

`nes_sprite_at($idx, $x, $y, $tile)`:
- `$idx`: 0-63 (clamped with `& 0x3F` on the VM side). Runtime int OK
- `$x` / `$y`: runtime int OK
- `$tile`: must be a literal at compile time (baked into extended_value)
- Doesn't touch the attr byte (= keeps existing value; default 0 = palette 0 / no flip / front)
- First call enters sprite_mode (rendering ON + NMI ON)

`nes_sprite_attr($idx, $attr)`:
- Both args runtime int OK
- attr byte: bit 0-1=palette / bit 5=priority / bit 6=hflip / bit 7=vflip
- This intrinsic alone doesn't enter sprite_mode (it's expected to pair with `nes_sprite_at`, which sets position)

### VM side

```asm
handle_nesphp_nes_sprite:               ; nes_sprite_at
    LDA sprite_mode_on
    BNE :+
    JSR enable_sprite_mode               ; First call: rendering + NMI on
:
    JSR resolve_op1                      ; OP1_VAL = $idx
    JSR resolve_op2                      ; OP2_VAL = $x
    JSR resolve_result                   ; RESULT_VAL = $y (reuse result slot)
    ; Read $tile literal from extended_value (TYPE_LONG check)
    ...
    LDA OP1_VAL+1
    AND #$3F                             ; clamp 0-63
    ASL A
    ASL A                                ; * 4
    TAX                                  ; X = OAM offset
    LDA RESULT_VAL+1
    STA OAM_SHADOW + 0, X                ; y
    LDA TMP2
    STA OAM_SHADOW + 1, X                ; tile
    LDA OP2_VAL+1
    STA OAM_SHADOW + 3, X                ; x (attr left untouched)
    JMP advance
```

The OAM shadow ($0200-$02FF) is DMA'd to hardware OAM by the NMI handler on the next VBlank (this happens automatically every frame after entering sprite_mode).

---

## Palette / attribute control (Phase 5E)

The PPU manages colors via 32 bytes of palette RAM ($3F00-$3F1F) and a 64-byte attribute table at the end of the nametable. nesphp exposes them through three intrinsics.

### NES palette memory map

```
$3F00: universal background color (shared across palettes)
$3F01-$3F03: BG palette 0 (colors 1, 2, 3)
$3F05-$3F07: BG palette 1
$3F09-$3F0B: BG palette 2
$3F0D-$3F0F: BG palette 3
$3F11-$3F13: sprite palette 0 (= palette 4)
$3F15-$3F17: sprite palette 1 (= palette 5)
$3F19-$3F1B: sprite palette 2 (= palette 6)
$3F1D-$3F1F: sprite palette 3 (= palette 7)
```

Each palette's color 0 ($3F04, $3F08, $3F0C, $3F10, $3F14, $3F18, $3F1C) mirrors $3F00 — effectively the same as the universal background color.

### NES color codes ($00-$3F)

```
Top 2 bits = brightness (0=dark, 1=normal, 2=bright, 3=whitish)
Bottom 4 bits = hue

  $0x: dark        $1x: normal      $2x: bright       $3x: whitish
  x0: gray         x1: blue         x2: indigo        x3: violet
  x4: magenta      x5: pink         x6: red           x7: orange
  x8: yellow       x9: yellow-green xA: green         xB: blue-green
  xC: cyan         xD: dark         xE: black mirror  xF: black mirror

  Common picks:
    $0F = black
    $30 = white
    $16 = dark red    $26 = red        $36 = bright red
    $12 = dark blue   $22 = blue       $32 = bright blue
    $1A = dark green  $2A = green      $3A = bright green
    $21 = cyan        $28 = yellow
```

### `nes_bg_color($c)` — set background color

Sets PPU $3F00 (universal background color) to a NES color code. Color 0, shared across all palettes, changes.

```php
nes_bg_color(0x0F);  // Black background (default)
nes_bg_color(0x02);  // Dark navy background
```

Direct write in forced_blanking; through the NMI queue in sprite_mode.

### `nes_palette($id, $c1, $c2, $c3)` — set palette colors

Sets palette colors 1-3. Our first 4-arg intrinsic — uses zend_op's op1/op2/result/extended_value all as inputs.

```php
nes_palette(0, 0x30, 0x16, 0x26);  // BG palette 0: white, dark red, red
nes_palette(1, 0x30, 0x2A, 0x1A);  // BG palette 1: white, green, dark green
nes_palette(4, 0x30, 0x16, 0x00);  // sprite palette 0: white, dark red, gray
```

id 0-3 is BG, 4-7 is sprite. Writes 3 bytes starting at PPU $3F01+id*4.

### `nes_attr($x, $y, $pal)` — set attribute table

Assigns a palette index (0-3) to a 2×2 tile (16×16 px) block in the BG attribute table.

```php
nes_attr(0, 0, 1);   // Top-left 16×16 px block uses BG palette 1
nes_attr(2, 3, 2);   // Block at x=2, y=3 (16×16 px) uses BG palette 2
```

x is 0-15 (32 tiles / 2), y is 0-14 (30 tiles / 2, truncated).

### How the attribute table works

The NES attribute table sits at the end of the nametable ($23C0-$23FF, 64 bytes). One byte controls a 4×4 tile (32×32 pixel) area, with 2 bits per 2×2-tile (16×16 px) sub-block:

```
1 byte = [TL:2][TR:2][BL:2][BR:2]
  bits 1-0: top-left 2×2 tile
  bits 3-2: top-right 2×2 tile
  bits 5-4: bottom-left 2×2 tile
  bits 7-6: bottom-right 2×2 tile
```

### RAM shadow (ATTR_SHADOW = $0608, 64 bytes)

Since each attribute byte packs four sub-block fields, mutating just one sub-block requires read-modify-write. PPU VRAM has a 1-cycle buffered read, so direct RMW is impractical.

nesphp keeps a 64-byte shadow in RAM ($0608-$0647):

1. `nes_attr` does read-modify-write on the shadow byte (just swap 2 bits)
2. Write the modified shadow byte to PPU $23C0-$23FF

This lets us safely change palettes per 16×16 px block.

### Combined example

```php
// Set black background
nes_bg_color(0x0F);

// BG palette 0: white text (titles)
nes_palette(0, 0x30, 0x10, 0x00);
// BG palette 1: red text (highlights)
nes_palette(1, 0x26, 0x16, 0x06);
// BG palette 2: green text (body)
nes_palette(2, 0x2A, 0x1A, 0x0A);

// Assign per row
for ($x = 0; $x < 16; $x++) {
    nes_attr($x, 0, 0);  // rows 0-1: palette 0 (white)
    nes_attr($x, 1, 1);  // rows 2-3: palette 1 (red)
    nes_attr($x, 2, 2);  // rows 4-5: palette 2 (green)
}

nes_puts(2, 0, "WHITE TITLE");
nes_puts(2, 2, "RED HIGHLIGHT");
nes_puts(2, 4, "GREEN BODY");
```

---

## Extension goal: a RAM string buffer for `ZEND_CONCAT`

A single fixed 256B buffer at `$0600-$06FF`. On `ZEND_CONCAT`:

1. Copy OP1 (IS_STRING) into the buffer
2. Append OP2 (IS_STRING)
3. Result zval: type = IS_STRING, payload = RAM buffer offset

A RAM string is **valid only within the current execution frame** (the next `ZEND_CONCAT` overwrites it). No GC needed. You can only have one RAM string at a time, but that's fine for MVP + extension stage 1.

---

## Related documents

- [02-ram-layout](./02-ram-layout.md) — RAM placement of the text-row buffer / OAM shadow / CONCAT buffer
- [03-vm-dispatch](./03-vm-dispatch.md) — How `ZEND_ECHO` calls `ppu_write_string_forced_blank`
- [04-opcode-mapping](./04-opcode-mapping.md) — Built-in folding details
