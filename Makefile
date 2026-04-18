# nesphp Makefile
# spec/05-toolchain.md, spec/07-roadmap.md
#
# 使い方:
#   make                     デフォルト: build/hello.nes を作る
#   make build/NAME.nes      examples/NAME.php から build/NAME.nes を作る
#   make verify              hello.nes に対する L3 ロマン検証
#   make clean               build/ を消す

PHP        := php
CA65       := ca65
LD65       := ld65

SERIALIZER := serializer/serializer.php
PACK_SRC   := tools/pack_src.php
VM_SRC     := vm/nesphp.s
VM_SRCS    := vm/nesphp.s vm/compiler.s
VM_CFG     := vm/nesphp.cfg
CHR_FONT   := chr/font.chr
BUILD_DIR  := build

# --- PHP version lock (spec/05-toolchain.md) ---
PHP_VERSION := $(shell $(PHP) -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)
ifneq ($(PHP_VERSION),8.4)
$(error PHP 8.4 required, found [$(PHP_VERSION)])
endif

EMULATOR   := fceux

.PHONY: all verify clean run
.DELETE_ON_ERROR:
# 中間ファイル (.ops.txt / .ops.bin / .o) を自動削除させない
.SECONDARY:

all: $(BUILD_DIR)/hello.nes

$(BUILD_DIR):
	@mkdir -p $@

# --- (1) pack: examples/NAME.php → build/NAME.src.bin ---
# PHP ソースに <?php タグ除去 + ASCII チェック + 文字列リテラルを zend_string
# プールに pre-build する。on-NES コンパイラは src.bin の本体を lex/parse する。
$(BUILD_DIR)/%.src.bin: examples/%.php $(PACK_SRC) | $(BUILD_DIR)
	@echo "[make] (1) pack      $< → $@"
	@$(PHP) $(PACK_SRC) $< $@

# --- オラクル用 (host-compile path): NAME.host.ops.bin ---
# 正解データ生成 + 検証に使う。本線ビルド (NAME.nes) には含まれない。
$(BUILD_DIR)/%.ops.txt: examples/%.php | $(BUILD_DIR)
	@echo "[make] oracle extract $< → $@"
	@$(PHP) -d opcache.enable_cli=1 \
	        -d opcache.file_update_protection=0 \
	        -d opcache.opt_debug_level=0x10000 \
	        $< 2> $@ > /dev/null || true

$(BUILD_DIR)/%.host.ops.bin: $(BUILD_DIR)/%.ops.txt $(SERIALIZER)
	@echo "[make] oracle serialize $< → $@"
	@$(PHP) $(SERIALIZER) $< $@

# --- (2) ca65 アセンブル ---
# vm/nesphp.s は build/src.bin を固定パスで .incbin するので、対象の
# NAME.src.bin を build/src.bin にコピーしてからアセンブルする。
$(BUILD_DIR)/%.o: $(VM_SRCS) $(BUILD_DIR)/%.src.bin $(CHR_FONT) | $(BUILD_DIR)
	@cp $(BUILD_DIR)/$*.src.bin $(BUILD_DIR)/src.bin
	@echo "[make] (2) assemble  $(VM_SRC) → $@"
	@$(CA65) -I vm $(VM_SRC) -o $@

# --- (3) ld65 リンク ---
$(BUILD_DIR)/%.nes: $(BUILD_DIR)/%.o $(VM_CFG)
	@echo "[make] (3) link      $< → $@"
	@$(LD65) -C $(VM_CFG) $< -o $@
	@echo "[make] OK: $@"

# --- L3 ロマン検証 (spec/09-verification.md) ---
verify: $(BUILD_DIR)/hello.nes
	@echo ""
	@echo "[make] === L3 ロマン検証 ==="
	@printf "  strings:     "; strings $< | head -1
	@printf "  ZEND_ECHO:   "; xxd -g 1 $< | grep -m1 '88 01 00 00' || echo "(not found)"
	@printf "  ZEND_RETURN: "; xxd -g 1 $< | grep -m1 '3e 01 00 00' || echo "(not found)"

# --- エミュレータで実行 ---
# make run:hello       デフォルト (hello.nes)
# make run:slides      任意の example を指定
run\:hello: $(BUILD_DIR)/hello.nes
	$(EMULATOR) $<

run\:%: $(BUILD_DIR)/%.nes
	$(EMULATOR) $<

clean:
	rm -rf $(BUILD_DIR)
