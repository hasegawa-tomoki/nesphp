# 10. Devlog: design-decision history

[← README](./README.md)

A chronological record of each phase, focused not on "what we built" but on
"**why we chose it**" and "**what we tripped on**". Specs (01-09) describe
"the current design"; this is "the thinking that led there".

---

## Phase 0: Locking down project assumptions

### The core choice: L1 vs L3 vs L4

When we say "execute PHP opcodes on a 6502", there are graduations of fidelity.

| Level | What | Verdict |
|---|---|---|
| L1 | Translate to a custom slimmed-down bytecode (custom opcode numbers too) | **Rejected** — no romance |
| L3 | Bake `zend_op` (32B) directly into ROM minus the `handler` pointer; literals are Zend's 16B `zval`; the 6502 VM reads Zend field offsets directly | **Adopted** — `xxd` reveals Zend-compatible bytes |
| L4 | L3 + keep zval as 16B in RAM, and reproduce IS_LONG in 64-bit | Rejected — runs out of 2KB RAM |

**Rationale**: L1 is easiest to implement but leaves a thin sense of "we
brought PHP opcodes". L4 immediately exhausts 2KB WRAM with 64-bit multi-byte
arithmetic + 16B RAM zval. L3 is the only intersection of "Zend-compatible
layout + executable on a 6502".

### Choosing the extraction means

| Means | Verdict |
|---|---|
| VLD extension | Needs an extra `pecl install`. Sub-candidate |
| **opcache.opt_debug_level=0x10000** | **MVP adopted** — bundled with stock PHP, no extra install |
| Custom Zend extension (C) | The ideal phase 2 — kills the text parsing layer |
| Reading opcache file cache directly | Rejected — undocumented format, depends on memory addresses |

---

## Phase 1: MVP (echo only → `hello.nes`)

### Goal

Display

```php
<?php echo "HELLO, NES!";
```

as a `.nes` in Mesen.

### Decisions

- **Lock to PHP 8.4**: opcode numbers shift across PHP minor versions, so we hard-code constants by reading `/opt/homebrew/Cellar/php/8.4.6/include/php/Zend/zend_vm_opcodes.h` directly
- **ROM layout**: iNES NROM-256 (32KB PRG + 8KB CHR), `ops.bin` in the front half ($8000-$BFFF), VM body in the back half ($C000-$FFFF)
- **CHR-ROM font**: hand-written 5×7 bitmap for 96 tiles, tile number = ASCII code. This lets us write the bytes of `zend_string.val[]` straight into the nametable
- **RAM-resident value**: keeping all 16B zval in RAM doesn't fit, so narrow to a **4B tagged value** (type 1B + payload 3B)

### Pitfall 1: divergence between spec's tentative values and the actual constants

The first edition of spec/01-rom-format.md had tentative values:

- `ZEND_ECHO = 0x28` (tentative) → **actually 0x88 (136)**
- `ZEND_RETURN = 0x3e` (tentative) → was correct (by coincidence)
- `IS_UNUSED = 8`, `IS_CV = 16` → **wrong**. Correct: `IS_UNUSED=0, IS_CV=8`

Determined them by direct grep of `zend_vm_opcodes.h` and `zend_compile.h`
during initial implementation, then corrected the spec. Rule established
since: "no tentative values; always pull from the real header".

### Pitfall 2: `xxd`'s default format

The spec said `xxd build/hello.nes | grep '28 01 08 08'`, but `xxd`'s default
2-byte grouping (`2801 0808`) means the search misses. **`xxd -g 1`** must be
specified explicitly.

### Result

`build/hello.nes` (40976 bytes):

```
strings hello.nes → HELLO, NES!
xxd -g 1 hello.nes | grep '88 01 00 00'  → ZEND_ECHO (IS_CONST)
xxd -g 1 hello.nes | grep '3e 01 00 00'  → ZEND_RETURN (IS_CONST)
```

`HELLO, NES!` shows up centered on the screen in Mesen.

---

## Phase 2: integer arithmetic + local variables (`arith.nes`)

### Goal

```php
<?php $a = 1; $a = $a + 2; echo $a;  // → 3
```

### Decisions

- **Add opcodes**: `ZEND_ASSIGN (22)`, `ZEND_ADD (1)`, `ZEND_SUB (2)`, `ZEND_QM_ASSIGN (31)`
- **Express CV / TMP slot numbers**: embed `slot_num * 16` into `op.var` (close to Zend's runtime byte-offset convention, but with the `sizeof(zend_execute_data)` offset removed)
  - The VM derives `slot * 4` with `LSR LSR` (/4) and adds it to `VM_CVBASE` → slot address of the 4B tagged value
- **Operand resolver**: generalize `resolve_op1` / `resolve_op2` to narrow `IS_CONST / IS_CV / IS_TMP_VAR / IS_VAR` all to 4B tagged values. Handlers see `OP1_VAL` / `OP2_VAL` uniformly
- **int16 → ASCII**: decimal conversion pushes digits to the 6502 stack and pops them while writing PPUDATA. divmod by 10 uses the standard shift-and-subtract

### Pitfall: integer support in echo

The `$a` in `echo $a;` is an IS_LONG (a 4B tagged value via IS_CONST or IS_CV).
Until now the ECHO handler only assumed IS_STRING, so we add an IS_LONG branch
that calls a `print_int16` routine.

`print_int16` returns the number of bytes written via `pi_count` (zero page),
and `echo_long` updates `PPU_CURSOR += pi_count`.

### Result

`arith.nes` → `3` on screen. The reality is the 6502 directly executes 5
instructions: ASSIGN → ADD → ASSIGN → ECHO (IS_LONG) → RETURN.

---

## Phase 3: control flow (`loop.nes`)

### Goal

```php
<?php $i = 0; while ($i < 5) { echo $i; $i = $i + 1; }  // → 01234
```

### Decisions

- **Add opcodes**: `ZEND_JMP (42)`, `ZEND_JMPZ (43)`, `ZEND_JMPNZ (44)`, `ZEND_IS_SMALLER (20)`, `ZEND_IS_EQUAL (18)`
- **Encoding jump targets**: opcache dumps express them as raw 4-digit op_index, e.g. `JMP 0005` / `JMPNZ T4 0002`. The serializer embeds this number as uint16 into the corresponding operand field (op1 for JMP, op2 for JMPZ/JMPNZ); operand type is `IS_UNUSED (0)`
- **VM-side computation**: `VM_PC = OPS_FIRST_OP + op_index * 24`. The multiply by 24 = 16+8 is `<<3` + `<<1` (save and add) shifts
- **is_truthy helper**: evaluate `OP1_VAL` and return A=1/0 (Z flag synced). `IS_NULL/IS_FALSE/IS_UNDEF`: falsy. `IS_TRUE`: truthy. `IS_LONG`: nonzero is truthy. `IS_STRING`: always truthy (simplified — PHP's `""`/`"0"` are falsy but unsupported)

### Discovery: while compiles as a bottom-test

opcache output:

```
0000 ASSIGN CV0($i) int(0)
0001 JMP 0005            ← jump to condition check
0002 ECHO CV0($i)        ←┐ body
0003 T2 = ADD CV0($i) int(1)  │
0004 ASSIGN CV0($i) T2   ←┘
0005 T4 = IS_SMALLER CV0($i) int(5)  ←┐ condition
0006 JMPNZ T4 0002       ←┘
0007 RETURN int(1)
```

It first jumps with `JMP 0005` to the condition block, then back to body if true.
Same structure as a C compiler's while-loop optimization.

### Pitfall: signed 16-bit comparison idiom

IS_SMALLER computes `op1 < op2` as signed 16-bit. The 6502 standard idiom:

```
SEC
LDA op1_lo ; SBC op2_lo
LDA op1_hi ; SBC op2_hi
BVC :+           ; if overflowed
EOR #$80         ; flip the sign
:
BMI is_smaller_true
```

Overflow correction is needed when the difference of two signed 16-bit values
doesn't fit in 16 bits. The `BVC + EOR #$80` combo recovers the correct sign.

---

## Phase 4: controller input (`button.nes`)

### Goal

```php
<?php echo "Press: "; $k = fgets(STDIN); echo $k;
```

Pressing a button shows the corresponding character (A/B/S/T/U/D/L/R).

### Decisions

- **Custom opcode**: `NESPHP_FGETS = 0xF0` (Zend uses 0-209, so the 0xE0-0xFF band becomes nesphp's territory)
- **Serializer pattern folding**: replace the 4-instruction sequence `INIT_FCALL "fgets" + FETCH_CONSTANT "STDIN" + SEND_VAL + DO_ICALL` with `NOP + NOP + NOP + NESPHP_FGETS`. op_index ordering is preserved (so jump targets don't break)
- **Pre-baked single-character zend_string**: `button_str_a` through `button_str_r` placed in the VM CODE segment (ca65 macro `ONE_CHAR_ZSTR`). The IS_STRING returned by fgets is the corresponding ROM offset
- **Toggle rendering on/off**: enable rendering only during fgets → wait → disable. Lets echo (forced-blanking) coexist with fgets (rendering required)
- **Controller read**: $4016 latch + shift produces a byte where bit 7=A ... bit 0=R. By priority order (A > B > S > T > U > D > L > R), the first pressed bit is mapped to a character

### Pitfall: the `opcache.file_update_protection=2` trap

Building with `touch examples/hello.php && make` produced **empty dumps**.
After hours of tracking, the cause:

- opcache's default `file_update_protection = 2` means "files newer than 2
  seconds are not cached", a race-condition guard
- Not cached = optimizer doesn't run = `opt_debug_level` doesn't run → nothing
  on stderr

Workaround: always pass `-d opcache.file_update_protection=0` in the Makefile.
This makes the optimizer run on freshly-touched files, producing dumps.

This is recorded with rationale in spec/05-toolchain.md.

### Pitfall: ECHO must reset PPUADDR

Toggling rendering on/off during fgets corrupts the PPU's internal latch
state. Subsequent ECHOes write to unintended positions.

Fix: change the ECHO handler to **always set `PPUADDR = PPU_CURSOR`**.
Previously we set it once at reset and relied on auto-increment, but to
account for cases where PPU state is corrupted, made it idempotent. At the
same time, switched the implementation to track `PPU_CURSOR += written_bytes`
in RAM.

---

## Phase 5A: tile-granularity character movement (`move.nes`)

### Goal

```php
<?php
$x = 16; $y = 14;
nes_put($x, $y, "X");
while (true) {
    $k = fgets(STDIN);
    nes_put($x, $y, " ");
    if ($k === "L") $x = $x - 1;
    // ...
    nes_put($x, $y, "X");
}
```

D-pad moves `X` in 8×8 tile units.

### Decisions

- **New custom opcode**: `NESPHP_NES_PUT = 0xF1` — takes 3 args `(x, y, char)` and writes one char to the nametable
- **Argument encoding**: op1 = x, op2 = y, extended_value = byte offset of the char literal (always `IS_CONST`)
- **`===` (IS_IDENTICAL) support**: until now `IS_EQUAL` only did byte comparison of 4B tagged values, so `button_str_l` (CODE segment) inside ROM and the user literal `"L"` (ops.bin segment) at different addresses don't match
  - → added a `values_equal_content` helper: for strings, reads `zend_string.len + val[]` and does content comparison
  - `IS_IDENTICAL` and `IS_EQUAL` share the same implementation (PHP type juggling is unsupported for simplicity)

### Pitfall: opcode variations from opcache

In opcache output, `nes_put(...)` uses `INIT_FCALL_BY_NAME` (it's not an
internal function, so not `INIT_FCALL`). And we get `_EX`-suffixed variants
like `SEND_VAR_EX` / `SEND_VAL_EX`. Extended the serializer's folding pattern:

```php
if (preg_match('/^SEND_(VAL|VAR)(_EX|_NO_REF(_EX)?)?$/', $mnemonic)) { ... }
```

Also, `DO_ICALL` (129), `DO_FCALL_BY_NAME` (131), and `DO_FCALL` (60) all fold
to the same destination.

### Pitfall: PHP runtime errors = make failure

`nes_put` doesn't exist in PHP, so after the opcache dump the PHP runtime tries
to call it and fatal-errors with non-zero exit. make's `.DELETE_ON_ERROR`
removes ops.txt, failing forever.

Fix: append `|| true` to the opcache-dump command in the Makefile, ignoring
PHP's exit code. The dump body is written to stderr before the error, so it's
preserved.

---

## Phase 5B: hardware sprite for pixel movement (`sprite.nes`)

### Goal

```php
<?php
$x = 120; $y = 120;
nes_sprite($x, $y, 65);  // 65 = 'A'
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 2;
    // ...
    nes_sprite($x, $y, 65);
}
```

`A` is shown as a sprite, moving 2 pixels at a time with the D-pad.

### Decisions

- **New custom opcode**: `NESPHP_NES_SPRITE = 0xF2`. Same 3-arg form as nes_put. Internally always operates on sprite 0
- **OAM shadow $0200-$02FF**: initialize y=$FF at reset (hides all 64 sprites off-screen)
- **NMI handler implementation**: do OAM DMA via `STA $4014` every VBlank (256-byte transfer, ~513 cycles, CPU stalls). Reset scroll to (0, 0)
- **Lazy transition via sprite_mode_on flag**: on first `nes_sprite` call:
  1. Wait for VBlank
  2. First OAM DMA (reflects the hidden sprites)
  3. Enable NMI via `PPUCTRL` bit 7
  4. Enable BG + sprite rendering via `PPUMASK`
  5. `sprite_mode_on = 1`
  Subsequent `fgets` skips the rendering toggle; rendering stays ON

### Design tradeoffs

| Option | Adopted? | Reason |
|---|---|---|
| Enable rendering + NMI immediately at reset | ❌ | Initial echo (forced-blanking premise) breaks |
| VBlank-sync all echoes | ❌ | High implementation cost; echo semantics get complex |
| **Transition on first nes_sprite** | ✅ | Matches user pattern ("initial echo → sprite infinite loop") |

**Limit**: `echo` / `nes_put` can only run **before** `nes_sprite`. Calling
them after sprite_mode kicks in writes the nametable mid-render and corrupts
the screen. Documented in the spec.

### Pitfall: 4 args don't fit in `zend_op`

Originally we considered "`nes_sprite($id, $x, $y, $tile)`" with 4 args, but
`zend_op` has only 4 fields op1/op2/result/extended_value, and result is
typically the "write-back destination", awkward to repurpose as a source.

→ Compromise: **fix sprite 0** and use 3-arg `nes_sprite($x, $y, $tile)`.
Multi-sprite is a future extension.

---

---

## Phase 5C: presentation use (`slides.nes`)

### Goal

```php
<?php
$p = 0;
while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;
    if ($p === 7) { $p = 1; }
    if ($p === 1) { nes_cls(); nes_puts(4, 4, "NESPHP PRESENTATION"); }
    if ($p === 2) { nes_puts(4, 7, "1. PHP ON FAMICOM"); }
    // ...
}
```

Each button press adds another line; reaching the end clears the screen on the
next press and starts over. Run an LT presentation deck on the NES.

### Decisions

- **Two new custom opcodes**: `NESPHP_NES_PUTS = 0xF3`, `NESPHP_NES_CLS = 0xF4`
  - `nes_puts($x, $y, "literal")`: same 3-arg pattern as nes_put. op1=x, op2=y, extended_value=zval offset of string literal. The VM writes `zend_string.len + val[]` to PPUDATA in bulk. Line wrapping is not implemented (the caller specifies y explicitly)
  - `nes_cls()`: 0 args; fills the entire nametable 0 ($2000-$23FF, 1024B) with space ($20) and resets `PPU_CURSOR` to its default
- **Serializer folding extension**: arrayize the 3-arg branch of nes_put / nes_sprite into `$customMap` to add nes_puts. nes_cls is 0-arg, so a separate branch right after DO_FCALL_BY_NAME folds it
- **Both assume forced_blanking**: same constraint as nes_put. Rendering is ON during fgets → OFF when nes_puts/nes_cls runs, so PPUDATA writes are safe. Both unavailable during sprite_mode (documented)

### Design tradeoffs

| Option | Adopted? | Reason |
|---|---|---|
| Append lines via NMI-synced echo | ❌ | Big rework that's roadmap phase 3; overkill for a deck |
| "Hardcode every line" via many nes_puts calls | ❌ | Hundreds of lines of PHP; unreadable |
| **Add nes_puts + nes_cls intrinsics** | ✅ | Direct extension of Phase 5A's folding pattern; 1-2 hours of work |
| Implement line wrapping in the VM | ❌ | Not worth the cost. For decks, explicit (x, y) per line is easier to control |

### Result

`slides.nes`: 58 ops / 19 literals / 1988-byte ops.bin. Button press shows
5 lines in order; on the 6th press it loops back. `xxd -g 1 build/slides.nes
| grep f3` / `grep f4` finds the bytes of `NESPHP_NES_PUTS` /
`NESPHP_NES_CLS`.

### Discovery: `nes_cls()` is straightforward in opcache

A 0-arg internal-like function call drops to:

```
INIT_FCALL_BY_NAME 0 string("nes_cls")
DO_FCALL_BY_NAME
```

— two instructions (no SEND_*). Folding only needs to confirm
`$pendingArgs === []`. Meanwhile `nes_puts`'s 3-string-arg form emits
`SEND_VAL_EX string("...") 3`, which the existing `parse_operand` resolves as
IS_CONST/TYPE_STRING. Minimal serializer change.

---

## Phase 3: NMI-synced writes (`livetext.nes`)

> Roadmap-wise, this was an open issue from earlier as phase 3. After Phase
> 5B (sprite_mode), the side-effect "echo / nes_put / nes_puts / nes_cls
> unavailable during sprite_mode" was deferred. The trigger to implement it
> was wanting to combine sprites and dynamic text in presentation use.

### Goal

Make `echo` / `nes_put` / `nes_puts` work during sprite_mode (rendering always
ON). The caller writes the same code as before; the VM transparently
switches between "direct write" and "NMI-synced write".

### Decisions

Adopted **the NMI-synced write queue**. The main loop just pushes entries to
`nmi_queue_write`; the actual PPU writes happen during VBlank in the NMI
handler via `flush_nmi_queue`.

- **Queue body**: 256-byte ring buffer in RAM `$0300-$03FF`
- **Format**: a sequence of `[addr_hi, addr_lo, len, data[len]]` entries
- **Head scheme**: `nmi_queue_write` (producer = main) and `nmi_queue_read` (consumer = NMI) are independent monotonic uint8s
- **Shared handler**: a `ppu_write_bytes` helper takes (TMP0=addr, TMP1=src ptr, TMP2=len) and branches on `sprite_mode_on` between direct write and queue. Three handlers (echo/nes_put/nes_puts) share it

### Alternatives considered

| Option | Adopted? | Reason |
|---|---|---|
| Briefly disable rendering → write → re-enable | ❌ | One-frame screen blank flickers; wrecks the sprite_mode experience |
| Mirror the nametable to PRG via CHR-RAM | ❌ | Mapper change + complexity; not worth it |
| **VBlank-synced write queue** | ✅ | Standard NES pattern, ~150 lines, doesn't break existing APIs |
| Double buffer (shadow nametable in VM RAM) | ❌ | Eats 2KB RAM; conflicts with nesphp's tagged-value RAM |

### Pitfall 1: `nes_cls` doesn't finish in one VBlank

Initially we designed for "NMI-sync nes_cls too", but nes_cls fills the
entire nametable 0 = 960 bytes (+ attributes 64B = 1024B) with space.

- 1 PPUDATA write = `LDA abs; STA abs` = at least 4 cycles (4 if A already holds the data)
- 1024 bytes × 4 cycles = 4096 cycles
- VBlank budget ~2273 cycles doesn't fit it in one frame

Choices:
1. Chunked clear (spread across 4 frames = 67ms)
2. Leave nes_cls unsupported in sprite_mode

Picked 2. nes_cls is only used for slide transitions, so forced_blanking-only
is enough (presentations follow the structure "initial echo for intro →
nes_sprite to interactive"). Chunked clear was deferred since it complicates
the implementation and the NMI handler's state machine.

### Pitfall 2: race on head reset

The first version had NMI reset `nmi_queue_read = nmi_queue_write = 0` at the
end of flush, reusing the buffer from index 0. This races:

```
main:  LDX nmi_queue_write   ; X = W_old
       (NMI fires here)
NMI:   flushes 0..W_old-1
       sets read = write = 0
main:  (resumes) writes bytes at positions X, X+1, ..., X+N-1
                 using the STALE X = W_old
       STX nmi_queue_write   ; write = W_old + N
```

This produces the inconsistency `read=0, write=W_old + N`; the next NMI
flushes 0..W_old+N-1 and **re-emits** the already-flushed 0..W_old-1 to PPU,
corrupting the screen.

**Fix**: don't reset head; **make both monotonic**. They wrap naturally at 256,
making the buffer a ring buffer. Aligning `NMI_QUEUE_ADDR = $0300` to a page
boundary lets `LDA NMI_QUEUE_ADDR, X`'s automatic X wrap give transparent
access even when entries straddle the end.

This change makes:
- Main only updates `write`, NMI only updates `read` → writer / reader exclusive
- Main's X cache isn't affected by NMI (NMI doesn't reset)
- Free space = `(read - write - 1) & $FF` (standard ring-buffer formula)
- If NMI advances read while main computes free, free is underestimated — only safe-side error, no corruption

About 60 lines rewritten and we got race-freedom.

### Pitfall 3: `print_int16` writes PPUDATA directly

Since Phase 2, `print_int16` had been writing digits straight to PPUDATA
during divmod. That assumes forced_blanking and fails in sprite_mode.

**Fix**: refactor `print_int16` to "write to `INT_PRINT_BUFFER = $0600`".
Returning the length via `pi_count` stays. The caller (echo_long) passes the
buffer to `ppu_write_bytes`. Now both forced_blanking and sprite_mode work.

A side effect: echo_long's structure becomes symmetric to echo_string; the
two branches merge into a common `echo_write` label (cleanup).

### Pitfall 4: meaning collision of TMP0/TMP1/TMP2 across handlers

The existing `handle_nesphp_nes_put` had TMP2 = the 1-character code, while
`enqueue_ppu_nt` uses TMP2 = len (byte length). Same zero-page bytes used
with different meanings.

**Fix**: in the nes_put handler, move the char into `INT_PRINT_BUFFER[0]` and
unify to TMP1 = INT_PRINT_BUFFER, TMP2 = 1. Now echo / nes_put / nes_puts all
delegate to `ppu_write_bytes` with the same "TMP0=addr, TMP1=src ptr,
TMP2=len" contract.

### Cascading limits unlocked

Side effects of Phase 3 implementation:

1. **Dynamic text in sprite_mode**: gamification of presentations (sprite + slides)
2. **Score/status updates in sprite_mode**: integer display via echo also works
3. **Sprite + static text coexistence**: demoed in livetext.nes

But the following stay out of scope:
- nes_cls (doesn't finish in one VBlank)
- nes_chr_bank / nes_chr_bg tearing (CHR switches apply immediately, not VBlank-synced. NMI-syncing them is a separate task; for presentation, they're only used at slide transitions, so low priority)

### Result

`build/livetext.nes`: while a sprite moves at center under user control,
A-button presses append "HIT!" lines downward. Previously, calling nes_puts
during sprite_mode would corrupt PPU latch and trash the entire screen; with
Phase 3, writes go through NMI, leaving sprites and BG intact.

Existing examples (hello/arith/loop/button/move/sprite/slides/chrdemo) all
continue to work unchanged. The forced_blanking path keeps its pre-refactor
direct-write equivalence for echo_string / echo_long / nes_put / nes_puts.

---

## Phase 3.1: nes_cls in sprite_mode (`livereset.nes`)

> An open footgun discovered immediately after Phase 3. `nes_cls` can't use
> the NMI queue (1024B / VBlank budget ~2273 cycles), so it needed a
> different approach. The trigger was wanting nes_cls for slide transitions
> in presentations.

### Issue uncovered

Phase 3 made handlers dual-path, but `handle_nesphp_nes_cls` was excluded;
calling nes_cls during sprite_mode unconditionally wrote PPUADDR / PPUDATA
directly. The actual damage:

1. `STA PPUADDR` × 2: writing PPUADDR mid-render contaminates the PPU's internal v register (overwrites $2000 directly) → scroll and current-scanline nametable reference position jump suddenly
2. `STA PPUDATA` × 1024: PPUDATA mid-render is undefined behavior. CPU's auto-increment of v collides with PPU render pipeline's v update, scattering 1024 bytes of $20 randomly into the nametable
3. ~5000 cycles ≈ 18 scanlines of visible-area corruption
4. Sprites are intact (separate OAM shadow); only BG is full of holes

### Options reviewed

| Option | Cost | Side effects | Adopted? |
|---|---|---|---|
| (A) runtime no-op guard | minimal | can't clear | ❌ functionality lost |
| (B) handle_unimpl + halt | minimal | hangs during presentation | ❌ bad UX |
| (C) compile-time error | small | nes_sprite → nes_cls flow forbidden | ❌ overkill |
| **(D) brief force-blanking** | medium | 1-2 frames black flash | ✅ **adopted** |
| (E) chunked clear via NMI queue | large | no tearing, no flash | ❌ implementation bloat, NMI state machine |

Why (D): for presentations, "slide transition = snap change" is the expected
behavior, and a 1-2 frame black flash actually serves as a transition.
Implementation cost is low and doesn't break Phase 3 design.

### Implementation: brief force-blanking

`handle_nesphp_nes_cls` checks `sprite_mode_on` at the top, and during
sprite_mode does:

```
1. Save ppu_ctrl_shadow on stack
2. Clear PPUCTRL bit 7 (disable NMI)
3. PPUMASK = 0 (stop rendering)
4. 1024B clear loop (existing code)
5. BIT PPUSTATUS → BPL to wait next VBlank
6. STA $4014 to manually run OAM DMA (compensate for NMI-disabled period)
7. PPUSCROLL = 0, 0
8. PPUMASK = %00011110 (resume rendering)
9. Restore PPUCTRL from shadow (re-enable NMI)
10. Reset PPU_CURSOR, JMP advance
```

The forced_blanking path is unchanged. With `sprite_mode_on == 0`, it stays
the original maximum-speed direct write (no impact on initial-display
hello.nes or slides.nes).

### Pitfall 1: NMI must be disabled

Initially we thought "just toggling rendering off should be enough", but
during sprite_mode NMI is auto-firing, and the NMI handler's `flush_nmi_queue`
touches PPUADDR. If it interrupts mid-clear, PPUADDR state gets corrupted and
the clear writes to unintended positions.

Solved by temporarily clearing PPUCTRL bit 7 to suppress NMI itself.
`ppu_ctrl_shadow` is PHA'd onto the 6502 stack, then atomically restored with PLA.

### Pitfall 2: must compensate OAM DMA or sprites stay stale

While NMI is disabled, automatic OAM DMA stops. For ~1-2 frames, sprites
display at the previous frame's positions (subtle, but a moving sprite shows
a visual hitch).

A single manual `STA $4014` during the clear's tail VBlank provides minimal
OAM update. Not perfect (lags by one frame), but a continuously-moving sprite
"only briefly stalls" rather than visibly hitching.

### Pitfall 3: VBlank-wait loop misses with NMI enabled

`BIT PPUSTATUS; BPL` waits for VBlank flag, but if NMI is enabled, the NMI
handler interrupts at VBlank and reads PPUSTATUS first (`BIT PPUSTATUS`),
consuming the flag. The main loop's subsequent `BIT PPUSTATUS` sees a cleared
flag and waits one more frame → flaky.

Pitfall 1's NMI-disable solves this too (no NMI interrupt = no other code
reads the flag).

### Result

`build/livereset.nes`: initial slide → sprite_mode → A press to clear screen
+ next slide draw, cycling. Sprite position is preserved; the black flash is
1-2 frames (~30ms perceived), serving naturally as "transition to next
slide".

Existing examples (hello/arith/loop/button/move/sprite/slides/chrdemo/livetext)
all continue to work unchanged. The forced_blanking path is gated behind
`sprite_mode_on == 0`, fully preserving the legacy fast direct-write behavior.

### Out-of-scope items (Phase 3.1)

- `nes_chr_bank` / `nes_chr_bg` still tear during sprite_mode. They could be
  put on the NMI queue as "CHR switch commands", but VBlank budget allocation
  and the chained re-render after switch (just bank-switching corrupts the
  picture) make a simple queue extension insufficient
- Promoting to MMC3 lets sprites and BG hold separate CHR banks, structurally
  removing "switch corrupts sprite". But mapper-implementation cost is high

---

## Phase 5D: pattern table switching (`chrdemo.nes`)

### Goal

To take presentations in the "cool" direction, we want to swap fonts/tilesets
per slide. At least 2 sets, ideally 4-8.

### Decision: combine (A) PPUCTRL bit 4 with (B) CNROM

Four options reviewed:

| Option | Granularity | Cost | Adopted? |
|---|---|---|---|
| (A) PPUCTRL bit 4 only | 2 patterns inside the same CHR | minimal (no mapper change) | ✅ |
| (B) CNROM (mapper 3) only | 4 × 8KB banks | mapper promotion | ✅ |
| (C) UxROM + CHR-RAM | unlimited, arbitrary tiles per slide | mapper implementation + RAM transfer routines | ❌ (overkill) |
| (D) MMC3 + scanline IRQ | mid-frame switching | IRQ handling, timing-sensitive | ❌ (unnecessary for a deck) |

Adopted (A) **and** (B). Combining gives **4 × 2 = 8 pattern tables**.
(A) alone is too few at 2; (B) alone lacks fine-grained switching within a
bank — they complement each other.

### Mapper promotion: NROM-256 → CNROM (mapper 3)

- iNES header: CHR size 1 → 4 (4 × 8KB), Flags 6 = `%00110000` (mapper LSB nibble = 3)
- `vm/nesphp.cfg`: CHR MEMORY area `size = $2000` → `size = $8000`
- `chr/make_font.php`: `build_bank()` per 8KB, concatenate 4 banks to produce 32KB `font.chr`

Serializer untouched (ops.bin layout unchanged).

### Pitfall: bus conflict

CNROM "latches the bank number when CPU does any STA into $8000-$FFFF". On
some real hardware, if the value being written differs from the ROM cell at
that address, the data bus drives both simultaneously and the behavior breaks.

Workaround: place a "LUT where each entry equals its index" in ROM and use
`STA cnrom_bank_lut, X`. To switch to bank 2, X=2 and A=2; the ROM's
`cnrom_bank_lut[2]` is also `$02`, so no conflict.

```asm
cnrom_bank_lut:
    .byte $00, $01, $02, $03
```

Mesen tolerates bus conflicts, but we adopt this pattern for real-hardware
compatibility.

### Introducing `ppu_ctrl_shadow`

`PPUCTRL` ($2000) is write-only, so to change just bit 4 (= preserve other
bits) there's no way to read the current value. We reserved one byte of zero
page as `ppu_ctrl_shadow` and kept it in sync with the real register on every
write.

Now `nes_chr_bg` can switch the BG pattern table without breaking the NMI
enable bit (bit 7) already set by sprite_mode. When we add the
sprite-pattern-table-switch intrinsic `nes_chr_spr` (bit 3) in the future,
the same shadow handles it.

### Auto-generation of an inverse font

To showcase (A) immediately, `make_font.php` auto-generates an "inverse
typeface" in pattern table 1:

```php
$bank[$t1 + $y] = chr($rows[$y] ^ 0xF8);  // bitwise invert in 5-pixel width
```

Space (0x20) is left as 0 to avoid filling unused nametable cells. Calling
`nes_chr_bg(1)` switches subsequent text to "highlights with a 5-pixel-wide
solid background and glyph cut-out" — usable as-is for title emphasis.

### Contents of banks 1-3

By default banks 1-3 are copies of bank 0. Edit the `$banks` array in
`chr/make_font.php` to put unique tiles in each bank.

Why we go "swap-by-default": committing demo-stage artwork (logos / decorative
fonts) won't fit future presentation content. Users should generate their own
to match their slides.

### Result

`chrdemo.nes`: a sample cycling through 5 states. Each press toggles
NORMAL → INVERSE → NORMAL → BANK1 → BANK0 → ... via `nes_chr_bg` /
`nes_chr_bank`. xxd reveals `f5 01 00 00` (NES_CHR_BANK with IS_CONST op1)
and `f6 01 00 00` (NES_CHR_BG). ROM size: 16 + 32KB PRG + 32KB CHR = 65552 bytes.

### Impact on existing examples

The mapper bump doubles built artifact size, but hello.nes / arith.nes /
loop.nes / button.nes / move.nes / sprite.nes / slides.nes all rebuild
successfully and `make verify` passes. Serializer and op_array layouts are
unchanged, so the change is zone-isolated.

---

## Cross-phase lessons

### 1. Tug-of-war between "look like Zend" and "run on a 6502"

The L3 policy locked "ROM layout to Zend-compatible", but compromised on RAM
representation as 4B tagged. The result:

- **ROM side (ops.bin)**: byte-for-byte compatible with Zend's `zend_op` / `zval` / `zend_string`
- **RAM side (VM working state)**: nesphp's own 4B tagged value

— a hybrid. The duality of "look at ROM, you see Zend; look at RAM, you see nesphp".

### 2. opcache's debug output is quirkier than expected

- `opcache.opt_debug_level=0x10000` dumps inside the optimizer; non-cacheable files don't run the optimizer
- `file_update_protection=2` (default) skips files with mtime ≤ 2 seconds
- It uses SHM for CLI, so caches should die on process exit (in theory) — but it's flaky on macOS
- Non-zero exit codes break make → defended with `|| true`

A custom Zend extension would solve all of the above, but for MVP we rode the
opcache path through.

### 3. Function-call folding: the "single-instruction" judgment

Zend function calls expand to 3-5 instructions (INIT_FCALL + SEND_* + DO_*).
Executing them per-instruction on a 6502 would need call-stack management and
get complex.

→ Consistently adopted: the serializer pattern-recognizes "function name +
argument list" and folds into **one custom opcode**. fgets / nes_put /
nes_sprite all follow this pattern.

This folding rests on "the serializer knows the function name". **Adding a
new intrinsic each time requires a serializer pattern-match update** — doesn't
scale. Future: keep a generic `DO_FCALL_BY_NAME` and look up the name in a
VM-side table (with the function-name table in ROM).

### 4. Is "Zend opcode numbers = factual data" really legally clean?

Post-Oracle v. Google, the consensus is that numerical constants aren't
copyrightable. The PHP 8.4 opcode-number list in our spec is the result of
reading `zend_vm_opcodes.h` directly — facts, not code excerpts. Judged safe
to publish under MIT (already noted in the license note in spec/README).

### 5. Honest characterization of "PHP that runs on Famicom"

What we got is the following PHP subset:

- Integers (16-bit narrow)
- Strings (immutable in ROM only, no RAM strings)
- CV / TMP / VAR slots
- if / while
- `===` / `==` / `<` (similarity comparisons)
- echo
- Intrinsics: fgets(STDIN), nes_put, nes_sprite

Can't:
- 64-bit int / double / array / object / exceptions / generators / closures
- String concatenation (ZEND_CONCAT unimplemented)
- Function definition (user-function calls limited via INIT_FCALL_BY_NAME to intrinsics)
- Dynamic echo (mid-render nametable writes unsupported)

Even so, **`strings hello.nes` shows `HELLO, NES!`, and `xxd -g 1 hello.nes |
grep '88 01 00 00'` finds the bytes of ZEND_ECHO**. That's enough for the
romance to land.

---

## Phase 5E: palette + attribute + custom tiles

### Goal

For presentations, make "colorful screens with per-line color variation"
controllable from PHP. Operate the NES's PPU palette and attribute table via
PHP intrinsics, and display simple graphics (Japanese flag) via custom tiles.

### Design choice: split into 3 intrinsics

There was an option to bundle palette ops into a single "do-it-all API", but
we mapped them naturally onto NES hardware structure and split into 3:

| intrinsic | NES hardware target | Why |
|---|---|---|
| `nes_bg_color($c)` | PPU $3F00 (universal background) | One color; one arg suffices |
| `nes_palette($id, $c1, $c2, $c3)` | PPU $3F01+id*4 (3 colors) | Per-palette-entry op. BG (0-3) / sprite (4-7) unified |
| `nes_attr($x, $y, $pal)` | attribute table ($23C0-$23FF) | Spatial color assignment. Independent of palette setup |

The split lets "change just background", "swap just a palette", "change just
per-line color assignment" each be called independently.

### Encoding 4-arg intrinsics

`nes_palette($id, $c1, $c2, $c3)` is nesphp's first 4-arg intrinsic. To fit 4
args in the 24-byte zend_op, we **repurposed the result field as input**:

```
op1            = $id   (palette number)
op2            = $c1   (color 1)
result         = $c2   (color 2)  ← typically "destination" but reused as input
extended_value = $c3   (color 3)
```

This deviates from Zend convention, but it's in the custom opcode region
(0xE0-0xFF), so it's fine. The serializer accumulates 4 elements in
`pendingArgs` and encodes them in one shot at DO_FCALL_BY_NAME.

### RAM shadow for the attribute table

The NES attribute table packs four 2×2 tile-block entries into one byte at 2
bits each. Rewriting an individual block needs read-modify-write, but PPU
VRAM has a buffered-read delay, making direct RMW awkward.

Solution: a **64-byte RAM shadow** at `ATTR_SHADOW = $0608`:

1. Initialize the shadow to $00 at boot (every block = palette 0)
2. For each `nes_attr` call: byte offset = y/2 * 8 + x/2, bit position = ((y&1)*2 + (x&1)) * 2
3. Mask the relevant 2 bits in the shadow byte → OR in the new palette number
4. Write the modified byte to PPU $23C0+offset

### Custom tile system

Added a `$customTiles` array to `chr/make_font.php`. Tile numbers 0x00-0x1F
unused by the ASCII font can now host arbitrary graphics.

The Japanese-flag demo represents a 2×2 = 16×16 pixel flag with 4 tiles
(0x01-0x04):

- **bitplane 0** (color 1) = white: flag background (entire white)
- **bitplane 1** (color 2) = red: the red disc

`nes_palette` sets color 1 = white ($30), color 2 = red ($16); `nes_put`
places tile numbers 0x01-0x04 in 2×2. Minimal graphic representation that
leverages the NES's two-bitplane scheme.

### Result

`examples/color.php` → `build/color.nes`: red title on black, white body,
green emphasis, cyan footer, plus the Japanese flag. Per-line color split is
controllable purely from PHP code.

---

## Phase W6: peek/poke + USER_RAM (avoiding zval overhead)

### Motivation: 8KB PRG-RAM exhausted in tetris Phase 5b (rotation)

Storing the 7 pieces × 4 rotations = 28 shapes as the array `$shapes = [...]`
costs `1 entry × 16B × 28 = 448 bytes` from ARR_POOL. Combined with $grid
(20 entries × 16B = 320B), that's 768B — over the ARR_POOL remaining (~460B).
op_array (296×24=7104B) + literals (40×16=640B) already occupied 7.7KB. The
rotation table won't fit.

### Comparing solutions

| Option | Verdict |
|---|---|
| 4×2 bbox 8-bit shapes only | I-piece's vertical rotation is 4×1 — doesn't fit. Rejected |
| 19 deduplicated shapes | Still 304B; doesn't fit ARR_POOL |
| Algorithmic rotation (`(x,y) → (3-y,x)` in PHP) | +30-50 ops in op_array; just barely over the limit |
| **peek/poke + USER_RAM** | **Adopted** — 1-byte representation with zero overhead per byte |

### Design

The CV symbol table ($0700-$07FF, 256B) is used only during L3S compilation;
unused at runtime. Reuse the same area as **USER_RAM** via peek/poke.

Four new intrinsics:
- `nes_peek($offset)` — return USER_RAM[$offset] as IS_LONG (one byte)
- `nes_peek16($offset)` — return little-endian 2-byte as IS_LONG
- `nes_poke($offset, $byte)` — USER_RAM[$offset] = byte (low 1B)
- `nes_pokestr($offset, $string)` — bulk-copy raw string bytes into USER_RAM

**`nes_pokestr` is the deciding factor**: a 28-rotation × 2-byte = 56-byte
shape table can be initialized with one op (= one string literal). Doing 56
separate pokes adds 56 ops to the compile-time op_array, breaking immediately.
A string puts 56 bytes in str_pool with just one op.

### Why we rejected "`$user_mem[$x]` syntax sugar"

The user proposed "writing it in PHP array syntax would be natural", but we rejected:
- Existing PHP arrays are 16B zval / ARR_POOL-managed / `count()`-able. Making `$user_mem` a byte array mixes two semantics under the same `[]` syntax
- Parser needs special-cased `$user_mem` identifier branching (emit NES_PEEK on `[]` instead of FETCH_DIM_R, etc.)
- Inconsistent with existing intrinsic patterns (`nes_put`, etc.)

**Conclusion**: function intrinsics fit current design directly. Op cost is
the same (both compile to one zend_op). Adding syntactic sugar later is
possible but not needed now.

### Phase 5b incidental fixes

Going further with rotation surfaced multiple latent bugs from tetris.php's
scaling:

1. **CV / TMP slot resolution 8-bit-only bug** (surfaced with 24 CVs in tetris): zend_op `op.var` is `slot * 16` 16-bit, but the resolver only read the low 1B. With slot ≥ 16, aliasing made `$write_row` overwrite `$grid` — severe bug. Fixed everywhere via `cv_addr_y` / `tmp_addr_y` helpers (16-bit)
2. **CMP_TMP_COUNT not reset across statements**: long programs exhausted the 64-TMP-slot ceiling. Changed `cmp_dispatch_stmt` to PHA at entry / PLA at exit. TMPs emitted in one statement die at statement boundary, so they can be reused
3. **No upper bound on op_array → corrupted CMP_LIT_STAGE**: added 16-bit bound check in `cmp_op_finish` (`HEAD < CMP_LIT_STAGE` evaluated via SBC)
4. **`nes_rand() % N` returns negative**: rand returns unsigned 16-bit, but PHP's `%` takes the dividend's sign, so high bit set → negative. Established the convention `(nes_rand() & 0x7FFF) % N` on the tetris side (documented in spec/13-compiler)

### Memory layout adjustments

Repartitioned op_array / literals / arr_pool / str_pool inside 8KB PRG-RAM
to fit Phase 5b's scale:

```
$6010-$7CFF  op_array + literals (~308 op × 24 + 40 lit × 16 ≈ 90% of 8KB)
$????-$7F7F  ARR_POOL (grows from end of literals)
$7D00-$7F7F  CMP_LIT_STAGE (during compile, 768B = 48 zval staging)
$7F80-$7FFF  STR_POOL (128B, absorbs tetris's 56-byte shape data + UI strings)
$0700-$07FF  USER_RAM (256B, reuses post-compile CV-table area)
```

Also bumped CV-table cap from 32 → 64 ($0700-$077F → entire $0700-$07FF).
tetris.php Phase 5b needs 33 CVs — 32 wasn't enough.

### Result

`examples/tetris.php`: 7-piece + 4-rotation + line clear + score + simple
game over. Phase 5a (286 ops, $shapes array) → Phase 5b (278 ops, peek16-based)
gains features with fewer ops. USER_RAM efficiency paying off.

`examples/peek_test.php`: smoke test for peek/poke/pokestr.

### Constraints remaining (Phase 5b — resolved in Phase 5c)

- Full screen redraw after line clear (200 cells) skipped due to op_array shortage → cleared rows linger as ghosts
- No GAME OVER message (just stops)
- NEXT preview / speed up unimplemented (carried to Phase 5c)

---

## Phase W7: SXROM standard-compliant (PRG-ROM 64KB / CHR-RAM 8KB / PRG-RAM 32KB)

### Motivation: ARR_POOL pressure

In Phase 5b's tetris.php, bank 0's 8KB held op_array 6.7KB + literals 640B +
header 16B + STR_POOL 128B = 7.5KB used; ARR_POOL remaining was **720B
(~45 zvals)**. `$grid` 20 rows = 320B nearly full. Phase 5c's full-redraw
addition wouldn't fit in either op count or memory.

### Design-decision arc

Started with the straightforward "I want more PRG-RAM"; through dialogue:

1. **Which mapper variant**: compared SNROM (current, 8KB), SOROM (16KB, bit 3), SUROM (PRG-ROM growth, unrelated), and SXROM (32KB, bits 2-3). Chose SXROM to 4× the PRG-RAM
2. **Bit-collision problem**: SXROM repurposes CHR bank 0 reg ($A000) bits 2-3 as PRG-RAM bank. Conflicts with current 8-CHR-bank scheme using bits 0-2
3. **Accept CHR-RAM**: standard SXROM is CHR-RAM-only 8KB. With CHR-RAM, bank switching disappears, resolving the bit conflict. The cost: total CHR 32KB → 8KB
4. **CHR data placement**: extend PRG-ROM to 64KB; place CHRDATA 16KB (4 sets × 4KB) in bank 1. `nes_chr_bg/spr` becomes a bulk transfer
5. **Defer op_array bank crossing**: op_array fits in bank 0 8KB for now, so cross-bank dispatch is future work

We also realized "current nesphp is actually SIROM-equivalent, not SNROM" (CHR-ROM
32KB + PRG-RAM 8KB + 32KB PRG-ROM combo is SIROM). The "SNROM configuration"
comment in `vm/nesphp.s` had been inaccurate for a long time.

### Bank allocation

```
PRG-RAM (32KB, 4 × 8KB):
  bank 0: op_array + literals + ARR_POOL (old) + STR_POOL  ← bank 0 = unchanged
  bank 1: ARR_POOL 8KB                                     ← arrays only
  bank 2: USER_RAM_EXT 8KB (peek/poke_ext)                 ← new
  bank 3: reserved
```

**Rationale**: "move everything but op_array to bank 1" (literals/STR_POOL/ARR_POOL
all in bank 1) hits bank-switch cost on every-opcode literals access → 30-50%
slowdown. Rejected. "Only arrays out of bank" (= option X) switches only on
array touch, holding overhead to ~10%.

ARR_POOL bank-switching follows the atomic pattern of `PRG_RAM_BANK1` at handler
entry and `PRG_RAM_BANK0` at exit (5 array handlers all updated). Dispatch loop
untouched.

### CHR-RAM impact

- At boot, bulk-transfer 8KB from PRG_BANK1 to PPU $0000-$1FFF (~50ms; trivial vs L3S compile)
- `nes_chr_bg/spr($n)` change from MMC1 register write to a 4KB bulk transfer PRG_BANK1 → PPU. Same brief force-blanking pattern as `cls_sprite_mode` (~25ms blackout / 1.5 frames) — works in both sprite_mode/forced_blanking
- chrdemo / presen* "BG inverse" effect continues working (now as CHR-set swap)
- tetris doesn't call `nes_chr_bg/spr`, so no impact

### 4 new intrinsics

For USER_RAM_EXT (bank 2, 8KB) access:
- `nes_peek_ext($ofs)` → byte
- `nes_peek16_ext($ofs)` → 16-bit LE
- `nes_poke_ext($ofs, $byte)` → write 1 byte
- `nes_pokestr_ext($ofs, $string)` → bulk copy (string ≤ 255B; built-in RAM $0600 used as relay)

Allocated opcodes 0xE8-0xEB; added INT_PEEK_EXT etc. to compiler.s.

### Phase 5b/5c reconciliation

ARR_POOL expanding to 8KB lets `tetris.php` Phase 5c (full redraw + GAME
OVER) fit in op_array. The 200-cell scan loop after line clear borrows the
`lineclear_test.php` pattern (one " " draw per cell → overwrite to "\x05" if
needed), trimming op count by removing the else branch.

### Migration cadence (8 commits)

1. Add FCEUX-based smoke test harness (regression detection)
2. PRG-ROM 32KB → 64KB (4 × 16KB banks, linker config extension)
3. CHR-RAM (iNES CHR-ROM=0 declaration, 8KB bulk transfer at boot)
4. Re-implement `nes_chr_bg/spr` as bulk transfer
5. Declare PRG-RAM 8KB → 32KB + add ZP `cur_prg_ram_bank`
6. Move ARR_POOL to bank 1 (PRG_RAM_BANK1/0 wrap on 5 handlers)
7. Add USER_RAM_EXT (bank 2) + 4 ext intrinsics
8. tetris.php Phase 5c

Smoke test (37/40 PASS, baseline maintained) ran at every step to prevent
regressions.

### Performance

- 1 bank switch = MMC1 serial write ~30 cycles
- Array handlers do 2 switches (in/out) = ~60 cycles overhead per op
- ~50 array accesses/frame in tetris → 3000 cyc/frame ≈ 1.7 ms ≈ 10% slowdown (60fps → 54fps, acceptable)

### Constraints remaining

- op_array stays bank-0-limited at **max 308 ops** (no cross-bank dispatch)
- Bank 1 access during dispatch is ARR_POOL only (escaping op_array overflow needs cross-bank PC management)
- Standard SXROM is CHR-RAM only; CHR-ROM config is non-standard. If 64KB CHR-ROM is needed in the future, branch to SOROM (CHR 8 banks retained + PRG-RAM 16KB only) or pick a different mapper

---

## Phase W8: STR_POOL bank 2 migration and NES 2.0 header

### Motivation: 128B string literal limit became visible

W7 expanded PRG-RAM to 32KB, but STR_POOL stayed locked in bank 0's
`$7F80-$7FFF` **128 bytes**. tetris.php (UI strings + 56-byte shape-table
string) just fit, but:

- `examples/color.php` (134-byte explanation strings) → ERR L78 C27 (line 78 crosses the 128B boundary; halted by `cln_string`'s overflow check)
- Tetris title `"TETRIS"` displays as bogus bytes like `EF 1F 01 00 00 00`

Two bugs surfaced. The latter is a symptom from when overflow detection was
absent; commit 3bf8e8f (string dedup + bound check) changed it to "draws but
halts on ERR", but the fundamental "**no capacity for presentation ROM**"
issue remained.

### Plan: STR_POOL-dedicated bank 1 occupancy

The first idea was "co-locate STR_POOL with bank 1 ARR_POOL", but ARR_POOL is
designed to atomically bank-switch per array handler — co-location fails (if
an array op runs while a string handler has bank 1 mapped, ARR_POOL is
unreachable). Made bank 2 **STR_POOL-dedicated** and rearranged to a
**all-4-banks-used** layout: bank 1 = ARR_POOL / bank 2 = STR_POOL / bank 3 =
USER_RAM_EXT (W7's bank 2 contents shifted to bank 3).

Bank-switch targets in `vm/nesphp.s`:

- `cln_string` (writes decoded bytes to STR_POOL during compile)
- `echo_write` (reads STR_POOL and writes to PPU for `echo`)
- `vec_string` (string equality)
- `np_from_string` (1-byte slice for `nes_put`)
- `handle_nesphp_nes_puts` (PPU bulk write source)
- `handle_nesphp_nes_pokestr` (bulk copy to USER_RAM internal RAM)
- `handle_nesphp_nes_pokestr_ext` stage 1 (STR_POOL → internal RAM. Stage 2 is bank 3)

Typical pattern: atomic `PRG_RAM_BANK2` at entry / `PRG_RAM_BANK0` at exit.
Same style as W7's ARR_POOL bank switching.

### Trap: FCEUX ignores PRG-RAM banking under iNES 1.0

After implementation, `hello.nes`'s "HELLO, NES!" rendered as bytes like
`02 00 40 00 02 00 00 00 00 00 08` — **bank 0 op_array header bytes**. Bank
switching code is correct; suspected "FCEUX is no-op'ing the banking
instructions".

Investigation revealed: **iNES 1.0 headers make FCEUX treat PRG-RAM as fixed
8KB and no-op MMC1 bank switches**. We need NES 2.0 headers explicitly
declaring 32KB PRG-RAM:

- Flags 7 = `0b00001000` (bits 2-3 = `10` → NES 2.0 marker)
- byte 10 = `$09` (PRG-RAM = 64 << 9 = 32KB volatile)
- byte 11 = `$07` (CHR-RAM = 64 << 7 = 8KB volatile)

After header rewrite, rebuilt `hello.nes` shows `48 45 4C 4C 4F 2C 20 4E 45
53 21` = "HELLO, NES!" correctly. Then 40/41 examples pass including
`color.nes` (134-byte strings) (err_syntax is intentional fail).

### Side benefit: CMP_LIT_STAGE expanded 40 → 48 zvals

The old STR_POOL area `$7F80-$7FFF` (128B) freed up, so `CMP_LIT_STAGE_END = $8000`
was raised; zval staging grew 40 → 48 entries. Slack for tetris-class
literal-heavy programs.

### Open items

- spec/02-ram-layout.md and spec/13-compiler.md bank-layout diagrams were updated (this commit)
- The `cur_prg_ram_bank` ZP is meant for "remember the current bank before re-entering dispatch loop", but currently every handler restores bank 0 at exit — so it's **effectively unused**. Future cross-bank optimizations could revive it; for now, dead-code-ish
- op_array cross-bank dispatch remains unimplemented since W7. With banks 2/3 occupied by STR_POOL/USER_RAM_EXT, cross-bank dispatch to allow op_array > 8KB later means **adding bank 4+ (= SXROM 32KB → 64KB?)** or escaping opcodes into PRG-ROM banks

---

## Related documents

- [01-rom-format](./01-rom-format.md) — current ROM binary spec
- [04-opcode-mapping](./04-opcode-mapping.md) — implemented opcode list
- [07-roadmap](./07-roadmap.md) — per-phase progress
- [09-verification](./09-verification.md) — acceptance criteria for each demo
