# 09. 受け入れ基準とロマン検証

[← README](./README.md) | [← 08-risks](./08-risks.md)

## MVP 受け入れ基準

### 環境構築

- [ ] `brew install cc65 php` 完了
- [ ] `php -v` が `PHP 8.4.x` を表示
- [ ] `ca65 --version` が動く

### ビルド

- [ ] `examples/hello.php` に `<?php echo "HELLO, NES!";` が書かれている
- [ ] `make` が成功し `build/hello.nes` が生成される
- [ ] `make` の実行中にエラーなし

### 中間生成物の検証

- [ ] `build/ops.txt` (opcache 出力) に以下の行が含まれる:
  ```
  0000 ECHO string("HELLO, NES!")
  0001 RETURN int(1)
  ```
- [ ] `build/ops.bin` の hex dump が [01-rom-format](./01-rom-format.md) の「具体 hex dump 例」と同じ構造になっている:
  - op_array header (先頭 16B): `num_ops=2`, `num_literals=2`, `php_version=8.4`
  - op[0] (24B): `opcode=0x88 (ZEND_ECHO=136)`, `op1_type=0x01 (CONST)`
  - op[1] (24B): `opcode=0x3e (ZEND_RETURN=62)`, `op1_type=0x01`
  - literals[0]: `type=0x06 (IS_STRING)`
  - literals[1]: `type=0x04 (IS_LONG)`, `value=1`
  - zend_string: `len=11`, `val="HELLO, NES!"`

### エミュレータでの動作

- [ ] Mesen で `build/hello.nes` を開くとクラッシュしない
- [ ] 画面中央付近に `HELLO, NES!` が表示される
- [ ] 文字列を `"NESPHP WORKS"` に変えて `make` を再実行し、表示も `NESPHP WORKS` に変わる (= シリアライザが実際にコンパイルしている証左)
- [ ] Mesen のデバッガで PPU nametable を見ると、該当位置に ASCII コードのタイル番号が書き込まれている

---

## L3 ロマン検証 (必須)

これが成功して初めて「Zend が吐いた opcode が NES で動いている」と胸を張れる。

### 検証 1: PHP ソースの文字列が NES ROM に生で存在する

```bash
strings build/hello.nes | grep -i hello
```

期待出力:
```
HELLO, NES!
```

**意味**: PHP ソースの文字列リテラルが、Zend の `zend_string` 経由で NES ROM の中にそのままバイトとして焼かれている。

### 検証 2: ZEND_ECHO opcode バイト列が見える

```bash
xxd -g 1 build/hello.nes | grep '88 01 00 00'
```

期待: 1 件以上ヒット。

**意味**: Zend の `ZEND_ECHO` (番号 0x28) と、operand タイプバイト (`op1_type=IS_CONST=0x01`, `op2_type=op1_type+result_type=0x08 0x08`) が連続して ROM に焼かれている。これは Zend の `zend_op` 構造体の末尾 4 バイトと完全一致。

### 検証 3: ZEND_RETURN opcode バイト列が見える

```bash
xxd -g 1 build/hello.nes | grep '3e 01 00 00'
```

期待: 1 件以上ヒット。

### 検証 4: literals の 16B zval レイアウトが Zend 互換

```bash
xxd build/hello.nes | awk '/3f40:/{ print; getline; print }'
```

期待出力の近似:
```
00003f40: 50 3f 00 00 00 00 00 00 06 00 00 00 00 00 00 00  P?..............
00003f50: 01 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00  ................
```

- `3f40` 行の `06 00 00 00` = `u1.type_info` の下位バイトが `IS_STRING(6)`
- `3f50` 行の `01 00 00 00 00 00 00 00` = `value.lval = 1`
- `3f50` 行の `04 00 00 00` = `IS_LONG(4)`

これらは **Zend 互換の 16B zval レイアウト**そのもの。

### 検証 5: 文字列を変えると ROM も変わる

```bash
# 元
strings build/hello.nes | grep HELLO

# 文字列を変えて再ビルド
sed -i '' 's/HELLO, NES!/NESPHP WORKS/' examples/hello.php
make

strings build/hello.nes | grep -E 'HELLO|NESPHP'
# → NESPHP WORKS
```

シリアライザが literal を実際に差し替えている証左。

---

## 第 2 段階 (自作 Zend 拡張) 受け入れ基準

- [ ] `nesphp_dump/` 以下で `phpize && ./configure && make` が成功
- [ ] `nesphp_dump.so` が生成される
- [ ] `php -dzend_extension=./nesphp_dump/modules/nesphp_dump.so examples/hello.php > build/ops_direct.bin` が成功
- [ ] `diff build/ops.bin build/ops_direct.bin` がバイト一致 (または意図的な差分のみ)
- [ ] serializer.php からテキストパース層を削除しても `build/hello.nes` が同じ内容でビルドできる
- [ ] `spec/05-toolchain.md` が自作拡張ベースの手順に更新されている

---

## 実装済み demo の受け入れ基準

全て `make build/NAME.nes` でビルド → Mesen で起動。

### 延長第 1 段階: 整数 + ローカル変数 (`arith.nes`) ✅

`examples/arith.php`:
```php
<?php
$a = 1;
$a = $a + 2;
echo $a;
```

- [x] Mesen で `3` が表示される
- [x] `xxd -g 1 build/arith.nes | grep '01 08 01 02'` で ZEND_ADD (0x01) + op1_type=IS_CV + op2_type=IS_CONST + result_type=IS_TMP_VAR がヒット
- [x] `xxd -g 1 build/arith.nes | grep '16 08 01 00'` で ZEND_ASSIGN (0x16) がヒット

### 延長第 2 段階: 制御フロー (`loop.nes`) ✅

`examples/loop.php`:
```php
<?php
$i = 0;
while ($i < 5) {
    echo $i;
    $i = $i + 1;
}
```

- [x] Mesen で `01234` が表示される
- [x] `xxd -g 1 build/loop.nes | grep '2a 00 00 00'` で ZEND_JMP (0x2A) がヒット
- [x] `xxd -g 1 build/loop.nes | grep '2c 02 00 00'` で ZEND_JMPNZ (0x2C) + op2_type=IS_UNUSED がヒット
- [x] `xxd -g 1 build/loop.nes | grep '14 08 01 02'` で ZEND_IS_SMALLER (0x14) がヒット

### 延長第 4 段階: コントローラ入力 (`button.nes`) ✅

`examples/button.php`:
```php
<?php
echo "Press: ";
$k = fgets(STDIN);
echo $k;
```

- [x] Mesen で `Press: ` が表示される
- [x] A/B/Start/Select/U/D/L/R の各ボタンを押すと対応する文字が続けて表示される
- [x] `xxd -g 1 build/button.nes | grep 'f0 00 00 04'` で NESPHP_FGETS (0xF0) + result_type=IS_VAR がヒット
- [x] fgets の `INIT_FCALL / FETCH_CONSTANT / SEND_VAL` が NOP (0x00) に畳み込まれている

### 延長第 5A 段階: タイル文字移動 (`move.nes`) ✅

`examples/move.php`:
```php
<?php
$x = 16;
$y = 14;
nes_put($x, $y, "X");
while (true) {
    $k = fgets(STDIN);
    nes_put($x, $y, " ");
    if ($k === "L") $x = $x - 1;
    if ($k === "R") $x = $x + 1;
    if ($k === "U") $y = $y - 1;
    if ($k === "D") $y = $y + 1;
    nes_put($x, $y, "X");
}
```

- [x] 画面中央に `X` が表示される
- [x] 十字キーで `X` が 1 タイルずつ動く (erase old + redraw new)
- [x] `xxd -g 1 build/move.nes | grep 'f1 08 08 00'` で NESPHP_NES_PUT (0xF1) がヒット
- [x] `xxd -g 1 build/move.nes | grep '10 08 01 02'` で ZEND_IS_IDENTICAL (0x10) がヒット

### 延長第 5B 段階: ハードウェアスプライト (`sprite.nes`) ✅

`examples/sprite.php`:
```php
<?php
$x = 120;
$y = 120;
nes_sprite($x, $y, 65);
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 2;
    if ($k === "R") $x = $x + 2;
    if ($k === "U") $y = $y - 2;
    if ($k === "D") $y = $y + 2;
    nes_sprite($x, $y, 65);
}
```

- [x] 画面中央に `A` (tile 65) がスプライトで表示される
- [x] 十字キーで 2 ピクセルずつ滑らかにスプライトが動く
- [x] `xxd -g 1 build/sprite.nes | grep 'f2 08 08 00'` で NESPHP_NES_SPRITE (0xF2) がヒット
- [x] NMI ハンドラが毎 VBlank で OAM DMA ($4014) を実行

### 延長第 5C 段階: プレゼン表示 (`slides.nes`) ✅

`examples/slides.php`:
```php
<?php
$p = 0;
while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;
    if ($p === 7) { $p = 1; }
    if ($p === 1) { nes_cls(); nes_puts(4, 4, "NESPHP PRESENTATION"); }
    if ($p === 2) { nes_puts(4, 7, "1. PHP ON FAMICOM"); }
    if ($p === 3) { nes_puts(4, 9, "2. ZEND OPCODE ON 6502"); }
    if ($p === 4) { nes_puts(4, 11, "3. L3 ROM LAYOUT"); }
    if ($p === 5) { nes_puts(4, 13, "4. ROMAN OVER UTILITY"); }
    if ($p === 6) { nes_puts(4, 16, "PRESS ANY KEY TO RESET"); }
}
```

- [x] 任意のボタン押下でスライドが 1 行ずつ追加表示される
- [x] 6 回目の押下で画面がクリアされ、タイトルから再描画される
- [x] `strings build/slides.nes` で全スライド文字列がヒット (`NESPHP PRESENTATION` 他)
- [x] `xxd -g 1 build/slides.nes | grep 'f3 01 01 00'` で NESPHP_NES_PUTS (0xF3, op1/op2=IS_CONST) がヒット
- [x] `xxd -g 1 build/slides.nes | grep 'f4 00 00 00'` で NESPHP_NES_CLS (0xF4, 引数なし) がヒット

### 延長第 3 段階: NMI 同期書き込み (`livetext.nes`) ✅

`examples/livetext.php`: sprite_mode 中に nes_puts / nes_put を呼ぶデモ。
スプライトが十字キーで動く中、A ボタン押下で "HIT!" が行を 1 つずつずらして
表示される。

- [x] ビルド成功、ROM サイズ 65552 バイト
- [x] sprite_mode 中に呼ばれた `nes_puts(3, $row, "HIT!")` が A 押下で画面に反映される
- [x] スプライト 'X' が十字キーで動き続ける (NMI が毎フレーム OAM DMA を実行している)
- [x] sprite 移動と HIT! 追加を並行操作しても画面崩れが発生しない
- [x] `xxd -g 1 build/livetext.nes | grep 'f3 01 08 00'` で NESPHP_NES_PUTS (op1=IS_CONST x=3, op2=IS_CV $row) がヒット
- [x] Mesen の PPU viewer で `$0300-$03FF` に NMI キューエントリが確認できる (A 押下直後の短時間)

### 延長第 3.1 段階: sprite_mode での nes_cls (`livereset.nes`) ✅

`examples/livereset.php`: sprite_mode 中に `nes_cls()` でスライド遷移するデモ。
A 押下で画面クリア + 次スライドの `nes_puts` が走り、3 スライドを循環する。

- [x] ビルド成功、ROM サイズ 65552 バイト
- [x] 初期表示 "PHASE 3.1: CLS DEMO" + sprite 'X' が出る
- [x] 十字キーで sprite が動く (sprite_mode のまま)
- [x] A 押下で 1-2 フレームの黒フラッシュ → 新しいスライドが表示される
- [x] A 連打で sprite 位置を保ったままスライドが循環する
- [x] 画面崩壊しない (brief force-blanking 経由)
- [x] `xxd -g 1 build/livereset.nes | grep 'f4 00 00 00'` で NESPHP_NES_CLS がヒット

### 延長第 5D 段階: CHR バンク + pattern table 切替 (`chrdemo.nes`) ✅

`examples/chrdemo.php`: ボタン押下で `nes_chr_bg(0/1)` と `nes_chr_bank(0/1)` を
順に呼び、同じテキストが通常 → インバース → バンク切替と変化するデモ。

- [x] ビルド成功、ROM サイズ 65552 バイト (16 + 32KB PRG + 32KB CHR)
- [x] `xxd -g 1 -l 16 build/chrdemo.nes` で `02 04 30 00` (PRG=2, CHR=4, Flags6=0x30=mapper 3) が確認できる
- [x] `xxd -g 1 build/chrdemo.nes | grep 'f5 01 00 00'` で NESPHP_NES_CHR_BANK (0xF5) がヒット
- [x] `xxd -g 1 build/chrdemo.nes | grep 'f6 01 00 00'` で NESPHP_NES_CHR_BG (0xF6) がヒット
- [x] Mesen の PPU viewer で pattern table 0/1 の両方にフォントタイルが存在する
- [x] Mesen の mapper viewer で bank 0-3 が参照できる (初期状態は全て bank 0 のコピー)
- [x] 既存 example (hello/arith/loop/button/move/sprite/slides) が CNROM 昇格後も全てビルド成功・動作

### 延長第 5E 段階: パレット + attribute + カスタムタイル (`color.nes`) ✅

`examples/color.php`: 3 つのパレット intrinsic (nes_bg_color / nes_palette / nes_attr) と
カスタムタイル (日本国旗) を使ったカラフルプレゼンデモ。

- [x] ビルド成功、ROM サイズ 65552 バイト
- [x] `xxd -g 1 build/color.nes | grep 'f7 01 00 00'` で NESPHP_NES_BG_COLOR (0xF7, op1=IS_CONST) がヒット
- [x] `xxd -g 1 build/color.nes | grep 'f8 01 01 01'` で NESPHP_NES_PALETTE (0xF8, op1/op2/result=IS_CONST) がヒット
- [x] `xxd -g 1 build/color.nes | grep 'f9 01 01 00'` で NESPHP_NES_ATTR (0xF9, op1/op2=IS_CONST) がヒット
- [x] Mesen で黒背景にカラフルなテキスト (赤タイトル、白本文、緑強調、水色フッタ) が表示される
- [x] 日本国旗 (2×2 = 16×16 px カスタムタイル) が白地に赤丸で正しく表示される
- [x] Mesen の PPU palette viewer で BG palette 0-3 が異なる色セットになっている

---

## 実機検証 (任意)

- [ ] Everdrive N8 Pro または互換 flash cart で `build/hello.nes` を実機にロード
- [ ] Mesen と同じ表示が出ることを確認
- [ ] 実機限定のバグ (PPU タイミング、DPCM 等) が出ないこと

---

## 関連ドキュメント

- [07-roadmap](./07-roadmap.md) — 実装ステップの順序
- [01-rom-format](./01-rom-format.md) — hex dump の期待レイアウト
- [08-risks](./08-risks.md) — 検証で検出したいリスク
