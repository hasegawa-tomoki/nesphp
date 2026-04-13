# 06. PPU 表示とコントローラ入力

[← README](./README.md) | [← 05-toolchain](./05-toolchain.md) | [→ 07-roadmap](./07-roadmap.md)

## CHR-ROM とフォント

- CHR-ROM 8KB のうち、最初の 2KB (パターンテーブル 0) をフォントに使う
- **タイル番号 = ASCII コード**と決め打ち配置:
  - タイル `0x20` = スペース
  - タイル `0x41` = 'A'
  - タイル `0x48` = 'H'
  - …
- これにより `zend_string.val[]` のバイトをそのまま nametable に書ける (`LDA val_byte : STA PPUDATA`)
- 8KB のうち、0x00-0x1F と 0x80-0xFF は未使用 (将来のスプライト用に予備)

### font.chr の作り方

- NES 向けのフリーフォント (例: `8x8-ascii-bitmap-font`) を使う
- 1 タイル = 8×8 ピクセル = 16 バイト (CHR 形式)
- 96 タイル (0x20-0x7F) = 1536 バイト
- 残り 6656 バイトは `00` 埋め

---

## PPU 初期化シーケンス (リセットハンドラ内)

1. `$2000 = 0` (PPUCTRL 無効化)
2. `$2001 = 0` (PPUMASK 無効化 = 強制 blanking)
3. `$4010 = 0` (DMC 無効化)
4. 2 回の VBL 待ち (`BIT $2002` → `BPL $-3` を 2 回)
5. RAM クリア
6. **OAM shadow `$0200-$02FF` を y=$FF で初期化** (64 スプライトを画面外に隠す)
7. パレット書き込み (`$3F00-$3F1F` に 32 バイト)
8. nametable クリア (スペース `$20` で埋める 960 + attr 64 バイト)

---

## 実装済み表示モード state machine

現行の nesphp VM は 2 つの PPU state を持つ。

```
         [forced_blanking]                       [sprite_mode]
         PPUMASK = 0                             PPUMASK = %00011110 (BG+sprite)
         NMI off                                 NMI on
         nametable に直接書ける                    echo/nes_put は使えない
         sprite は表示されない                     OAM DMA が毎 VBlank で走る
               │                                        ▲
               │  ┌── fgets: 一時的に rendering on, 待機, off ──┐
               │  │                                            │
               │  └────────────────────────────────────────────┘
               │                                        │
               │                                        │
               │        最初の nes_sprite 呼び出し       │
               └────────────────────────────────────────┘
```

### forced_blanking (初期状態 / sprite_mode に遷移前)

- `PPUMASK = 0`、レンダリング停止 → 画面は黒
- `echo` / `nes_put` は強制 blanking 中に `PPUADDR` / `PPUDATA` を直接叩ける
- `fgets` は以下のサブフロー:
  1. `PPUSCROLL = 0,0` + `PPUMASK = %00001110` (rendering 一時 on)
  2. コントローラ全ボタン release 待ち → 新押下待ち
  3. `PPUMASK = 0` (forced blanking 復帰) + `PPUADDR = PPU_CURSOR` 再セット
  4. button 対応の `button_str_X` の ROM offset を result に書き戻し
- ユーザから見ると「ボタン押してる間だけ画面が見える」体験

### sprite_mode (初回 nes_sprite 後)

初回 `nes_sprite` 呼び出しで `enable_sprite_mode` ルーチンが走る:

1. VBlank 待ち (`BIT PPUSTATUS` / `BPL :-`)
2. 初回 OAM DMA (`STA $4014`) で隠しスプライト (y=$FF) を反映
3. `PPUSCROLL = 0,0` (スクロールリセット)
4. `PPUCTRL = %10000000` (NMI enable、sprite/BG pattern table 0)
5. `PPUMASK = %00011110` (BG + sprite rendering、左端 8 ピクセル表示)
6. `sprite_mode_on = 1`

以降:

- `nes_sprite` は OAM shadow `$0200-$0203` に (y, tile, attr, x) を書くだけ。NMI が毎 VBlank で DMA
- `fgets` は rendering を切らずにボタン待ち (NMI が走り続けるので画面表示継続)
- `echo` / `nes_put` は **使ってはいけない** (rendering 中の nametable 書き込みは PPU state を壊す)

### 状態遷移の制約

- **一度 sprite_mode に入ったら forced_blanking に戻れない** (MVP では意図的に単方向)
- `echo` は sprite_mode 前にしか期待通り動かない。ユーザコードは「初期表示の echo → `nes_sprite` 開始 → loop」というパターンを守る必要
- 将来、NMI 同期 echo (下記) を実装すれば両モードで echo が動くようになる

### NMI ハンドラ (現行実装)

```asm
nmi:
    PHA : TXA : PHA : TYA : PHA    ; A/X/Y 保存
    LDA #>OAM_SHADOW               ; $02
    STA OAM_DMA                    ; $4014: OAM DMA 512+ cycle 停止
    BIT PPUSTATUS                  ; latch reset
    LDA #0
    STA PPUSCROLL : STA PPUSCROLL  ; scroll 0, 0
    PLA : TAY : PLA : TAX : PLA
    RTI
```

単純に OAM DMA + scroll reset するだけ。nametable 転送 / 任意の VBlank 処理は現段階では未実装。

---

## パレット

黒背景に白文字で統一。BG / sprite ともに同じパターンテーブル (pattern table 0) のフォントを参照する。

```asm
palette_data:
    .byte $0F, $30, $10, $00   ; BG palette 0  (背景=黒, 文字=白)
    .byte $0F, $30, $10, $00   ; BG palette 1-3 (同上)
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00   ; sprite palette 0
    .byte $0F, $30, $10, $00   ; sprite palette 1-3
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
```

sprite はフォントの 1bit glyph を使うので色 1 (白) が見え、色 0 は透明。

---

## nametable への ASCII 書き込み (MVP: 強制 blanking 方式)

PPU の VRAM `$2000-$23FF` が nametable 0 (32×30 タイル = 960 バイト)。

### 書き込み手順

1. `PPUADDR` ($2006) に書き込み先アドレスを high, low の順で書く
2. `PPUDATA` ($2007) にタイル番号 (ASCII コード) を順次書き込む。`PPUCTRL` の VRAM 増分フラグで自動的に +1 進む

### `ppu_write_string_forced_blank` ルーチン

```asm
; 入力:
;   TMP0  zend_string.val[] の先頭 ROM アドレス (16bit)
;   TMP1  len (下位 2B)
; 副作用:
;   PPU_CURSOR を更新 (次の echo の継続位置)
ppu_write_string_forced_blank:
    ; PPUADDR を PPU_CURSOR にセット
    LDA $2002            ; ラッチリセット
    LDA PPU_CURSOR+1     ; high
    STA $2006
    LDA PPU_CURSOR       ; low
    STA $2006

    ; len バイトを PPUDATA に書き出す
    LDY #0
write_loop:
    LDA (TMP0),Y
    STA $2007
    INY
    CPY TMP1             ; len == Y ?
    BNE write_loop       ; (len が 256 以上なら要拡張)

    ; PPU_CURSOR を進める
    LDA PPU_CURSOR
    CLC
    ADC TMP1
    STA PPU_CURSOR
    BCC :+
    INC PPU_CURSOR+1
:
    RTS
```

### カーソル初期位置

`PPU_CURSOR` は `$2000 + 行*32 + 列` で初期化。MVP では 10 行目 6 列目あたり (`$20C6`) から開始すると見やすい。

### 注意

- 強制 blanking 中 (`$2001 = 0`) 以外で `PPUADDR`/`PPUDATA` を叩くと PPU 内部状態が壊れる
- MVP は VM メインループ全体が強制 blanking 中に実行されるので問題ない
- 延長ゴールで動的 echo (実行中の表示更新) が必要になったら NMI 同期方式に昇格

---

## 延長ゴール: NMI 同期方式

### 問題

VM が長時間動き続ける (while ループ等) と、強制 blanking のままでは画面が真っ黒のまま。VM 実行中にも画面を見せるには、レンダリングを有効化した状態で ecore できる必要がある。

### 解決: テキスト行バッファ + NMI 転送

1. `ZEND_ECHO` ハンドラは **RAM 上のテキスト行バッファ** (`$0600-$06FF`) に書き、PPU は触らない
2. NMI ハンドラが VBlank 中に行バッファの内容を nametable にコピー
3. コピー後、行バッファをクリア

### NMI ハンドラ (延長版)

```asm
nmi:
    PHA
    TXA
    PHA
    TYA
    PHA

    ; OAM DMA (スプライト用)
    LDA #$02
    STA $4014

    ; テキスト行バッファを nametable に転送
    JSR flush_text_buffer

    ; PPU_CURSOR 更新
    ; (scroll 等は MVP では不要)

    PLA
    TAY
    PLA
    TAX
    PLA
    RTI
```

1 フレーム (1/60 秒) あたり VBlank で転送できるバイト数は約 2000 バイト (CPU サイクル予算 ~2273)。MVP の 32×30 = 960 文字は 1 フレームで余裕。

---

## 延長ゴール: コントローラ入力 (`fgets(STDIN)` マッピング)

### PHP 側の書き方

```php
<?php
while (true) {
    $key = fgets(STDIN);
    if ($key === "A") echo "A pressed";
    // ...
}
```

### シリアライザの畳み込み

opcache ダンプでは:

```
INIT_FCALL 1 "fgets"
SEND_VAL CONST "STDIN"  (実際はリソース定数)
DO_FCALL
ASSIGN CV($key) TMP#N
```

この `INIT_FCALL`+`SEND_VAL`+`DO_FCALL` の 3 命令シーケンスを serializer が検出し、`ZEND_DO_FCALL` の `op1.extended_value` に特殊組み込み ID `BUILTIN_READ_INPUT` を埋め込む。

### VM 側の実装

```asm
handle_do_fcall:
    ; op1.extended_value に組み込み ID が入っている
    LDY #12
    LDA (VM_PC),Y
    CMP #BUILTIN_READ_INPUT
    BEQ do_read_input
    CMP #BUILTIN_SPRITE_SET
    BEQ do_sprite_set
    ; 他の組み込みは未対応
    JMP handle_unimpl

do_read_input:
    JSR read_controller
    ; A に押されたボタンの ASCII コード (U/D/L/R/A/B/S/T、なし=0)
    ; これを IS_STRING の 1 文字文字列として result スロットに push
    ...
    JMP advance
```

### コントローラ読み取り (NESdev Wiki のリトライ版)

DPCM グリッチ対策のため、同じ結果が 2 回連続で得られるまでループ:

```asm
read_controller:
read_loop:
    LDA #$01
    STA $4016            ; コントローララッチ
    LDA #$00
    STA $4016            ; 読み取り開始

    LDX #$08             ; 8 ボタン
read_bit:
    LDA $4016
    LSR A                ; bit 0 を C に
    ROL ctrl_temp        ; C を ctrl_temp に shift in
    DEX
    BNE read_bit

    ; DPCM 干渉対策: 2 回読んで一致すれば信頼
    LDA ctrl_temp
    CMP ctrl_prev
    BNE read_loop
    STA ctrl_current

    ; ボタンマッピング表でビット → ASCII に変換
    ; 優先順位: A > B > Start > Select > Up > Down > Left > Right
    ...
    RTS
```

### ボタン → ASCII マッピング

| ビット位置 (NES 標準) | ボタン | ASCII |
|---------------------|--------|-------|
| 0 | A | `A` (0x41) |
| 1 | B | `B` (0x42) |
| 2 | Select | `S` (0x53) |
| 3 | Start | `T` (0x54) |
| 4 | Up | `U` (0x55) |
| 5 | Down | `D` (0x44) |
| 6 | Left | `L` (0x4C) |
| 7 | Right | `R` (0x52) |

「直前フレームで新規押下された中で最優先のボタン 1 個の ASCII」を返す。何も押されていなければ `IS_NULL` を返す (PHP 側では `while` で待てる)。

---

## 延長ゴール: スプライト

### PHP 側

```php
<?php
nes_sprite_set(0, 64, 100, 0xA0);   // sprite id=0, x=64, y=100, tile=0xA0
```

### serializer の畳み込み

`INIT_FCALL 4 "nes_sprite_set"` + `SEND_VAL × 4` + `DO_FCALL` を検出し、`ZEND_DO_FCALL` の extended_value に `BUILTIN_SPRITE_SET` を埋め込む。

### VM 側

```asm
do_sprite_set:
    ; VM スタックから 4 引数 (tile, y, x, id) を pop
    JSR vm_pop            ; tile
    ...
    JSR vm_pop            ; id

    ; OAM シャドウ $0200 + id*4 に (y, tile, attr=0, x) を書く
    LDA id
    ASL A                ; id * 2
    ASL A                ; id * 4
    TAX
    LDA y
    STA $0200,X
    INX
    LDA tile
    STA $0200,X
    INX
    LDA #0               ; attr
    STA $0200,X
    INX
    LDA x
    STA $0200,X

    JMP advance
```

OAM シャドウは次の VBlank で NMI ハンドラが `$4014` に書いて OAM DMA でハードウェアに転送する。

---

## 延長ゴール: `ZEND_CONCAT` 用の RAM 文字列バッファ

固定 256B のバッファを 1 本だけ `$0600-$06FF` に配置。`ZEND_CONCAT` 実行時:

1. OP1 (IS_STRING) をバッファにコピー
2. 続けて OP2 (IS_STRING) をコピー
3. 結果 zval の type = IS_STRING、payload = RAM バッファオフセット

RAM 文字列は **実行フレーム内でのみ有効** という割り切り (次の `ZEND_CONCAT` で上書きされる)。これで GC 不要。同時に 2 本以上の RAM 文字列を持てない制約があるが、MVP + 延長第 1 段階では問題にならない。

---

## 関連ドキュメント

- [02-ram-layout](./02-ram-layout.md) — テキスト行バッファ / OAM シャドウ / CONCAT バッファの RAM 配置
- [03-vm-dispatch](./03-vm-dispatch.md) — `ZEND_ECHO` handler から `ppu_write_string_forced_blank` を呼ぶ流れ
- [04-opcode-mapping](./04-opcode-mapping.md) — 組み込み関数畳み込みの詳細
