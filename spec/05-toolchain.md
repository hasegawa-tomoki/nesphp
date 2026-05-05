# 05. Toolchain and build pipeline

[← README](./README.md) | [← 04-opcode-mapping](./04-opcode-mapping.md) | [→ 06-display-io](./06-display-io.md)

## End-to-end flow

```
input.php
   │
   ▼ (1) Extract: opcache.opt_debug_level (MVP) / nesphp_dump.so (Phase 2)
ops.txt (or ops.bin)
   │
   ▼ (2) Serialize: serializer.php
ops.bin (L3 ROM image, follows [01-rom-format](./01-rom-format.md))
   │
   ▼ (3) Assemble: ca65 vm/nesphp.s
nesphp.o
   │
   ▼ (4) Link: ld65 -C vm/nesphp.cfg (.incbin "ops.bin")
nesphp.nes
```

A `Makefile` pattern rule does it in one shot (`make build/NAME.nes` runs all of (1)-(4) from examples/NAME.php to .nes).

---

## (1) Extraction layer

### MVP: opcache.opt_debug_level

```bash
php -dopcache.enable_cli=1 \
    -dopcache.opt_debug_level=0x10000 \
    examples/hello.php 2> build/ops.txt > /dev/null
```

- Bundled with stock PHP 8.4, no extra install required
- Dumps a textual representation to stderr
- Format example:
  ```
  $_main:
       ; (lines=2, args=0, vars=0, tmps=0)
       ; (after optimizer)
       ; /tmp/test.php:1-1
  0000 ECHO string("HELLO, NES!")
  0001 RETURN int(1)
  ```
- Operands carry type prefixes: `string("...")` / `int(N)` / `CV($var)` / `TMP#N` / `V#N`

### Phase 2: a custom Zend extension `nesphp_dump.so`

About 300 lines of C. Calls `zend_compile_file()`, gets the `zend_op_array*`, and walks `opcodes[]` and `literals[]` directly to emit a binary.

- Emits bytes that match `spec/01-rom-format.md` directly
- Lets us delete the text-parser layer in serializer.php entirely
- **Maximum romance**: "Our extension snatches the `zend_op` that the Zend engine emitted, binary-encodes it, and the 6502 interprets it"

PHP extension build is `phpize && ./configure && make`; we version-check at compile time via `PHP_API_VERSION`.

---

## (2) Serializer layer: `serializer.php`

Responsibilities:

1. Parse `ops.txt` (the opcache text)
2. Reference the number table in `spec/04-opcode-mapping.md` to convert mnemonics into Zend opcode numbers
3. Pack literals into 16B zvals by type
4. Add string literals to the string pool as `zend_string` (24B header + content)
5. Resolve CONST operand offsets relative to literals_off
6. Embed jump targets (`JMP 0003` etc.) as uint16 indices
7. Detect built-in patterns (`INIT_FCALL "fgets"` + `DO_FCALL`) and fold into special IDs
8. Pack op_array header + opcodes + literals + string pool into a single `ops.bin`
9. Abort with a compile error on unsupported opcodes / literal types

### Single-file structure

```
serializer/
  serializer.php     ~600 lines (target)
  composer.json      (zero deps, ~10 lines)
```

We **don't use** external libraries like nikic/php-parser (preserves the romance).

### Internal modules (within one file)

- `Parser` — opcache text-dump parsing
- `ZendOp` — `zend_op` data class
- `ZendZval` — `zval` data class
- `ZendString` — string pool management
- `OpcodeTable` — mnemonic → number per `spec/04-opcode-mapping.md`
- `RomEmitter` — emits the binary byte stream
- `BuiltinFolder` — folds `INIT_FCALL` patterns

---

## (3) Assembler layer: ca65

- `vm/nesphp.s` — VM core (reset/NMI/dispatch/handlers)
- `vm/nesphp.cfg` — ld65 memory layout (NROM 32KB + 8KB CHR)
- `chr/font.chr` — 96-tile ASCII CHR binary (`.incbin`)

### Build

```bash
ca65 --target none vm/nesphp.s -o build/nesphp.o
ld65 -C vm/nesphp.cfg build/nesphp.o -o build/nesphp.nes
```

`.incbin "build/ops.bin"` embeds the serializer output into the ROM.

### ld65 memory layout (nesphp.cfg)

```
MEMORY {
    HEADER: start=$0,      size=$10,   type=ro, file=%O, fill=yes;
    PRG:    start=$8000,   size=$8000, type=ro, file=%O, fill=yes;
    CHR:    start=$0000,   size=$2000, type=ro, file=%O, fill=yes;
    ZP:     start=$0000,   size=$100,  type=rw, define=yes;
    RAM:    start=$0200,   size=$600,  type=rw, define=yes;
}
SEGMENTS {
    HEADER:  load=HEADER, type=ro;
    OPS:     load=PRG,    type=ro, start=$8000;
    CODE:    load=PRG,    type=ro, start=$C000;
    VECTORS: load=PRG,    type=ro, start=$FFFA;
    CHARS:   load=CHR,    type=ro;
    ZEROPAGE:load=ZP,     type=zp;
    BSS:     load=RAM,    type=bss, define=yes;
}
```

(Actual values are tuned during implementation.)

---

## (4) Integrated build: `Makefile`

A pattern rule chains (1)-(4):

```makefile
$(BUILD_DIR)/%.ops.txt: examples/%.php | $(BUILD_DIR)
	$(PHP) -d opcache.enable_cli=1 \
	       -d opcache.file_update_protection=0 \
	       -d opcache.opt_debug_level=0x10000 \
	       $< 2> $@ > /dev/null

$(BUILD_DIR)/%.ops.bin: $(BUILD_DIR)/%.ops.txt $(SERIALIZER)
	$(PHP) $(SERIALIZER) $< $@

$(BUILD_DIR)/%.o: $(VM_SRC) $(BUILD_DIR)/%.ops.bin $(CHR_FONT) | $(BUILD_DIR)
	cp $(BUILD_DIR)/$*.ops.bin $(BUILD_DIR)/ops.bin
	$(CA65) $(VM_SRC) -o $@

$(BUILD_DIR)/%.nes: $(BUILD_DIR)/%.o $(VM_CFG)
	$(LD65) -C $(VM_CFG) $< -o $@
```

### Why `opcache.file_update_protection=0`

opcache's default (`=2`) is the "files newer than 2 seconds are skipped — neither optimizer nor cache" race-condition guard. That kicks in for the typical **`touch example.php && make`** edit flow and silently empties the dump. nesphp disables it across the board.

It doesn't matter for our flow (one stock CLI process per compile).

### Usage

```bash
make                     # Default: build/hello.nes
make build/foo.nes       # examples/foo.php → build/foo.nes
make verify              # L3 romance verification
make clean               # Remove build/
```

---

## Why version-lock PHP

### Zend opcode numbers shift

The constants in `php-src/Zend/zend_vm_opcodes.h` may renumber across PHP releases. The opcode table in [04-opcode-mapping](./04-opcode-mapping.md) (referenced by serializer and VM) **must be pinned to a specific version**.

### `zend_op` layout shifts

PHP build settings (ZTS/NTS, 32/64-bit, debug/release) change struct padding and union sizes. The 12B compressed layout in `spec/01-rom-format.md` assumes the host-side `serializer.php` reads the 32B `zend_op` from a **NTS x64 PHP 8.4 release build** and extracts the lo 2B of each znode_op.

### Choice: PHP 8.4

- Close to the latest stable at the time of writing (2026-04)
- `brew install php` gives it
- 8.3 / 8.5 compatibility is not guaranteed

### Runtime check

- The VM checks `php_version_major=0x08, php_version_minor=0x04` in the op_array header at boot. Mismatch → on-screen error & halt
- The serializer reads `php -v` and aborts early if it isn't 8.4.x

---

## Required installs

```bash
brew install php       # 8.4.x
brew install cc65      # ca65 + ld65
brew install mesen     # (optional) debugging emulator
```

Verify with `php -v` and `ca65 --version`.

---

## Related documents

- [00-overview](./00-overview.md) — Big picture of the 3-layer architecture
- [01-rom-format](./01-rom-format.md) — Binary spec the serializer outputs
- [04-opcode-mapping](./04-opcode-mapping.md) — Opcode number table
- [07-roadmap](./07-roadmap.md) — Implementation step order
