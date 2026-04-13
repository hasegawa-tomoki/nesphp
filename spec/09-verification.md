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

## 延長ゴールの段階別受け入れ基準

### 第 1 段階: 整数 + ローカル変数

`examples/arith.php`:
```php
<?php
$a = 1;
$a = $a + 2;
echo $a;
```

- [ ] Mesen で `3` が表示される
- [ ] `xxd build/arith.nes | grep '01 01 08 08'` (ZEND_ADD 等の予想値) がヒット

### 第 2 段階: 制御フロー

`examples/loop.php`:
```php
<?php
$i = 0;
while ($i < 5) {
    echo "X";
    $i = $i + 1;
}
```

- [ ] Mesen で `XXXXX` が表示される

### 第 3 段階: 動的 echo (NMI 同期)

`examples/count.php`:
```php
<?php
$i = 0;
while ($i < 10) {
    echo "*";
    $i = $i + 1;
}
```

- [ ] NMI 同期方式に切り替えた状態で、画面に `*` が順番に増えていく様子が見える (強制 blanking では全部描かれた後に一瞬で表示)

### 第 4 段階: コントローラ入力

`examples/input.php`:
```php
<?php
while (true) {
    $k = fgets(STDIN);
    if ($k === "A") echo "A";
    if ($k === "B") echo "B";
}
```

- [ ] Mesen でコントローラ A ボタンを押すと画面に `A` が追加される
- [ ] B ボタンを押すと `B` が追加される

### 第 5 段階: スプライト

`examples/sprite.php`:
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

- [ ] 画面中央にスプライトが表示される
- [ ] 十字キーでスプライトが上下左右に動く

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
