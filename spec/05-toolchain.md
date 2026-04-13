# 05. ツールチェーンとビルドパイプライン

[← README](./README.md) | [← 04-opcode-mapping](./04-opcode-mapping.md) | [→ 06-display-io](./06-display-io.md)

## 全体フロー

```
input.php
   │
   ▼ (1) 抽出: opcache.opt_debug_level (MVP) / nesphp_dump.so (第 2 段階)
ops.txt (or ops.bin)
   │
   ▼ (2) シリアライズ: serializer.php
ops.bin (L3 ROM イメージ、[01-rom-format](./01-rom-format.md) 準拠)
   │
   ▼ (3) アセンブル: ca65 vm/nesphp.s
nesphp.o
   │
   ▼ (4) リンク: ld65 -C vm/nesphp.cfg (ops.bin を .incbin)
nesphp.nes
```

1 コマンド化は `Makefile` の pattern rule で行う (`make build/NAME.nes` が examples/NAME.php から .nes までを一気通貫)。

---

## (1) 抽出層

### MVP: opcache.opt_debug_level

```bash
php -dopcache.enable_cli=1 \
    -dopcache.opt_debug_level=0x10000 \
    examples/hello.php 2> build/ops.txt > /dev/null
```

- stock PHP 8.4 同梱、追加インストール不要
- stderr にテキスト形式のダンプが出る
- 書式例:
  ```
  $_main:
       ; (lines=2, args=0, vars=0, tmps=0)
       ; (after optimizer)
       ; /tmp/test.php:1-1
  0000 ECHO string("HELLO, NES!")
  0001 RETURN int(1)
  ```
- オペランドは `string("...")` / `int(N)` / `CV($var)` / `TMP#N` / `V#N` の型プレフィックス付き

### 第 2 段階: 自作 Zend 拡張 `nesphp_dump.so`

C で ~300 行。`zend_compile_file()` を呼んで `zend_op_array*` を受け取り、`opcodes[]` と `literals[]` を直接歩いてバイナリ出力。

- `spec/01-rom-format.md` 準拠のバイトをそのまま吐く
- serializer.php のテキストパース層を完全に殺せる
- **ロマン最大化**: 「Zend エンジンが吐いた `zend_op` を我々の拡張が吸い出してバイナリ化し、それを 6502 が解釈」

PHP 拡張ビルドは `phpize && ./configure && make`、`PHP_API_VERSION` でコンパイル時にバージョンチェック。

---

## (2) シリアライザ層: `serializer.php`

責務:

1. `ops.txt` (opcache テキスト) をパース
2. `spec/04-opcode-mapping.md` の番号表を参照して、ニーモニックを Zend opcode 番号に変換
3. literal を型ごとに 16B zval に詰める
4. 文字列 literal は `zend_string` (24B ヘッダ + content) として文字列プールに追加
5. CONST オペランドのオフセットを literals_off 起点で解決
6. 制御フロー命令 (`JMP 0003` 等) の index を uint16 で埋め込み
7. 組み込み関数パターン (`INIT_FCALL "fgets"` + `DO_FCALL`) を検出して特殊 ID に畳み込み
8. op_array header + opcodes + literals + string pool を 1 本の `ops.bin` にパック
9. 未対応 opcode / 未対応 literal 型に当たったら compile error で abort

### 単一ファイル構成

```
serializer/
  serializer.php     ~600 行想定
  composer.json      (依存ゼロ、~10 行)
```

nikic/php-parser 等の外部ライブラリは**使わない** (ロマン評価を損ねないため)。

### 内部モジュール (1 ファイル内)

- `Parser` — opcache テキストダンプのパース
- `ZendOp` — `zend_op` 相当のデータクラス
- `ZendZval` — `zval` 相当のデータクラス
- `ZendString` — 文字列プール管理
- `OpcodeTable` — `spec/04-opcode-mapping.md` 準拠のニーモニック→番号表
- `RomEmitter` — バイナリバイト列を生成
- `BuiltinFolder` — `INIT_FCALL` パターンの畳み込み

---

## (3) アセンブラ層: ca65

- `vm/nesphp.s` — VM 本体 (リセット/NMI/dispatch/ハンドラ)
- `vm/nesphp.cfg` — ld65 メモリレイアウト設定 (NROM 32KB + 8KB CHR)
- `chr/font.chr` — ASCII 96 タイル CHR バイナリ (`.incbin`)

### ビルド

```bash
ca65 --target none vm/nesphp.s -o build/nesphp.o
ld65 -C vm/nesphp.cfg build/nesphp.o -o build/nesphp.nes
```

`.incbin "build/ops.bin"` でシリアライザ出力を ROM に埋め込む。

### ld65 メモリレイアウト (nesphp.cfg)

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

(実際の値は実装時に調整)

---

## (4) 統合ビルド: `Makefile`

pattern rule で (1)〜(4) を繋ぐ:

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

### `opcache.file_update_protection=0` の根拠

opcache のデフォルト (`=2`) は、「mtime が現在から 2 秒以内の新しいファイルは optimizer にかけず cache もしない」という race condition 対策。これが **`touch example.php && make`** の典型的な編集フローで dump を空にしてしまうので、nesphp では一律に無効化する。

開発フローで opcache race は問題にならない (stock CLI の 1 プロセス 1 コンパイル)。

### 使い方

```bash
make                     # デフォルトで build/hello.nes
make build/foo.nes       # examples/foo.php から build/foo.nes
make verify              # L3 ロマン検証
make clean               # build/ を消す
```

---

## PHP バージョンロックの根拠

### Zend opcode 番号が変動する

`php-src/Zend/zend_vm_opcodes.h` の定数定義は PHP リリース間で番号がシフトすることがある。serializer と VM が参照する番号表 ([04-opcode-mapping](./04-opcode-mapping.md)) は**特定バージョンに固定**する必要がある。

### `zend_op` のレイアウト変動

PHP ビルド設定 (ZTS/NTS、32/64 bit、debug/release) によって構造体のパディングや union サイズが変わる。`spec/01-rom-format.md` の 24B 仕様は **NTS x64 PHP 8.4 リリースビルド** を前提にしている。

### 採用: PHP 8.4

- 記述時点 (2026-04) で最新安定版に近い
- `brew install php` で取得できる
- 8.3/8.5 との互換性は保証しない

### 実行時チェック

- op_array header の `php_version_major=0x08, php_version_minor=0x04` を VM 側で起動時に確認、不一致なら画面エラー表示 & halt
- serializer は `php -v` の出力を見て 8.4.x でなければ早期 abort

---

## 必須インストール

```bash
brew install php       # 8.4.x
brew install cc65      # ca65 + ld65
brew install mesen     # (任意) デバッグ用エミュレータ
```

`php -v` と `ca65 --version` で確認。

---

## 関連ドキュメント

- [00-overview](./00-overview.md) — 3 層アーキテクチャの全体像
- [01-rom-format](./01-rom-format.md) — シリアライザが出力するバイナリ仕様
- [04-opcode-mapping](./04-opcode-mapping.md) — opcode 番号表
- [07-roadmap](./07-roadmap.md) — 実装ステップの順序
