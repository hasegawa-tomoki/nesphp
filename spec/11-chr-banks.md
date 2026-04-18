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

## マッパー: MMC1 (mapper 1, SNROM 構成)

### iNES ヘッダ

```
4E 45 53 1A   "NES" + EOF
02            PRG-ROM = 2 * 16KB = 32KB
04            CHR-ROM = 4 * 8KB  = 32KB
10            Flags 6: mapper LSB nibble = 1 (MMC1)
00            Flags 7
01            PRG-RAM = 1 * 8KB (WRAM $6000-$7FFF)
00 ...        padding
```

`vm/nesphp.s` の `.segment "HEADER"` と `vm/nesphp.cfg` が単一の真実。

### CNROM からの昇格点

| | CNROM (旧) | MMC1 (現在) |
|---|---|---|
| CHR 切替粒度 | 8KB 一括 | **4KB × 2 面を独立指定** |
| 切替方法 | STA 1 回 (bus-conflict 注意) | **シリアル 5bit × 5 回** (bus-conflict なし) |
| BG と sprite を別 bank にできるか | ❌ | ✅ (CHR bank 0/1 を個別制御) |
| PRG banking | なし | **16KB 単位** ($8000 側切替、$C000 固定) |
| WRAM | なし | **8KB** ($6000-$7FFF) |
| 最大 CHR 容量 | 32KB | **128KB** |

### CHR 配置

MMC1 の 4KB CHR banking mode では、32KB CHR-ROM は 8 つの 4KB bank として
アドレスされる。font.chr の物理レイアウト (8KB × 4) は変わらないが、
**4KB 単位で PPU にマッピング**できるようになった:

```
CHR-ROM (32KB) = 8 × 4KB bank
├── 4KB bank 0: 通常フォント (旧 CNROM bank 0 の PT0)
├── 4KB bank 1: インバースフォント (旧 CNROM bank 0 の PT1)
├── 4KB bank 2: 通常フォント (旧 CNROM bank 1 の PT0)
├── 4KB bank 3: インバースフォント (旧 CNROM bank 1 の PT1)
├── 4KB bank 4-5: (旧 CNROM bank 2)
└── 4KB bank 6-7: (旧 CNROM bank 3)
```

MMC1 の 2 つの CHR レジスタで PPU 空間にマッピング:
- **CHR bank 0 register ($A000)** → PPU $0000-$0FFF にどの 4KB bank を置くか
- **CHR bank 1 register ($C000)** → PPU $1000-$1FFF にどの 4KB bank を置くか

### 後方互換性

`nes_chr_bank($n)` は CNROM 時代と同じ API を維持。内部で **CHR bank 0 = N×2、
CHR bank 1 = N×2+1** を同時にセットする (旧 8KB bank N と等価):

```asm
; nes_chr_bank(1) の内部動作
LDA #2           ; 1 * 2
MMC1_WRITE $A000  ; CHR bank 0 = 4KB bank 2
LDA #3           ; 1 * 2 + 1
MMC1_WRITE $C000  ; CHR bank 1 = 4KB bank 3
```

`chr/make_font.php` が生成する。バンク毎に独自タイルを入れたい場合は
`$banks` 配列を書き換えて `php chr/make_font.php` を再実行する。

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
| $A000-$BFFF | CHR bank 0 | PPU $0000-$0FFF の 4KB bank 番号 |
| $C000-$DFFF | CHR bank 1 | PPU $1000-$1FFF の 4KB bank 番号 |
| $E000-$FFFF | PRG bank | $8000-$BFFF の 16KB bank 番号 + WRAM enable |

CNROM と違い bus conflict は発生しない (MMC1 は専用の shift register IC)。

## `NESPHP_NES_CHR_BG` (0xF6): BG 用 4KB CHR bank 切替

### 呼び出し

```php
nes_chr_bg(0);  // BG → 4KB bank 0 (通常フォント)
nes_chr_bg(1);  // BG → 4KB bank 1 (インバースフォント)
nes_chr_bg(2);  // BG → 4KB bank 2 (カスタム)
// ...最大 7 まで (32KB / 4KB = 8 banks)
```

引数はコンパイル時の整数リテラル (0-7)。

### VM 実装

MMC1 CHR bank 0 register ($A000) にシリアル 5bit 書き込み:

```asm
LDA OP1_VAL+1
AND #$07
MMC1_WRITE $A000
```

PPU $0000-$0FFF に指定 bank がマッピングされる。PPUCTRL bit 4 = 0 (reset で
設定済み) なので BG はここからタイルを取る。**sprite 側 ($1000) には一切影響
しない**。

## `NESPHP_NES_CHR_SPR` (0xF5): sprite 用 4KB CHR bank 切替

### 呼び出し

```php
nes_chr_spr(0);  // sprite → 4KB bank 0 (通常フォント)
nes_chr_spr(4);  // sprite → 4KB bank 4 (カスタム)
```

引数はコンパイル時の整数リテラル (0-7)。

### VM 実装

MMC1 CHR bank 1 register ($C000) にシリアル 5bit 書き込み:

```asm
LDA OP1_VAL+1
AND #$07
MMC1_WRITE $C000
```

PPU $1000-$1FFF に指定 bank がマッピングされる。PPUCTRL bit 3 = 1 (reset で
設定済み) なので sprite はここからタイルを取る。**BG 側 ($0000) には一切影響
しない**。

### PPUCTRL による BG / sprite の分離

reset 時に `PPUCTRL = %00001000` を設定:
- bit 4 = 0: BG は PPU $0000-$0FFF (= CHR bank 0 register が制御)
- bit 3 = 1: sprite は PPU $1000-$1FFF (= CHR bank 1 register が制御)

この設定により `nes_chr_bg` と `nes_chr_spr` が**完全に独立**して動き、
CNROM 時代の「バンク切替で sprite が化ける」問題が構造的に解消されている。

初期状態では CHR bank 0 = CHR bank 1 = 0 (両方とも 4KB bank 0 = 通常フォント)
なので、**見た目は従来と同一**。

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
nes_chr_bg(1);  // BG → 4KB bank 1 (インバースフォント)
nes_puts(4, 4, "HIGHLIGHTED");
nes_chr_bg(0);  // BG → 4KB bank 0 (通常に戻す)
nes_puts(4, 6, "NORMAL TEXT");
// sprite は $1000 (CHR bank 1 register) を見ているので影響を受けない
```

### パターン 2: BG と sprite を独立に切替

```php
// BG は装飾フォント bank、sprite は通常フォント bank に固定
nes_chr_bg(2);    // BG → 4KB bank 2 (カスタムフォント)
nes_chr_spr(0);   // sprite → 4KB bank 0 (通常フォント)
// → BG だけ別デザイン、sprite は安定して 'X' を表示し続ける
```

### パターン 3: スライド遷移

```php
nes_chr_bg(4);   // BG → タイトル用フォント (4KB bank 4)
nes_cls();
nes_puts(4, 4, "SLIDE TITLE");
$k = fgets(STDIN);
nes_chr_bg(0);   // BG → 本文用フォント (4KB bank 0)
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
| `nes_chr_bank` / `nes_chr_bg` が sprite_mode 中に tearing する | 書き込みが即時反映されて VBlank 同期していない | Phase 3 の NMI キューに CHR 切替コマンドも載せる (今後) |
| mid-frame 切替不可 | scanline IRQ 非対応 (MMC1 にはタイマーなし) | MMC3 に昇格すれば可能 |
| sprite 用 pattern table は `nes_chr_bg` の対象外 | bit 3 を触る intrinsic が未実装 | `nes_chr_spr($n)` を追加すれば対応可能 |
| バンク 1-3 は初期状態で bank 0 のコピー | `chr/make_font.php` がそう組むため | `$banks` を書き換えて再生成 |
| ランタイムでのタイルデータ変更不可 | CHR-**ROM** のため書き込みできない | CHR-RAM 対応構成に変更が必要 |

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — iNES ヘッダ、PRG / CHR 容量
- [04-opcode-mapping](./04-opcode-mapping.md) — `NESPHP_NES_CHR_BANK` / `NESPHP_NES_CHR_BG` の番号
- [06-display-io](./06-display-io.md) — PPUCTRL 全ビットの意味、パレット
- [10-devlog](./10-devlog.md) — Phase 5D の設計経緯
