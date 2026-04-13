# 07. ロードマップ (実装ステップ)

[← README](./README.md) | [← 06-display-io](./06-display-io.md) | [→ 08-risks](./08-risks.md)

## 進捗サマリ

| フェーズ | 成果物 | 状態 |
|---|---|---|
| MVP: echo のみ | `hello.nes` | ✅ **完了** |
| 延長 第 1 段階: 整数 + 変数 | `arith.nes` | ✅ **完了** |
| 延長 第 2 段階: 制御フロー | `loop.nes` | ✅ **完了** |
| 延長 第 4 段階: コントローラ入力 | `button.nes` | ✅ **完了** |
| 延長 第 5A: ネームテーブル文字移動 | `move.nes` | ✅ **完了** |
| 延長 第 5B: ハードウェアスプライト移動 | `sprite.nes` | ✅ **完了** |
| 延長 第 5C: プレゼン用 `nes_puts` / `nes_cls` | `slides.nes` | ✅ **完了** |
| 延長 第 3 段階: NMI 同期 echo | — | 未着手 (echo は sprite_mode 前まで制限) |
| 第 2 段階: 自作 Zend 拡張 | `nesphp_dump.so` | 未着手 |
| 多スプライト対応 | — | 未着手 (現在 sprite 0 固定) |

各フェーズの設計判断の経緯と躓きは [10-devlog](./10-devlog.md) に記録している。

## MVP (`echo "HELLO, NES!";` を NES で表示する)

### ステップ 1: リポジトリ骨格

以下のフォルダを切る:

```
nesphp/
  spec/         仕様ドキュメント (このフォルダ)
  extractor/    opcache ダンプを呼ぶシェルラッパー
  serializer/   serializer.php と composer.json
  vm/           nesphp.s (ca65) と nesphp.cfg
  chr/          font.chr
  examples/     hello.php 等
  build/        中間生成物と .nes (gitignore)
  Makefile      1 コマンドビルド (make / make clean / make verify)
  README.md     プロジェクト説明 (3 層図を含む)
```

### ステップ 2: NES 側の素 Hello World (PHP 抜き)

ca65 で `HELLO WORLD` を固定表示する `.nes` を先に作る。この段階で:

- PPU 初期化 / パレット / nametable クリア ([06-display-io](./06-display-io.md))
- iNES ヘッダ / NROM マッパー / リセットベクタ
- CHR-ROM (font.chr) の作成と配置
- `ca65 + ld65` のビルド確立
- Mesen でロードして `HELLO WORLD` が見えることを確認

雛形: [bbbradsmith/NES-ca65-example](https://github.com/bbbradsmith/NES-ca65-example)

**このステップを独立させる理由**: PHP 側が動いていない段階で NES ビルド基盤を確立しておくと、後で切り分けがしやすい。

### ステップ 3: opcache ダンプの検証

```bash
cat > examples/hello.php <<'EOF'
<?php echo "HELLO, NES!";
EOF

php -dopcache.enable_cli=1 -dopcache.opt_debug_level=0x10000 \
    examples/hello.php 2> build/ops.txt > /dev/null

cat build/ops.txt
```

期待する出力:
```
$_main:
     ; (lines=2, ...)
0000 ECHO string("HELLO, NES!")
0001 RETURN int(1)
```

PHP バージョン (`php -v` で 8.4.x) を `spec/README.md` の動作確認欄に記録。

### ステップ 4: L3 フォーマット仕様の凍結

`spec/01-rom-format.md` の内容が実装の単一の真実。このステップでは仕様を確定させ、serializer 実装と VM 実装のどちらもこのファイルだけを参照するようにする。

### ステップ 5: シリアライザ v0

`serializer/serializer.php` で MVP 最小機能を実装:

- `ops.txt` をパースして ZEND_ECHO と ZEND_RETURN の 2 命令、`string("...")` と `int(N)` の 2 literal 型のみ対応
- `spec/01-rom-format.md` と `spec/04-opcode-mapping.md` を元に `ops.bin` を出力
- ZEND_ECHO=0x28, ZEND_RETURN=0x3e 等の番号は PHP 8.4 の `zend_vm_opcodes.h` を見てハードコード
- PHP バージョンが 8.4 でなければ abort

テスト: `hexdump -C build/ops.bin` の出力が `spec/01-rom-format.md` の hex dump 例と一致すること。

### ステップ 6: VM ループ (ca65)

`vm/nesphp.s` に `spec/03-vm-dispatch.md` の設計をそのまま実装:

- ゼロページの VM_PC / VM_SP / VM_LITBASE / VM_CVBASE / VM_TMPBASE
- 256 エントリ jump table (未実装は handle_unimpl)
- `handle_zend_echo` と `handle_zend_return` の 2 ハンドラだけ実装
- `resolve_op1` / `resolve_op2` の汎用 operand resolver
- `ppu_write_string_forced_blank` で nametable に書き込む
- 起動時に op_array header を読んで php_version を確認、不一致なら halt

### ステップ 7: 統合ビルド

`Makefile` で (1) 抽出 → (2) シリアライズ → (3) アセンブル → (4) リンク を pattern rule で繋ぐ ([05-toolchain](./05-toolchain.md))。

```bash
make                     # デフォルトで build/hello.nes
make build/foo.nes       # examples/foo.php から build/foo.nes
make verify              # L3 ロマン検証
make clean               # build/ を消す
```

### ステップ 8: Mesen で動作確認

`build/hello.nes` を開き、画面に `HELLO, NES!` が表示されることを確認。

### ステップ 9: ロマン検証

`spec/09-verification.md` の「L3 ロマン検証」セクションを実行:

- `strings build/hello.nes | grep HELLO` → `HELLO, NES!` がヒット
- `xxd build/hello.nes | grep '28 01 08 08'` → ZEND_ECHO バイト列がヒット
- `xxd build/hello.nes | grep '3e 01 08 08'` → ZEND_RETURN バイト列がヒット

ここまでで **MVP 完了**。

### ステップ 10 (第 2 段階): 自作 Zend 拡張 `nesphp_dump.so`

- `nesphp_dump/config.m4` と `nesphp_dump/nesphp_dump.c` (~300 行 C) を書く
- `zend_compile_file()` を呼んで `zend_op_array*` を直接歩き、`spec/01-rom-format.md` 準拠のバイナリを直接出力
- serializer.php のテキストパース層を削除し、拡張出力を直接使う
- テキスト経路版とバイト一致することを確認
- 完成すると「PHP エンジンが吐いた `zend_op` を拡張がバイナリ化し、6502 がそのまま解釈」のロマン最大構成になる

---

## 延長ゴール (MVP 後)

### 第 1 段階: 整数 + ローカル変数

対応 opcode 追加:
- `ZEND_ASSIGN`, `ZEND_ADD`, `ZEND_SUB`, `ZEND_IS_SMALLER`

```php
<?php
$a = 1;
$a = $a + 1;
echo $a;
```

が動くことを目指す。CV スロット 1 個 (`$0400`) と VM スタック 2-3 段を使う。

### 第 2 段階: 制御フロー

対応 opcode 追加:
- `ZEND_JMP`, `ZEND_JMPZ`, `ZEND_JMPNZ`
- `ZEND_IS_EQUAL`, `ZEND_IS_NOT_EQUAL`

```php
<?php
$i = 0;
while ($i < 10) {
    echo "X";
    $i = $i + 1;
}
```

が動くことを目指す。`ZEND_JMP` の `op1.jmp_offset` を serializer で NES ROM 内 op index に解決する実装を追加。

### 第 3 段階: 動的 echo (NMI 同期)

ステップ 2 の時点で `echo` は強制 blanking 中のみ有効だが、ここでテキスト行バッファ + NMI 転送に昇格 ([06-display-io](./06-display-io.md))。while ループ内の echo が実行時に見えるようになる。

### 第 4 段階: 標準入力 = コントローラ

PHP 側で `fgets(STDIN)` を使い、serializer が `INIT_FCALL "fgets"` パターンを `BUILTIN_READ_INPUT` に畳み込み、VM が `$4016` コントローラ読み取りを呼ぶ。

```php
<?php
while (true) {
    $k = fgets(STDIN);
    if ($k === "A") echo "A";
}
```

が動くことを目指す。

### 第 5 段階: スプライト

ビルトイン関数 `nes_sprite_set($id, $x, $y, $tile)` を serializer で畳み込み、OAM シャドウ書き込み + NMI での OAM DMA。

```php
<?php
$x = 120;
$y = 120;
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 1;
    if ($k === "R") $x = $x + 1;
    if ($k === "U") $y = $y - 1;
    if ($k === "D") $y = $y + 1;
    nes_sprite_set(0, $x, $y, 0xA0);
}
```

これで `README.md` の延長ゴール (「画面の文字やスプライトをコントローラで動かす」) が達成される。

### 第 6 段階: バンクスイッチ (必要なら)

PRG-ROM が 32KB に収まらなくなったら UxROM に昇格し、VM を固定バンク、op_array/literals を切替バンクに配置。

---

## スケジュール感

| ステージ | 所要 |
|---------|------|
| MVP (ステップ 1-9) | 1-2 週間 |
| 第 2 段階 (自作拡張) | 数日 |
| 延長 第 1 段階 (整数+変数) | 1 週間 |
| 延長 第 2 段階 (制御フロー) | 1 週間 |
| 延長 第 3 段階 (動的 echo) | 数日 |
| 延長 第 4 段階 (コントローラ) | 数日 |
| 延長 第 5 段階 (スプライト) | 1 週間 |

合計 2-3 ヶ月で延長ゴール全達成 (週末プロジェクトとして週 10 時間想定)。

---

## 関連ドキュメント

- [09-verification](./09-verification.md) — 各ステップの受け入れ基準
- [08-risks](./08-risks.md) — 各ステージで遭遇しうるリスク
- [05-toolchain](./05-toolchain.md) — ビルドパイプラインの詳細
