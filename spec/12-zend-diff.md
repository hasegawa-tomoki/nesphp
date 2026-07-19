# 12. Comparison with the original Zend: nesphp's modifications

[← README](./README.md) | [← 01-rom-format](./01-rom-format.md) | [← 10-devlog](./10-devlog.md)

This document is a side-by-side comparison of "**the original Zend opcode /
zval / zend_string / op_array structures** vs. **how nesphp modified them to
fit a 6502 ROM**". The byte-level layout spec is owned by
[01-rom-format](./01-rom-format.md) as the single source of truth; this
document is the architectural rationale and design decisions behind it.

References (upstream definitions):
- [php-src Zend/zend_compile.h](https://github.com/php/php-src/blob/master/Zend/zend_compile.h) — `struct _zend_op`, `union znode_op`, `IS_CONST`, etc.
- [php-src Zend/zend_types.h](https://github.com/php/php-src/blob/master/Zend/zend_types.h) — `struct _zval_struct`, `struct _zend_string`
- [php-src Zend/zend_vm_opcodes.h](https://github.com/php/php-src/blob/master/Zend/zend_vm_opcodes.h) — opcode constants

---

# The original Zend opcode format (PHP 8.4)

## `struct _zend_op` (32 bytes on 64-bit)

The actual definition in `Zend/zend_compile.h`:

```c
struct _zend_op {
    const void    *handler;       // 8B  C function pointer to handler
    znode_op       op1;           // 4B  first operand (union)
    znode_op       op2;           // 4B  second operand (union)
    znode_op       result;        // 4B  result destination (union)
    uint32_t       extended_value;// 4B  extra info (third arg / flags / etc.)
    uint32_t       lineno;        // 4B  PHP source line number (debug)
    zend_uchar     opcode;        // 1B  instruction number
    zend_uchar     op1_type;      // 1B  operand kind (IS_CONST etc.)
    zend_uchar     op2_type;      // 1B
    zend_uchar     result_type;   // 1B
};
```

### Why the `handler` field is first

Zend uses **direct-threaded / call-threaded dispatch**, so during opcache
compilation it bakes a C handler function pointer into `handler` for each
opcode. At runtime:

```c
for (;;) {
    ((zend_vm_handler)(opline->handler))();
    if (done) break;
}
```

That is, dispatch is just a `handler()` call, not a switch on the opcode byte
(some build configurations choose GOTO / SWITCH variants instead). Because the
"call the handler directly" model is the heart of PHP VM speed, `handler` is
placed at the **beginning** of the struct for cache hit optimization.

### `znode_op` (4-byte union)

```c
typedef union _znode_op {
    uint32_t constant;   // byte offset into the literals array
    uint32_t var;        // byte offset of a slot in execute_data
    uint32_t num;        // generic number (arg count etc.)
    uint32_t opline_num; // index into op_array->opcodes[]
    uint32_t jmp_offset; // runtime byte offset for JMP
} znode_op;
```

The 4 bytes change meaning by context. The neighboring `*_type` field decides
which interpretation is used (`IS_CONST` → constant, `IS_CV` → var, `IS_UNUSED`
→ num / jmp_offset).

### Operand types (`Zend/zend_compile.h`)

| Value | Name |
|---|---|
| 0x00 | `IS_UNUSED` |
| 0x01 | `IS_CONST` |
| 0x02 | `IS_TMP_VAR` |
| 0x04 | `IS_VAR` |
| 0x08 | `IS_CV` |

## `struct _zval_struct` (16 bytes)

> **Why zval shows up here**: when `*_type` of `zend_op.op1` is `IS_CONST`,
> those 4 bytes are "a byte offset into the literals array (= an array of
> `zval`)". So **understanding the operand requires knowing the layout of an
> element of literals = `zval`**. `zend_op` doesn't stand alone; references
> chain into `zval`, and from there into `zend_string` for strings.

`Zend/zend_types.h`:

```c
struct _zval_struct {
    zend_value    value;   // 8B union (lval/dval/str/arr/obj/...)
    union {
        uint32_t  type_info;
        struct {
            zend_uchar type;       // ← type ID in the low byte
            zend_uchar type_flags;
            union { uint16_t extra; } u;
        } v;
    } u1;                  // 4B
    union {
        uint32_t  next;
        uint32_t  cache_slot;
        // ... 10+ different uses
    } u2;                  // 4B
};
```

Inside the `value` union:

```c
typedef union _zend_value {
    zend_long        lval;   // 8B signed integer (int64 on 64-bit builds)
    double           dval;   // 8B IEEE 754
    zend_string     *str;    // 8B pointer
    zend_array      *arr;    // 8B pointer
    zend_object     *obj;    // 8B pointer
    /* ... */
} zend_value;
```

Type IDs (`Zend/zend_types.h`):

| Value | Name |
|---|---|
| 0 | `IS_UNDEF` |
| 1 | `IS_NULL` |
| 2 | `IS_FALSE` |
| 3 | `IS_TRUE` |
| 4 | `IS_LONG` |
| 5 | `IS_DOUBLE` |
| 6 | `IS_STRING` |
| 7 | `IS_ARRAY` |
| 8 | `IS_OBJECT` |
| ... | ... |

## `struct _zend_string` (24-byte header + variable-length body)

When zval has type `IS_STRING`, `value.str` points at:

```c
struct _zend_string {
    zend_refcounted_h gc;    // 8B  refcount:4 + type_info:4
    zend_ulong        h;     // 8B  DJBX33A hash
    size_t            len;   // 8B  byte length
    char              val[1];// flex, NUL-terminated + alignment
};
```

The low bits of `gc.type_info` carry flags like `IS_STR_INTERNED` /
`IS_STR_PERMANENT`. In particular the **IMMUTABLE flag (0x40)** means "exempt
from GC, don't touch refcount".

## `struct _zend_op_array` (original: hundreds of bytes)

The upper container that wraps the opcode body. It's huge; an excerpt:

```c
struct _zend_op_array {
    /* Common fields with zend_internal_function */
    zend_uchar type;
    zend_uchar arg_flags[3];
    uint32_t fn_flags;
    zend_string *function_name;
    zend_class_entry *scope;
    zend_function *prototype;
    uint32_t num_args;
    uint32_t required_num_args;
    zend_arg_info *arg_info;
    HashTable *attributes;
    uint32_t T;
    /* op_array specific */
    uint32_t *refcount;
    uint32_t last;
    zend_op *opcodes;       // ← pointer to opcode array
    int last_var;
    uint32_t T_liveranges;
    zend_string **vars;     // CV variable names
    int last_literal;
    uint32_t num_dynamic_func_defs;
    zval *literals;         // ← pointer to literals array
    int cache_size;
    void **run_time_cache;
    zend_string *filename;
    uint32_t line_start;
    uint32_t line_end;
    zend_string *doc_comment;
    /* ... */
};
```

Dozens of fields, many heap pointers, runtime cache, attributes. Members vary
slightly across library versions.

---

# nesphp's modifications

To run on a 6502 with **2KB RAM + 32KB PRG-ROM**, we change the following.
Policy: **"keep the ROM side as Zend-compatible as possible; the RAM side can
go its own way"** (L3 fidelity).

## Modification 1: drop `handler` / `lineno` + compress each znode_op 4B → 2B (32B → 12B)

```
Zend original     nesphp (current 12B compressed)
offset  field     offset  field
  0     handler (8B)  ---   (dropped)
  8     op1 (4B)     0      op1 (2B, low 2B only)
 12     op2 (4B)     2      op2 (2B)
 16     result (4B)  4      result (2B)
 20     ext_v (4B)   6      extended_value (2B)
 24     lineno (4B)  ---    (dropped)
 28     opcode (1B)  8      opcode
 29     op1_type     9      op1_type
 30     op2_type    10      op2_type
 31     result_type 11      result_type
```

**Reason (handler dropped)**: `handler` is **a pointer to a host (x86/ARM) C
function** — it has zero meaning on a 6502. opcache resolves `handler` only
at load time, and structurally "fetch the next opcode byte and dispatch" is
equivalent — so it can be dropped **without information loss**.

**Reason (lineno dropped)**: the NES VM has no mechanism to display line
numbers at runtime (the compile-error path uses `CMP_LINE` separately).
A debug-only lineno is dropped under **ROM size constraints**.

**Reason (znode_op 4B → 2B compression)**: the VM only reads the low 2B in practice:
- `constant`: the literal area tops out well under 4KB (host L3: ~48 zvals × 16B; L3S: up to 192 × 4B tagged) → 12 bits suffice
- `var`: slot number × 4 (was × 16 before the 4B migration), max 64 slots → 256 = 8 bits
- `jmp_offset`: op_index, max ~617 ops → 10 bits

To overcome the situation where tetris.php's op_array filled 97.8% of PRG-RAM
bank 0 (8KB), we compressed 24B → 12B. The VM handlers reference the
`ZOP_*` symbols (ZOP_OP1=0, ZOP_OP2=2, ZOP_RESULT=4, ZOP_EXT=6, ZOP_OPCODE=8,
ZOP_*_TYPE=9..11, ZOP_SIZE=12) at the top of `vm/nesphp.s`, so future
expansion / compression only changes one constant. Tetris went from 97.8% to
roughly 53%.

The 6502 VM's dispatch loop reads the opcode byte (offset 8) and switches a
16-bit `JMP` target — interpretable as "the NES version where the handler
call has been precomputed".

## Modification 2: narrow `IS_LONG` to 16 bits

| | Zend original | nesphp |
|---|---|---|
| `value.lval` | int64 (64-bit build) | low 16 bits only, sign-extended |
| Range | `-9.2×10^18 .. +9.2×10^18` | `-32768 .. +32767` |
| Out of range | runs as-is | **serializer compile error** |

**Reason**: 64-bit arithmetic on the 6502 is 8 bytes × many instructions per
op → multiplier/divider routines of hundreds of ROM bytes. With 16-bit,
ADD/SUB runs in 6-8 instructions.

In the host L3 format the physical zval layout is **kept at 16B**; nesphp only
reads the low 2 bytes of the `value` union, and the remaining bytes are
"padding for Zend compatibility". (In L3S the compiler drops that padding
entirely — literals live in PRG-RAM as 4B tagged, see Modification 8.)

## Modification 3: `IS_DOUBLE` / `IS_ARRAY` / `IS_OBJECT` are unsupported

The serializer raises a compile error the moment it sees any of these literals.

| type | If present in ROM | Reason |
|---|---|---|
| `IS_DOUBLE` | compile error | softfloat routines (1-2KB) are too heavy |
| `IS_ARRAY` | compile error | `HashTable` 56B + bucket 36B doesn't fit in 2KB RAM |
| `IS_OBJECT` | compile error | same, internally has a `HashTable` |

The zval type-ID numbers match Zend, leaving the door open to add them later
without ID collisions.

## Modification 4: redefine `value.str` from "pointer" to "ROM offset"

Zend original:
```
zval.value.str = zend_string * (64-bit pointer in host address space)
```

nesphp:
```
zval.value.str = uint16 byte offset (relative to the start of ops.bin)
```

Of the 8 bytes in `value`, only the **low 2 bytes** are used; the remaining 6
bytes are 0. The VM restores the absolute address with `LDA value.str; ADC #<OPS_BASE`.

**Reason**: The 6502 doesn't have 64-bit pointers, let alone a 32-bit address
space. uint16 offsets relative to ROM start are sufficient. The 16B zval
layout stays; only the **meaning** of the value changes.

## Modification 5: `zend_string.hash` is hardcoded to 0

Zend original: a 64-bit hash computed by `DJBX33A` is stored in `h`.
nesphp: always 0.

**Reason**: nesphp has no HashTable, so there's no context where the hash is
read (not for array keys, not for string interning). Computation cost zero,
and 8 bytes of garbage stay in ROM. We keep the field for Zend compatibility.

## Modification 6: `gc.refcount` hardcoded to 0, `type_info` set to `IMMUTABLE` (0x40)

Every `zend_string` is **immutable in ROM**, so refcount manipulation is
meaningless. Even Zend itself doesn't touch the refcount on `IS_STR_PERMANENT`
or `IMMUTABLE` strings, so this matches the "CONST string in Zend" handling.

## Modification 7: complete replacement of the `op_array` header

Zend's `zend_op_array` is a giant struct of hundreds of bytes (filename,
function_name, scope, arg_info, run_time_cache, attributes, ...). Bringing
that to a 6502 is impractical, so we replaced it with a **custom 16-byte
header**:

```
offset  size  field
  0     2     num_opcodes
  2     2     literals_off
  4     2     num_literals
  6     2     num_cvs
  8     2     num_tmps
 10     1     php_version_major
 11     1     php_version_minor
 12     4     reserved
```

Zend compatibility ends at **the `zend_op` body and the zval / zend_string
chain**; the container (op_array) is bespoke. This boundary is the actual
limit of what nesphp calls "L3" (going to L4 would mean making op_array
Zend-compatible, which is impossible).

**Only `php_version_major/minor` is original**: PHP minor versions shift
opcode numbers, so it's the version-lock guard that halts the VM at boot if
not 8.4. Zend has **no equivalent** (PHP at runtime knows its own version, so
it's unneeded), but on nesphp the ROM and VM are locked at build time, making
this essential.

## Modification 8: in-RAM zval representation 16B → 4B tagged value

This isn't a ROM-layout change but a **runtime modification** — important
enough to mention.

Zend original keeps execute_data CV / TMP / VAR slots as 16B zvals. nesphp
compresses them to a **4-byte tagged value** under the 2KB RAM constraint:

```
byte 0: type ID (TYPE_LONG / TYPE_STRING / TYPE_TRUE / ...)
byte 1-2: low 16 bits of payload (IS_LONG value or zend_string ROM offset)
byte 3: extra (unused)
```

Since the 4B literal migration (2026-07-19), the L3S on-NES compiler also
stores **literals** in PRG-RAM pre-narrowed to 4B tagged (`[v0, v1, v2, type]`
— type at offset 3), and `resolve_op1` / `resolve_op2` read that layout
directly. The fetch-time "read 16B, narrow to 4B" translation now exists only
conceptually for the L3 host format. As a result:

- **Host oracle (`.host.ops.bin`)**: stays in Zend's 16B zval layout
- **PRG-RAM literals (L3S)**: 4B tagged zval
- **RAM (`$0400`-`$05FF`)**: nesphp's own 4B tagged value

The duality of "look at ROM and you see Zend; look at RAM and you see nesphp".
Details of the RAM side are in [02-ram-layout](./02-ram-layout.md), and the
history is in [10-devlog](./10-devlog.md) "Cross-phase lessons".

## Modification 9: custom opcode band added (0xF0-0xF6)

Less of a "modification" than an extension. The 0xE0-0xFF band that Zend
doesn't use is filled with seven nesphp-specific instructions, and the
serializer folds `fgets()` / `nes_*()` function-call patterns into them
(`NESPHP_FGETS=0xF0`, etc.).

The struct layout is untouched; only the `opcode` byte numbers grow. The VM
dispatch treats "standard Zend opcodes and custom ones the same way: the
single main_loop `CMP` chain branches both". See [04-opcode-mapping](./04-opcode-mapping.md)
for the full list.

## Modification 10: omit the `zend_string` struct (L3S only)

**This modification applies only to the on-NES compiler path (L3S)**. The
host `serializer.php` path (L3) still bakes the 24B `zend_string` header into
ROM as before.

In L3S, no `zend_string` struct represents a string literal — the zval's
`value` field directly carries (ROM offset, length):

```
L3 (host):
  zval.value.str (8B) → zend_string in ROM (24B header + val[] + null)
                        └─ len at offset 16
                        └─ val[] from offset 24

L3S (on-NES):
  zval.value bytes 0-1 → val[] start in ROM (16-bit offset relative to OPS_BASE)
  zval.value bytes 2-3 → length (16-bit)
  No zend_string header
```

**Reason**: L3S bakes the PHP source as raw ASCII into ROM, so the val[] of
each string literal **already exists in the ROM** as the body inside the
source's `"..."`. Burning an extra 24B header would make the header's `len`
and the val[] body just duplicate the PHP source string bytes. `strings
hello.nes` would show "HELLO, NES!" twice, undermining the "ROM = the PHP
source itself" romance axis.

Concrete effects of the omission:

| Aspect | L3 | L3S |
|------|-----|-----|
| `strings` occurrences | source 1 + pool 1 = 2 | source 1 |
| ROM use | PHP source + 24B header × num strings + duplicated body | PHP source only |
| VM `echo_string` | Navigates zend_string header (LDY #16 / ADC #24) | Reads 4B tagged directly (simpler) |
| L3 fidelity | Full | Partial deviation (no zend_string) |
| zval 16B layout | Preserved | Replaced by 4B tagged literals (since 2026-07-19; earlier L3S kept 16B with changed **meaning** of the value union) |

The 4B tagged value (RAM) also changes: byte 3 is unused under L3 but in L3S
**carries the length when type is IS_STRING** (see [02-ram-layout](./02-ram-layout.md)).

The string-related handlers in `vm/nesphp.s` (`echo_string` / `vec_string` /
`handle_nesphp_nes_put` / `handle_nesphp_nes_puts`) have been rewritten for
L3S. Whether L3 (host path) can read the same binary requires a
serializer-side change to write length into bytes 2-3 of the 16B zval (the
host path's maintenance policy is undecided; we'll align
[13-compiler](./13-compiler.md) and `serializer.php` upon completing M-E).
The 4B literal migration (2026-07-19) widened the gap further: the VM's
resolvers now expect 4B tagged literals (type at offset 3), so executing the
host path's 16B-literal binary would additionally require the serializer to
emit 4B literals, or a resolver-side compatibility shim. `.host.ops.bin`
today is an **op-sequence oracle only**, not a VM-loadable image.

The single source of truth for this spec is [13-compiler](./13-compiler.md);
see there for byte-level detail.

---

# Summary: what stayed, what changed

| Item | Zend original | nesphp | Compatibility |
|---|---|---|---|
| `zend_op` size | 32B | 12B | handler / lineno dropped + each znode_op compressed 4B → 2B. **Zend offset compatibility was abandoned** (see Mod 1) |
| Each `zend_op` field meaning | as is | as is | ✅ byte-for-byte |
| `zval` size | 16B | L3 `.host.ops.bin`: 16B / L3S PRG-RAM literals: 4B tagged | ✅ (L3) / ❌ (L3S) |
| `zval.value` interpretation | 8-byte union | low 2 bytes only | low used, upper zero-padded |
| `IS_LONG` precision | 64-bit | 16-bit narrow | meaning shrunk |
| `IS_DOUBLE` / `IS_ARRAY` / `IS_OBJECT` | supported | compile error | dropped |
| `zend_string` header | 24B | L3: 24B / **L3S: omitted** | L3 layout-compatible / L3S puts (offset, length) directly in zval |
| `zend_string.hash` | computed | L3: hardcoded 0 / L3S: — | L3 layout-compatible, value meaningless |
| `zend_string.val[]` | UTF-8 etc. | ASCII only | character-set restricted |
| `zend_op_array` header | hundreds of bytes | 16B custom | ❌ **complete replacement** |
| CV / TMP slot (RAM) | 16B zval | 4B tagged value | ❌ different format |
| 4B tagged value byte 3 | — | L3: unused / **L3S: length on IS_STRING** | L3S-specific meaning |
| Custom opcodes | — | 0xF0-0xF9 added | borrows the unused Zend band |

In the end, the **core** of nesphp's claim to Zend compatibility is:

1. The **12B `zend_op` structure** (handler/lineno dropped + each znode_op compressed
   4B→2B) sits in ROM with the same field order/offsets as Zend
2. The 16B `zval` layout is preserved in the host L3 oracle (with degraded
   usage of the contents; the live L3S path narrows literals to 4B tagged)
3. The 24B `zend_string` header layout is preserved (host L3 only; L3S omits it)
4. Opcode numbers (`0x88 = ZEND_ECHO`, etc.) match PHP 8.4

Thanks to those four points:

- `xxd -g 1 build/hello.nes | grep '88 01 00 00'` reveals the byte sequence of ZEND_ECHO
- `strings build/hello.nes | grep HELLO` finds the string body as-is
- Looking at PHP 8.4's `zend_vm_opcodes.h` directly tells you nesphp's opcode numbers

That's where the romance lives. Conversely, the op_array container and the
in-RAM zval are pragmatically replaced — that's the actual design line.

---

## Related documents

- [01-rom-format](./01-rom-format.md) — strict byte-level spec for the "nesphp side" of this comparison
- [02-ram-layout](./02-ram-layout.md) — Mod 8's 4B tagged value detail (incl. L3S byte 3)
- [04-opcode-mapping](./04-opcode-mapping.md) — Zend opcode numbers + nesphp custom opcode list
- [10-devlog](./10-devlog.md) — L1 / L3 / L4 fidelity choices and per-phase design history
- [11-chr-banks](./11-chr-banks.md) — CNROM mapper promotion (a separate axis from ROM layout)
- [13-compiler](./13-compiler.md) — Single source of truth for L3S (on-NES compiler), Mod 10 detail
