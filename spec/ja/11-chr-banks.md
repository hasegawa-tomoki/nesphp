# 11. CHR 切替 (CHR-RAM バルクコピー + PPUCTRL)

[← README](./README.md) | [← 10-devlog](./10-devlog.md)

プレゼンテーションや「画面全体のルック」を切り替える用途のために、nesphp は
**2 段階の CHR 切替機構**を持つ。目的はロマンというより「スライド毎に違う
タイルセットで華やかにしたい」という実用動機。

## 2 段階の切替

| 段 | 手段 | 粒度 | 切替コスト | 実装 |
|---|---|---|---|---|
| **(A)** | `PPUCTRL` bit 3/4 (reset 時に固定) | BG は PPU $0000、sprite は $1000 から fetch — 独立した 2 面の pattern table | 0 (静的な設定) | reset コード |
| **(B)** | PRG-ROM (`CHRDATA`) から CHR-RAM への 4KB バルクコピー | BG または sprite の pattern table を 4 つの 4KB CHR set のいずれかで差し替え | 転送 ~25 ms (sprite_mode では短い黒フラッシュ) | `NESPHP_NES_CHR_BG` / `NESPHP_NES_CHR_SPR` (`chr_bulk_transfer`) |

ソースデータは静的 (4 つの 4KB CHR set を PRG-ROM bank 1 に焼き込み) なので、
スライド毎に中身を差し替えたければ `chr/` に CHR データを用意して
`make_font.php` で組む。PPU 側は CHR-**RAM** なので「切替」とはコピーのこと
であり、もはや CHR bank レジスタは存在しない (CNROM / CHR-ROM 時代は過去の
もの。下の変遷表を参照)。

## マッパー: MMC1 (mapper 1, SXROM 相当 + CHR-RAM 化)

### iNES ヘッダ (NES 2.0)

```
4E 45 53 1A   "NES" + EOF
04            byte 4 = PRG-ROM = 4 * 16KB = 64KB
00            byte 5 = CHR-ROM = 0 (CHR-RAM 化)
10            byte 6 (Flags 6): mapper LSB nibble = 1 (MMC1)
08            byte 7 (Flags 7): bit 2-3 = NES 2.0 marker
00            byte 8 = mapper bits 8-11 + submapper
00            byte 9 = PRG/CHR ROM size upper nibble
09            byte 10: PRG-RAM size = 64 << 9 = 32 KB (volatile)
07            byte 11: CHR-RAM size = 64 << 7 = 8 KB
00 00 00 00   bytes 12-15 (padding)
```

`vm/nesphp.s` の `.segment "HEADER"` と `vm/nesphp.cfg` が単一の真実。

### 変遷: CNROM → MMC1 / SXROM (CHR-RAM 化)

| | CNROM (古) | MMC1 SNROM (旧) | **MMC1 SXROM + CHR-RAM (現在)** |
|---|---|---|---|
| CHR | 32KB CHR-ROM | 128KB CHR-ROM 上限 | **8KB CHR-RAM** (起動時に PRG bank 1 から 8KB を PPU $0000-$1FFF へ転送) |
| CHR 切替粒度 | 8KB 一括 | 4KB × 2 面 | **CHR-RAM では bank 切替の意味は薄い** ($A000/$C000 reg は SXROM では PRG-RAM bank select に流用) |
| PRG-ROM | なし | 16KB 単位 ($8000 切替、$C000 固定) | **64KB**: bank 3 ($C000 固定) = VM CODE、bank 0/1/2 ($8000 切替可) = PHPSRC / CHRDATA / 予備 |
| PRG-RAM (WRAM) | なし | 8KB ($6000-$7FFF 単一 bank) | **32KB = 4 × 8KB bank** ($A000 reg bit 2-3 で切替): bank 0 = op_array+literals、bank 1 = ARR_POOL、bank 2 = STR_POOL、bank 3 = USER_RAM_EXT |

### CHR 配置

`chr/make_font.php` は今も 32KB の `font.chr` (4 × 8KB) を生成するが、ROM に
焼き込まれるのはその**先頭 16KB** だけで、PRG-ROM bank 1 (`CHRDATA` セグメント、
`vm/nesphp.s` の `.incbin "chr/font.chr", 0, $4000`) に **4 つの 4KB CHR set**
としてアドレスされる:

```
CHRDATA (PRG-ROM bank 1, 16KB) = 4 × 4KB CHR set
├── set 0: 通常フォント + カスタムタイル (旧 font.chr bank 0 の PT0)
├── set 1: インバースフォント            (旧 font.chr bank 0 の PT1)
├── set 2: set 0 のコピー               (旧 font.chr bank 1 の PT0)
└── set 3: set 1 のコピー               (旧 font.chr bank 1 の PT1)
   (font.chr の後半 16KB — 旧 bank 2-3 — は ROM に焼き込まれない)
```

起動時に reset コードが先頭 8KB (set 0-1) を CHR-RAM へコピーする: set 0 →
PPU $0000 (BG pattern table)、set 1 → PPU $1000 (sprite pattern table)。
`nes_chr_bg($n)` / `nes_chr_spr($n)` は共通サブルーチン `chr_bulk_transfer`
経由で、ランタイムに任意の 4KB set を再コピーする。

### MMC1 シリアル書き込みプロトコル

MMC1 のレジスタは **5bit シリアル** で書く。bit 0 から順に STA × 5 回を同じ
アドレス範囲に行い、5 回目で値がラッチされる:

```asm
.macro MMC1_WRITE addr
    STA addr      ; bit 0
    LSR A
    STA addr      ; bit 1
    LSR A
    STA addr      ; bit 2
    LSR A
    STA addr      ; bit 3
    LSR A
    STA addr      ; bit 4 → latch
.endmacro
```

4 つのアドレス範囲でレジスタを選択:

| アドレス | レジスタ | 用途 |
|---|---|---|
| $8000-$9FFF | Control | mirroring, PRG bank mode, CHR bank mode |
| $A000-$BFFF | CHR bank 0 | **SXROM + CHR-RAM では流用**: bit 2-3 = PRG-RAM bank select ($6000-$7FFF window、[02-ram-layout](./02-ram-layout.md) 参照) |
| $C000-$DFFF | CHR bank 1 | CHR-RAM では未使用 (8KB CHR-RAM は bank 化されない) |
| $E000-$FFFF | PRG bank | $8000-$BFFF の 16KB bank 番号 + WRAM enable |

CNROM と違い bus conflict は発生しない (MMC1 は専用の shift register IC)。

## `NESPHP_NES_CHR_BG` (0xF6): BG 用 4KB CHR set の差し替え

### 呼び出し

```php
nes_chr_bg(0);  // BG → CHR set 0 (通常フォント + カスタムタイル)
nes_chr_bg(1);  // BG → CHR set 1 (インバースフォント)
// ...最大 3 まで (CHRDATA 16KB / 4KB = 4 sets)
```

引数はコンパイル時の整数リテラル (0-3。`AND #$03` でクランプ)。

### VM 実装

PPU 転送先 hi byte $00 で `chr_bulk_transfer` を呼ぶ:

1. sprite_mode 中なら: NMI 無効 + rendering OFF (短い forced blanking、
   `nes_cls` と同じパターン。~25 ms ≈ 1.5 フレームの黒フラッシュ)。
   forced_blanking mode ではそのままコピーするので視覚的な副作用なし
2. PRG bank を 1 に切替 (`CHRDATA` が $8000-$BFFF にマッピングされる)
3. `$8000 + set × $1000` から PPU $0000-$0FFF へ PPUDATA 経由で 4KB コピー
4. PRG bank 0 に復帰。sprite_mode 中なら: VBlank 待ち → OAM DMA 再実行 →
   rendering ON に戻す

PPUCTRL bit 4 = 0 (reset で設定済み) なので BG は $0000 からタイルを取る。
**sprite 用 pattern table ($1000) には一切触れない**。

## `NESPHP_NES_CHR_SPR` (0xF5): sprite 用 4KB CHR set の差し替え

### 呼び出し

```php
nes_chr_spr(0);  // sprite → CHR set 0 (通常フォント + カスタムタイル)
nes_chr_spr(2);  // sprite → CHR set 2 (カスタム)
```

引数はコンパイル時の整数リテラル (0-3)。

### VM 実装

同じ `chr_bulk_transfer` を PPU 転送先 hi byte $10 で呼び、指定 set を
PPU $1000-$1FFF へコピーする。PPUCTRL bit 3 = 1 (reset で設定済み) なので
sprite はここからタイルを取る。**BG 用 pattern table ($0000) には一切触れない**。

### PPUCTRL による BG / sprite の分離

reset 時に `PPUCTRL = %00001000` を設定:
- bit 4 = 0: BG は PPU $0000-$0FFF (= `nes_chr_bg` が上書きする領域)
- bit 3 = 1: sprite は PPU $1000-$1FFF (= `nes_chr_spr` が上書きする領域)

この設定により `nes_chr_bg` と `nes_chr_spr` が**完全に独立**して動き、
CNROM 時代の「バンク切替で sprite が化ける」問題が構造的に解消されている。

起動時の状態 (set 0 = 通常フォントを $0000、set 1 = インバースフォントを
$1000) は `font.chr` bank 0 の元の 8KB PT0/PT1 レイアウトを再現するので、
**見た目は CHR-RAM 移行前と同一**。

### シリアライザの畳み込み (両方とも同じパターン)

```
INIT_FCALL_BY_NAME 1 "nes_chr_bg"    →  ZEND_NOP
SEND_VAL_EX int(N) 1                 →  ZEND_NOP
DO_FCALL_BY_NAME                     →  NESPHP_NES_CHR_BG
                                        op1_type = IS_CONST
                                        op1 = int literal の zval offset
```

`nes_chr_spr` も同一構造 (`NESPHP_NES_CHR_SPR` に変わるだけ)。

## 典型的な使い方

### パターン 1: BG をインバースに切替 (sprite はそのまま)

```php
nes_chr_bg(1);  // BG → CHR set 1 (インバースフォント)
nes_puts(4, 4, "HIGHLIGHTED");
nes_chr_bg(0);  // BG → CHR set 0 (通常に戻す)
nes_puts(4, 6, "NORMAL TEXT");
// sprite は $1000 を見ており、nes_chr_bg はそこに一切触れない
```

### パターン 2: BG と sprite を独立に切替

```php
// BG は装飾フォント set、sprite は通常フォント set に固定
nes_chr_bg(2);    // BG → CHR set 2 (カスタムフォント)
nes_chr_spr(0);   // sprite → CHR set 0 (通常フォント)
// → BG だけ別デザイン、sprite は安定して 'X' を表示し続ける
```

### パターン 3: スライド遷移

```php
nes_chr_bg(2);   // BG → タイトル用フォント (CHR set 2)
nes_cls();
nes_puts(4, 4, "SLIDE TITLE");
$k = fgets(STDIN);
nes_chr_bg(0);   // BG → 本文用フォント (CHR set 0)
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
新しい CHR で再リンクされる。ただし生成される 32KB のうち ROM に届くのは
**先頭 16KB** だけ (`CHRDATA` = 4KB set × 4) — font.chr の bank 2-3 を編集
してもビルドには影響しない点に注意。

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
function build_bank(array $font5x7, array $customTiles = []): string
{
    $bank = str_repeat("\x00", 8192);
    // ... ASCII 0x20-0x7F の glyph を pattern table 0 と 1 に埋める
    // ... $customTiles の各タイル (0x00-0x1F) を bp0/bp1 で書き込む
    return $bank;
}

$bank0 = build_bank($font5x7, $customTiles);
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

### `$customTiles` 配列: タイル 0x00-0x1F にグラフィックを配置

ASCII フォントはタイル 0x20-0x7F を使うため、**0x00-0x1F の 32 タイルは未使用**。
`chr/make_font.php` の `$customTiles` 配列でここにカスタムグラフィックを配置
できる。`build_bank()` が第 2 引数としてこの配列を受け取り、各タイルの
bitplane 0 / bitplane 1 を書き込む。

```php
$customTiles = [
    0x01 => [
        'bp0' => [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],  // 色 1
        'bp1' => [0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00],  // 色 2
    ],
    // ... 0x02, 0x03, 0x04 なども同様
];

$bank0 = build_bank($font5x7, $customTiles);
```

- `bp0` (bitplane 0): 立っているピクセルが色 1 になる
- `bp1` (bitplane 1): 立っているピクセルが色 2 になる
- 両方立てると色 3、両方 0 なら色 0 (背景色 / 透明)

#### 具体例: 日本国旗 (2×2 タイル = 16×16 ピクセル)

`examples/color.php` で使われている日本国旗は 4 タイル (0x01-0x04) で構成:

```
タイル配置:
  [0x01][0x02]    左上  右上
  [0x03][0x04]    左下  右下
```

各タイルは 2 つの bitplane を使う:
- **bitplane 0 (色 1 = 白)**: 旗の全面を塗る → `bp0` は全行 `0xFF`
- **bitplane 1 (色 2 = 赤)**: 日の丸の円だけ立てる → `bp1` に円のピクセルパターン

PHP 側では `nes_palette` で色 1 = `$30` (白)、色 2 = `$16` (暗い赤) を設定し、
`nes_put($x, $y, 1)` 等でタイル番号を直接指定して 2×2 に配置する。

#### 利用可能なタイル番号

| 範囲 | 用途 |
|---|---|
| 0x00 | 空白 (nametable のデフォルト値、使わない方が安全) |
| 0x01-0x04 | 日本国旗 (`examples/color.php`) |
| **0x05-0x0B** | テトリス用ピースタイル × 7 (I/O/T/S/Z/L/J、`examples/tetris.php` / `tetris2.php` / `tetris3.php`) |
| **0x0C** | レンガ壁 (テトリスの壁、`elephpant.php` の地面) |
| **0x10-0x13** | elePHPant sprite 16×16 = 2×2 タイル、立ち姿 (`examples/elephpant.php`) |
| **0x14-0x15** | elePHPant 歩行フレームの下半身 (歩幅) |
| **0x16-0x19** | 雲 16×16 = 2×2 タイル (SMB 風) |
| **0x1A-0x1D** | ? ブロック 16×16 = 2×2 タイル (SMB 風) |
| 0x0D-0x0F, 0x1E-0x1F | カスタムタイルに利用可能 (5 タイル) |
| 0x20-0x7E | ASCII フォント (make_font.php が自動生成。数字と大文字は chunky な 7×7 アーケード風 bold glyph、残りは 5×7) |
| 0x7F | DEL (未使用、カスタム利用可) |
| 0x80-0xFF | pattern table 1 側 (未使用、カスタム利用可) |

#### 具体例: テトリスピース (タイル 0x05-0x0B) と レンガ壁 (0x0C)

`examples/tetris.php` は BPS 版 Famicom テトリスに倣い **palette 1 を 1 種類だけ**
使う方式 (= color bleed 回避)。各ピースは 7×7 の縁取り (ring) + 中心 3×3 のコア
で識別、ring/core 色の組合せで 7 ピースを区別する:

```
col→ 0 1 2 3 4 5 6 7
row 0 R R R R R R R .
row 1 R . . . . . R .
row 2 R . C C C . R .
row 3 R . C C C . R .
row 4 R . C C C . R .
row 5 R . . . . . R .
row 6 R R R R R R R .
row 7 . . . . . . . .
```

- palette 1 = (`$0F` 黒 bg, `$30` 白 = slot 1, `$16` 赤 = slot 2, `$1A` 緑 = slot 3)
- 0x05 I: ring=3 緑 / core=3 緑 (緑単色)
- 0x06 O: ring=1 白 / core=1 白 (白単色)
- 0x07 T: ring=2 赤 / core=2 赤 (赤単色)
- 0x08 S: ring=3 緑 / core=2 赤 (緑枠+赤芯)
- 0x09 Z: ring=2 赤 / core=3 緑 (赤枠+緑芯)
- 0x0A L: ring=1 白 / core=2 赤 (白枠+赤芯)
- 0x0B J: ring=2 赤 / core=1 白 (赤枠+白芯)

レンガ壁 (0x0C) は palette 0 default colors (`$10` gray + `$00` dark gray)
を利用する 8×8 のレンガパターン (上下水平モルタル + 縦モルタル + オフセット)。
play field の attribute は palette 1 にしているため、frame は play field
attribute block と被らない位置 (row 3 / row 26) に配置することで pal 0
(default) のグレー表示を確保している。

### 例 1: バンク 1 に全く別のフォントを入れる

```php
// 自作の別フォントビットマップを用意
$fontDecorative = [ /* 96 個の [r0..r7] */ ];

$bank0 = build_bank($font5x7);
$bank1 = build_bank($fontDecorative);

$banks = [0 => $bank0, 1 => $bank1, 2 => $bank0, 3 => $bank0];
```

`$banks[0]` の PT0/PT1 が CHR set 0/1 に、`$banks[1]` の PT0/PT1 が set 2/3
になる (bank 2-3 は ROM に届かない)。上のレイアウトなら `nes_chr_bg(2)` で
BG が装飾フォントの PT0 に切り替わる。

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

`CHRDATA` は PRG-ROM bank 1 全体 = **16KB = 4 CHR set**。これ以上の set を
持つには PRG bank をもう 1 本使う (bank 2 は現在予備) か、タイルデータの圧縮が
必要。PPU 側は CHR-RAM なので、ランタイムに PRG からタイルを差し込んだり
生成したりすることは構造的には可能 — 現状ではコピーループの intrinsic が
あるだけ。

## 制限事項

| 制限 | 理由 | 緩和策 |
|---|---|---|
| `nes_chr_bg` / `nes_chr_spr` は sprite_mode 中に ~25 ms の黒フラッシュを起こす | 4KB の PPUDATA 転送は VBlank に収まらないため、短い forced blanking パス (NMI off → コピー → rendering on) を使う | NMI キュー経由でコピーを複数 VBlank に分割する (今後) |
| mid-frame 切替不可 | scanline IRQ 非対応 (MMC1 にはタイマーなし) | MMC3 に昇格すれば可能 |
| CHR set は 4 つだけ | CHRDATA = PRG-ROM bank 1 (16KB) のみ | PRG bank 2 (予備) を追加 CHRDATA に使う |
| set 2-3 は初期状態で set 0-1 のコピー | `chr/make_font.php` がそう組むため | `$banks` を書き換えて再生成 |
| タイル単位のランタイム書き込み不可 | PPUDATA レベルのタイル書き込みを露出する intrinsic がない (CHR-RAM 自体は書き込み可能) | `nes_chr_poke` 的な intrinsic を追加 (今後) |

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — iNES ヘッダ、PRG / CHR 容量
- [04-opcode-mapping](./04-opcode-mapping.md) — `NESPHP_NES_CHR_BG` / `NESPHP_NES_CHR_SPR` の番号
- [06-display-io](./06-display-io.md) — PPUCTRL 全ビットの意味、パレット
- [10-devlog](./10-devlog.md) — Phase 5D の設計経緯
