# 11. CHR バンク切替 (CNROM + PPUCTRL)

[← README](./README.md) | [← 10-devlog](./10-devlog.md)

プレゼンテーションや「画面全体のルック」を切り替える用途のために、nesphp は
**2 段階の CHR 切替機構**を持つ。目的はロマンというより「スライド毎に違う
タイルセットで華やかにしたい」という実用動機。

## 2 段階の切替

| 段 | 手段 | 粒度 | 切替コスト | 実装 |
|---|---|---|---|---|
| **(A)** | `PPUCTRL` bit 4 | 同一バンク内で 2 つの pattern table を選択 | 1 命令 (STA $2000) | `NESPHP_NES_CHR_BG` |
| **(B)** | CNROM バンクレジスタ | 4 枚の 8KB CHR バンクを切替 | 1 命令 (bus-conflict-safe STA) | `NESPHP_NES_CHR_BANK` |

両方を組み合わせると **最大 4 × 2 = 8 面の pattern table** が利用できる。すべて
静的 (ROM 焼き込み) なので、スライド毎に中身を差し替えたければ `chr/` に
CHR データを用意して `make_font.php` で組む。

## マッパー: CNROM (mapper 3)

### iNES ヘッダ

```
4E 45 53 1A   "NES" + EOF
02            PRG-ROM = 2 * 16KB = 32KB
04            CHR-ROM = 4 * 8KB  = 32KB  ← NROM-256 時代は 01
30            Flags 6: mapper LSB nibble = 3 (CNROM)
00            Flags 7
00 ...        padding
```

`vm/nesphp.s` の `.segment "HEADER"` と `vm/nesphp.cfg` の `CHR` MEMORY 定義
(`size = $8000`) が単一の真実。

### CHR 配置

```
CHR-ROM (32KB)
├── Bank 0 ($0000-$1FFF when selected)
│   ├── Pattern Table 0 (4KB): 通常フォント
│   └── Pattern Table 1 (4KB): インバースフォント (XOR $F8)
├── Bank 1 (8KB)  ← 初期は Bank 0 のコピー。カスタム差し替え推奨
├── Bank 2 (8KB)  ← 同上
└── Bank 3 (8KB)  ← 同上
```

`chr/make_font.php` が生成する。バンク毎に独自タイルを入れたい場合は
`$banks` 配列を書き換えて `php chr/make_font.php` を再実行する。

### バス衝突 (bus conflict) 対策

CNROM は「CPU が `$8000-$FFFF` のどこかに STA した瞬間に mapper がバンク番号を
ラッチする」動作で、一部の実機では**書き込み先 ROM セルの既存値と書き込み値が
一致していないと挙動が壊れる** (bus conflict)。

対策として ROM 内に以下のテーブルを持つ:

```asm
cnrom_bank_lut:
    .byte $00, $01, $02, $03
```

バンク N に切替えたいときは:

```asm
LDX #N
STA cnrom_bank_lut, X   ; 書き込むアドレスに N が既に入っているので衝突しない
```

`NESPHP_NES_CHR_BANK` ハンドラはこの LUT 経由で書き込む。LUT 自体は
`$C000-$FFFF` の CODE セグメント内に置かれ、PRG-ROM の一部として存在する。

## (A) `NESPHP_NES_CHR_BG` (0xF6): PPUCTRL bit 4 切替

### 呼び出し

```php
nes_chr_bg(0);  // BG = pattern table 0 ($0000-$0FFF)
nes_chr_bg(1);  // BG = pattern table 1 ($1000-$1FFF)
```

引数はコンパイル時の整数リテラル必須 (0 / 1)。

### VM 実装

`ppu_ctrl_shadow` (zero page 1B) に直前の PPUCTRL 値を持つ。

```
LDA ppu_ctrl_shadow
AND #$EF            ; bit 4 clear (or ORA #$10 for set)
STA ppu_ctrl_shadow
STA PPUCTRL
```

- NMI enable (bit 7)、sprite pattern table (bit 3) などの**他ビットは保存される**
- rendering 中でも PPUCTRL 書き換えは安全 (scroll レジスタと違って PPU 内部
  latch を汚さない)
- sprite 側の pattern table (bit 3) は現時点では `nes_chr_bg` の対象外。
  必要になったら `nes_chr_spr` intrinsic を足す

### シリアライザの畳み込み

```
INIT_FCALL_BY_NAME 1 "nes_chr_bg"    →  ZEND_NOP
SEND_VAL_EX int(1) 1                 →  ZEND_NOP
DO_FCALL_BY_NAME                     →  NESPHP_NES_CHR_BG
                                        op1_type = IS_CONST
                                        op1 = int literal の zval offset
```

## (B) `NESPHP_NES_CHR_BANK` (0xF5): CNROM バンク切替

### 呼び出し

```php
nes_chr_bank(0);  // Bank 0 を CHR 領域に mapping
nes_chr_bank(1);
nes_chr_bank(2);
nes_chr_bank(3);
```

引数はコンパイル時の整数リテラル (0-3)、4 以上は `AND #$03` で丸められる。

### VM 実装

```asm
LDA OP1_VAL+1
AND #$03
TAX
STA cnrom_bank_lut, X   ; bus-conflict-safe
```

### 副作用に注意

- **CHR 全体が一括で入れ替わる**。既に画面に表示中のタイルも、次のフレームで
  新バンクのタイルが引かれる。切替後にすぐ画面を描き直さないと、元の字が
  別のグリフに化ける (スライド単位の切替前提)
- OAM shadow は CPU 側にあるので、バンク切替で壊れない。ただし sprite が参照
  する tile 番号の絵柄は新バンクから取られる
- `nes_chr_bg` の状態は保存される (PPUCTRL は CPU 側のレジスタなので無関係)

### シリアライザの畳み込み

```
INIT_FCALL_BY_NAME 1 "nes_chr_bank"  →  ZEND_NOP
SEND_VAL_EX int(N) 1                 →  ZEND_NOP
DO_FCALL_BY_NAME                     →  NESPHP_NES_CHR_BANK
```

## 典型的な使い方

### パターン 1: スライド毎にインバース切替 (bank 固定)

```php
// Bank 0 の pattern table 0 と 1 を切り替えて強調表示
nes_cls();
nes_puts(4, 4, "TITLE");
nes_chr_bg(1);  // 以降全テキストがインバース
nes_puts(4, 6, "HIGHLIGHTED");
nes_chr_bg(0);  // 通常に戻す
nes_puts(4, 8, "NORMAL TEXT");
```

### パターン 2: スライド毎にバンク切替 (フォント差し替え)

```php
// Bank 0 = 本文フォント、Bank 1 = タイトル装飾フォント (カスタム差し替え前提)
nes_chr_bank(1);
nes_cls();
nes_puts(4, 4, "STYLED TITLE");
// ボタン待ち
$k = fgets(STDIN);
nes_chr_bank(0);
nes_cls();
nes_puts(4, 4, "BODY CONTENT");
```

## カスタム CHR の作り方

### ファイル構成と再生成

`chr/font.chr` は **コミット済みバイナリ**で、`chr/make_font.php` を実行する
度に上書きされる。編集手順:

```bash
vim chr/make_font.php          # バンク・タイルを書き換える
php chr/make_font.php          # chr/font.chr (32KB) を再生成
make                           # 差分 rebuild (CHR 変更は全 .nes に反映)
```

Makefile は `chr/font.chr` を依存に含んでいるので、再生成すれば既存 example も
新しい CHR で再リンクされる。

### タイルのバイトレイアウト (おさらい)

1 バンク = 8KB = 2 つの pattern table × 4KB:

```
バンク先頭からの offset   内容
$0000-$0FFF              Pattern Table 0 (256 タイル)
$1000-$1FFF              Pattern Table 1 (256 タイル)
```

1 タイル = 16 バイト:
- Bytes 0-7: bitplane 0 (8 行 × 8 ピクセル、MSB が左)
- Bytes 8-15: bitplane 1 (同上)

最終的なピクセル色 = `(bitplane1 << 1) | bitplane0` (0-3 のパレット index)。
nesphp の既定パレット (`palette_data`, [06-display-io](./06-display-io.md)) は
全行 `$0F, $30, $10, $00` で「色 0 = 黒 / 色 1 = 白 / 色 2 = 濃灰 / 色 3 = 透明」。

**単色で使う場合** (標準フォント): bitplane 0 だけに書いて bitplane 1 は 0。
**2 色使う場合** (エッジ付きフォント、影付きロゴ等): 色 2 も描きたいピクセルは
bitplane 1 に立て、色 1 と併せてどちらか一方を 1 にする。

### `chr/make_font.php` の構造

```php
function build_bank(array $font5x7): string
{
    $bank = str_repeat("\x00", 8192);
    // ... ASCII 0x20-0x7F の glyph を pattern table 0 と 1 に埋める
    return $bank;
}

$bank0 = build_bank($font5x7);
$banks = [
    0 => $bank0,        // ← 既定は 4 バンクとも同じ
    1 => $bank0,
    2 => $bank0,
    3 => $bank0,
];

$chr = '';
for ($i = 0; $i < 4; $i++) { $chr .= $banks[$i]; }
file_put_contents(__DIR__ . '/font.chr', $chr);
```

`$banks` 配列を書き換えるのが主な拡張ポイント。

### 例 1: バンク 1 に全く別のフォントを入れる

```php
// 自作の別フォントビットマップを用意
$fontDecorative = [ /* 96 個の [r0..r7] */ ];

$bank0 = build_bank($font5x7);
$bank1 = build_bank($fontDecorative);

$banks = [0 => $bank0, 1 => $bank1, 2 => $bank0, 3 => $bank0];
```

PHP からは `nes_chr_bank(1)` で装飾フォントに切り替わる。

### 例 2: ロゴや図形タイルを自由なタイル番号に配置

`build_bank` を拡張して、ASCII glyph の隙間にカスタムタイルを詰め込む:

```php
function build_bank_with_logo(array $font5x7): string
{
    $bank = str_repeat("\x00", 8192);

    // ASCII フォントは通常通り
    foreach ($font5x7 as $i => $rows) {
        $t0 = (0x20 + $i) * 16;
        for ($y = 0; $y < 8; $y++) {
            $bank[$t0 + $y] = chr($rows[$y]);
        }
    }

    // タイル 0x00-0x1F は未使用なのでロゴパーツを置ける
    // 例: タイル 0x01 に 8x8 の塗りつぶし
    $logoTile1 = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    for ($y = 0; $y < 8; $y++) {
        $bank[0x01 * 16 + $y] = chr($logoTile1[$y]);
    }

    return $bank;
}
```

PHP 側ではタイル 0x01 は ASCII の印字不可文字なので `nes_puts` では書けないが、
`nes_put($x, $y, 1)` (第 3 引数を int リテラルにする) で直接タイル番号を指定して
配置できる (IS_LONG 分岐が走って下位 1 バイトがタイル番号として使われる)。

### 例 3: bitplane 1 で 2 色フォントにする

影付き文字など:

```php
// 本体は bitplane 0 (色 1 = 白)、影は bitplane 1 のみ (色 2 = 濃灰)
for ($y = 0; $y < 8; $y++) {
    $bank[$t0 + $y]     = chr($rows[$y]);                    // 白の本体
    $bank[$t0 + 8 + $y] = chr($rows[$y] >> 1 | $rows[$y]);   // 右下シフトの影
}
```

パレットの色 2 を別の色に (`$0F, $30, $26, $00` 等) 変えたい場合は
`vm/nesphp.s` の `palette_data` を編集する。

### サイズ上限

CNROM は CHR-ROM 合計 **32KB 固定** (4 × 8KB)。これを超える場合は GxROM /
UxROM + CHR-RAM などへのマッパー昇格が必要。将来的に CHR-RAM 対応すれば
ランタイムで PRG からタイルを差し込めるようになる。

## 制限事項

| 制限 | 理由 | 緩和策 |
|---|---|---|
| mid-frame 切替不可 | scanline IRQ 非対応 (CNROM にはタイマーなし) | MMC3 に昇格すれば可能 |
| sprite 用 pattern table は `nes_chr_bg` の対象外 | bit 3 を触る intrinsic が未実装 | `nes_chr_spr($n)` を追加すれば対応可能 |
| バンク 1-3 は初期状態で bank 0 のコピー | `chr/make_font.php` がそう組むため | `$banks` を書き換えて再生成 |
| ランタイムでのタイルデータ変更不可 | CHR-**ROM** のため書き込みできない | CHR-RAM 対応マッパー (GxROM 等) に昇格が必要 |

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — iNES ヘッダ、PRG / CHR 容量
- [04-opcode-mapping](./04-opcode-mapping.md) — `NESPHP_NES_CHR_BANK` / `NESPHP_NES_CHR_BG` の番号
- [06-display-io](./06-display-io.md) — PPUCTRL 全ビットの意味、パレット
- [10-devlog](./10-devlog.md) — Phase 5D の設計経緯
