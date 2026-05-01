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
         nametable に直接書ける                    echo/nes_put/nes_puts は NMI キュー経由
                                                  nes_cls は brief force-blanking
                                                   (~1-2 フレーム黒フラッシュ)
         sprite は表示されない                     OAM DMA が毎 VBlank で走る
               │                                        ▲
               │  ┌── fgets: 一時的に rendering on, 待機, off ──┐
               │  │                                            │
               │  └────────────────────────────────────────────┘
               │                                        │
               │                                        │
               │        最初の nes_sprite_at 呼び出し       │
               └────────────────────────────────────────┘
```

### forced_blanking (初期状態 / sprite_mode に遷移前)

- `PPUMASK = 0`、レンダリング停止 → 画面は黒
- `echo` / `nes_put` / `nes_puts` / `nes_cls` は強制 blanking 中に `PPUADDR` / `PPUDATA` を直接叩ける
- `fgets` は以下のサブフロー:
  1. `PPUSCROLL = 0,0` + `PPUMASK = %00001110` (rendering 一時 on)
  2. コントローラ全ボタン release 待ち → 新押下待ち
  3. `PPUMASK = 0` (forced blanking 復帰) + `PPUADDR = PPU_CURSOR` 再セット
  4. button 対応の `button_str_X` の ROM offset を result に書き戻し
- ユーザから見ると「ボタン押してる間だけ画面が見える」体験

### sprite_mode (初回 nes_sprite_at 後)

初回 `nes_sprite_at` 呼び出しで `enable_sprite_mode` ルーチンが走る:

1. VBlank 待ち (`BIT PPUSTATUS` / `BPL :-`)
2. 初回 OAM DMA (`STA $4014`) で隠しスプライト (y=$FF) を反映
3. `PPUSCROLL = 0,0` (スクロールリセット)
4. `PPUCTRL = %10000000` (NMI enable、sprite/BG pattern table 0)
5. `PPUMASK = %00011110` (BG + sprite rendering、左端 8 ピクセル表示)
6. `sprite_mode_on = 1`

以降:

- `nes_sprite_at` は OAM shadow `$0200 + $idx*4` 先頭から (y, tile, x) を書く (attr は触らない、`nes_sprite_attr` で別途設定)。NMI が毎 VBlank で全 64 sprite 分を OAM に DMA
- `fgets` は rendering を切らずにボタン待ち (NMI が走り続けるので画面表示継続)
- `echo` / `nes_put` / `nes_puts` は **Phase 3 (NMI 同期書き込みキュー) により動く**。実際の PPU 書き込みは NMI ハンドラが VBlank 中に行う (下記参照)
- `nes_cls` は **Phase 3.1 (brief force-blanking) により動く**。1024 バイトは 1 VBlank 予算 (~2273 cycle) に入らないため NMI キュー経由ではなく、呼び出し時に一時的に `PPUMASK = 0` で rendering を止めて clear し、次 VBlank 同期で rendering を再開する方式。可視効果は 1-2 フレームの黒フラッシュで、スライド遷移のトランジションとして自然

### 状態遷移の制約

- **一度 sprite_mode に入ったら forced_blanking に戻れない** (MVP では意図的に単方向、`sprite_mode_on` フラグは一度 1 になったら 0 に戻らない)
- `echo` / `nes_put` / `nes_puts` は **Phase 3 以降、両モードで動く** (sprite_mode では NMI 同期書き込みキュー経由)
- `nes_cls` は **Phase 3.1 以降、両モードで動く** (sprite_mode では brief force-blanking、rendering を一時的に切って clear、次 VBlank で再開)

### NMI 同期書き込みキュー (Phase 3)

sprite_mode 中の nametable 書き込みを「呼んだ瞬間にキューへ積む → 次 VBlank で実際に PPU に流し込む」モデルで実現する。これにより rendering を止めずに nametable 更新ができる。

キュー実体: `NMI_QUEUE_ADDR = $0300`、256 バイトのリングバッファ。フォーマット:

```
[addr_hi addr_lo len data_0 ... data_{len-1}]  ← 1 エントリ
[addr_hi addr_lo len data_0 ... data_{len-1}]  ← 次エントリ
...
```

- **`nmi_queue_write`** (zero page, 1B): main CPU が次に append するオフセット (producer)
- **`nmi_queue_read`** (zero page, 1B): NMI が次に処理するオフセット (consumer)
- **両方ともモノトニック増加**する uint8 で、256 で自然 wrap。`read == write` で空、`(write - read - 1) & $FF` が使用中バイト数
- **page 境界整列 ($0300)** にしてあるので、`LDA NMI_QUEUE_ADDR, X` の X 自動 wrap で終端をまたぐエントリも透過アクセス

Race-free 設計:

- `write` は main のみ、`read` は NMI のみが更新する
- main は空き容量を `(read - write - 1) & $FF` で計算して、3 + len 以上あれば append
- append 中に NMI が fire しても、NMI は commit 前の `write` を見るので新エントリ領域には触れず、old entries を flush して `read` を `write` に追いつかせるだけ
- main が X レジスタに cache した write_head は NMI に影響されない (NMI は reset をしない設計)

`flush_nmi_queue` は NMI ハンドラ内から呼ばれ、`read..write-1` のエントリを順に PPUADDR/PPUDATA へ流し込む。1 VBlank で 256 バイト全部を flush しても ~1300 cycle で予算内。

`enqueue_ppu_nt` は producer 側のヘルパで、TMP0/TMP1/TMP2 に (addr, src ptr, len) を入れて JSR する。空きが足りない場合は NMI drain を busy-wait。

ハンドラは `ppu_write_bytes` に集約されていて、`sprite_mode_on` を見て「forced_blanking なら PPUADDR/PPUDATA 直書き、sprite_mode なら enqueue」に分岐する。

### nes_cls の brief force-blanking (Phase 3.1)

`nes_cls` は nametable 0 全域 (1024B) を空白で埋めるため、1 VBlank 予算 (~2273 cycle) には収まらず NMI キュー方式を使えない。代わりに sprite_mode 中の `nes_cls` 呼び出しでは以下を行う:

1. `ppu_ctrl_shadow` を 6502 スタックに退避
2. `PPUCTRL` bit 7 クリア (NMI 一時無効化)。clear 中に NMI が発火して `flush_nmi_queue` が PPUADDR を上書きしないようにする
3. `PPUMASK = 0` で rendering OFF → PPU は強制 blanking 状態へ
4. 既存の 1024B clear ループを実行
5. `BIT PPUSTATUS` / `BPL` で次 VBlank 開始まで wait (NMI 無効化済みなので flag が勝手にクリアされない)
6. `STA $4014` で OAM DMA を手動実行 (NMI 無効化期間中の OAM 更新の補償、1 回だけ)
7. `PPUSCROLL = 0, 0` で scroll 復帰
8. `PPUMASK = %00011110` で rendering 再開
9. `ppu_ctrl_shadow` をスタックから復元、`PPUCTRL` に書き戻す (NMI 再有効化)
10. `PPU_CURSOR` を `NAMETABLE_START` に戻して `JMP advance`

可視効果は「呼び出した瞬間から次 VBlank までの ~1-2 フレーム間、画面が真っ黒になる」。スライド遷移のトランジションとしては自然なフラッシュで、sprite 表示中に清潔にスライドを切り替えられる。forced_blanking パスは完全に無変更で、`sprite_mode_on == 0` のときは従来通りの高速直書き。

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

`nes_chr_bg($n)` で BG 用 4KB CHR bank (0-7) を、`nes_chr_spr($n)` で sprite 用
4KB CHR bank (0-7) を独立に切り替えられる (MMC1 の 4KB CHR banking)。
PPUCTRL bit 4 = 0 (BG → $0000) / bit 3 = 1 (sprite → $1000) により両者が完全
に分離している。詳細は [11-chr-banks](./11-chr-banks.md)。

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

## リアルタイム入力 API (`nes_vsync` + `nes_btn`)

`fgets(STDIN)` は release→press を待つ blocking 仕様で「押した瞬間」を 1 文字返す。対して L3S コンパイラは **poll 型 API** も持つ:

### intrinsic

| 関数 | 動作 |
|------|------|
| `nes_vsync()` | 次の VBlank (NMI) まで spin wait。sprite_mode が off なら `enable_sprite_mode` を自動で呼び、NMI + rendering を有効化する。1 フレーム = 1/60 秒を同期単位にしたい時に呼ぶ |
| `nes_btn()` | **0 引数**。現在のコントローラ状態を IS_LONG で返す (下位 1B = bitmask)。呼び出し側でビット演算 (`&` / `\|`) でボタンを判定する |

### ビットマスク対応表

```
A     = 0x80   (bit 7)
B     = 0x40
Select= 0x20
Start = 0x10
Up    = 0x08
Down  = 0x04
Left  = 0x02
Right = 0x01
```

ビット演算 (`&`) で個別検査。複数 bit の OR で「A or L」同時検出:
```php
$b = nes_btn();
if ($b & 0x82) { /* A または L */ }
```

### 典型的な game loop

```php
<?php
$x = 120; $y = 120;
nes_sprite_at(0, $x, $y, 88);
while (true) {
    nes_vsync();                   // 1 フレーム待つ
    $b = nes_btn();                // コントローラ状態を 1 回取得
    if ($b & 0x02) { $x = $x - 1; }  // L
    if ($b & 0x01) { $x = $x + 1; }  // R
    if ($b & 0x08) { $y = $y - 1; }  // U
    if ($b & 0x04) { $y = $y + 1; }  // D
    nes_sprite_at(0, $x, $y, 88);  // 座標反映
}
```

押しっぱなしで毎フレーム座標が変わる = 60 px/sec の連続移動。`fgets` での release-press 方式では不可能だったゲーム的な UX が実現する (`examples/poll.php`)。

### VM 側の実装

`handle_nesphp_nes_vsync` (`vm/nesphp.s`) は、まず `sprite_mode_on` が 0 なら `enable_sprite_mode` を呼んで NMI を有効化。その後:

```asm
LDA vblank_frame         ; NMI で INC される 8bit カウンタ
STA TMP0
:
LDA vblank_frame
CMP TMP0
BEQ :-                   ; 値が変わる = NMI が 1 回発火した
```

`handle_nesphp_nes_btn` は `read_controller` でコントローラ状態を更新し、`buttons` ZP の値を `IS_LONG` の下位 1B として result スロットへ書く (0 引数)。ビット検査は呼び出し側が `ZEND_BW_AND` (`&` 演算子) で行う。

### `fgets` との使い分け

- **`fgets(STDIN)`**: モーダル UI (メニュー、スライド遷移)、1 回押したら確定
- **`nes_vsync()` + `nes_btn($mask)`**: ゲームループ、アニメーション、押しっぱなし連続移動

両方を同じプログラム内で混在させることも可能 (`nes_sprite_at` 呼出で sprite_mode に入れば NMI が回るので、`fgets` も `nes_vsync` も動く)。

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

## マルチスプライト: `nes_sprite_at` / `nes_sprite_attr`

### PHP 側

```php
<?php
// 任意 OAM スロット (0-63) を更新。$idx は runtime int 可
for ($i = 0; $i < 8; $i = $i + 1) {
    nes_sprite_at($i, 32 + $i*16, 100, 0xA0);
}

// 属性を別途設定 (palette / flip / 優先度)
nes_sprite_attr(0, 0b01000001);   // bit 6=hflip, bit 0-1=palette 1
```

`nes_sprite_at($idx, $x, $y, $tile)`:
- `$idx`: 0-63 (VM 側で `& 0x3F` クランプ)。runtime int 可
- `$x` / `$y`: runtime int 可
- `$tile`: コンパイル時リテラル必須 (extended_value に literal 焼込み)
- `attr` バイトは触らない (= 既存値保持、初期値 0 = palette 0 / no flip / front)
- 初回呼び出しで sprite_mode に遷移 (rendering ON + NMI ON)

`nes_sprite_attr($idx, $attr)`:
- 両引数とも runtime int 可
- attr バイト構成: bit 0-1=palette / bit 5=priority / bit 6=hflip / bit 7=vflip
- sprite_mode は本 intrinsic 単独では起動しない (位置を設定する `nes_sprite_at` と組み合わせる前提)

### VM 側

```asm
handle_nesphp_nes_sprite:               ; nes_sprite_at
    LDA sprite_mode_on
    BNE :+
    JSR enable_sprite_mode               ; 初回のみ rendering + NMI 有効化
:
    JSR resolve_op1                      ; OP1_VAL = $idx
    JSR resolve_op2                      ; OP2_VAL = $x
    JSR resolve_result                   ; RESULT_VAL = $y (result スロット流用)
    ; extended_value から $tile literal を読む (TYPE_LONG チェック)
    ...
    LDA OP1_VAL+1
    AND #$3F                             ; 0-63 にクランプ
    ASL A
    ASL A                                ; * 4
    TAX                                  ; X = OAM offset
    LDA RESULT_VAL+1
    STA OAM_SHADOW + 0, X                ; y
    LDA TMP2
    STA OAM_SHADOW + 1, X                ; tile
    LDA OP2_VAL+1
    STA OAM_SHADOW + 3, X                ; x (attr は触らない)
    JMP advance
```

OAM シャドウ ($0200-$02FF) は次の VBlank で NMI ハンドラが `$4014` に書いて OAM DMA でハードウェアに転送する (これは sprite_mode 遷移後ずっと毎フレーム自動)。

---

## パレット / attribute 制御 (Phase 5E)

NES の PPU は 32 バイトのパレット RAM ($3F00-$3F1F) と、nametable 末尾 64 バイトの attribute table で色を管理する。nesphp は 3 つの intrinsic でこれを PHP から操作できる。

### NES パレットメモリマップ

```
$3F00: universal background color (全パレット共通の背景色)
$3F01-$3F03: BG palette 0 (色 1, 2, 3)
$3F05-$3F07: BG palette 1
$3F09-$3F0B: BG palette 2
$3F0D-$3F0F: BG palette 3
$3F11-$3F13: sprite palette 0 (= palette 4)
$3F15-$3F17: sprite palette 1 (= palette 5)
$3F19-$3F1B: sprite palette 2 (= palette 6)
$3F1D-$3F1F: sprite palette 3 (= palette 7)
```

各パレットの色 0 ($3F04, $3F08, $3F0C, $3F10, $3F14, $3F18, $3F1C) は $3F00 のミラーで、実質 universal background color と同じ。

### NES カラーコード ($00-$3F)

```
上位 2 bit = 明るさ (0=暗い, 1=普通, 2=明るい, 3=白寄り)
下位 4 bit = 色相

  $0x: 暗い        $1x: 普通        $2x: 明るい      $3x: 白寄り
  x0: 灰 (gray)    x1: 青 (blue)    x2: 紺 (indigo)   x3: 紫 (violet)
  x4: 赤紫         x5: ピンク       x6: 赤 (red)      x7: オレンジ
  x8: 黄           x9: 黄緑         xA: 緑 (green)    xB: 青緑
  xC: 水色 (cyan)  xD: 黒 (dark)    xE: 黒 (mirror)   xF: 黒 (mirror)

  よく使う色:
    $0F = 黒
    $30 = 白
    $16 = 暗い赤    $26 = 赤        $36 = 明るい赤
    $12 = 暗い青    $22 = 青        $32 = 明るい青
    $1A = 暗い緑    $2A = 緑        $3A = 明るい緑
    $21 = 水色      $28 = 黄
```

### `nes_bg_color($c)` — 背景色設定

PPU $3F00 (universal background color) を NES カラーコードで設定する。全パレット共通の背景色 (色 0) が変わる。

```php
nes_bg_color(0x0F);  // 黒背景 (デフォルト)
nes_bg_color(0x02);  // 暗い紺背景
```

forced_blanking 中は PPU に直書き、sprite_mode 中は NMI キュー経由。

### `nes_palette($id, $c1, $c2, $c3)` — パレット色設定

パレットの色 1-3 を設定する。nesphp 初の 4 引数 intrinsic で、zend_op の op1/op2/result/extended_value を全て入力として使用する。

```php
nes_palette(0, 0x30, 0x16, 0x26);  // BG palette 0: 白, 暗い赤, 赤
nes_palette(1, 0x30, 0x2A, 0x1A);  // BG palette 1: 白, 緑, 暗い緑
nes_palette(4, 0x30, 0x16, 0x00);  // sprite palette 0: 白, 暗い赤, 灰
```

id 0-3 が BG パレット、4-7 が sprite パレット。PPU の $3F01+id*4 から 3 バイトを書く。

### `nes_attr($x, $y, $pal)` — attribute table 設定

BG の attribute table で、2×2 タイル (16×16 ピクセル) のブロック単位にパレット番号 (0-3) を割り当てる。

```php
nes_attr(0, 0, 1);   // 左上 16×16 px ブロックに BG palette 1 を割当
nes_attr(2, 3, 2);   // x=2, y=3 の 16×16 px ブロックに BG palette 2 を割当
```

x は 0-15 (32 タイル / 2)、y は 0-14 (30 タイル / 2、端数切り捨て)。

### Attribute table の仕組み

NES の attribute table は nametable 末尾の 64 バイト ($23C0-$23FF) にあり、4×4 タイル (32×32 ピクセル) を 1 バイトで管理する。1 バイト内の 2bit ずつが 2×2 タイル (16×16 px) サブブロックのパレット番号を指定:

```
1 byte = [TL:2][TR:2][BL:2][BR:2]
  bit 1-0: 左上 2×2 タイル
  bit 3-2: 右上 2×2 タイル
  bit 5-4: 左下 2×2 タイル
  bit 7-6: 右下 2×2 タイル
```

### RAM shadow (ATTR_SHADOW = $0608, 64 バイト)

attribute table は 1 バイトに 4 つのサブブロック情報が詰まっているため、個別のサブブロックだけを書き換えるには read-modify-write が必要。しかし PPU VRAM は読み出しに 1 cycle のバッファ遅延があり直接 RMW が困難。

nesphp は RAM 上に 64 バイトの shadow ($0608-$0647) を保持し:

1. `nes_attr` 呼び出しで shadow のバイトを read-modify-write (2bit だけ差し替え)
2. 変更後の shadow 全体を PPU $23C0-$23FF に書き出す

これにより任意の 16×16 px ブロック単位で安全にパレットを変更できる。

### 3 つの intrinsic の組み合わせ例

```php
// 黒背景に設定
nes_bg_color(0x0F);

// BG palette 0: 白文字 (タイトル用)
nes_palette(0, 0x30, 0x10, 0x00);
// BG palette 1: 赤文字 (強調用)
nes_palette(1, 0x26, 0x16, 0x06);
// BG palette 2: 緑文字 (本文用)
nes_palette(2, 0x2A, 0x1A, 0x0A);

// 行ごとにパレットを割り当て
for ($x = 0; $x < 16; $x++) {
    nes_attr($x, 0, 0);  // row 0-1: palette 0 (白)
    nes_attr($x, 1, 1);  // row 2-3: palette 1 (赤)
    nes_attr($x, 2, 2);  // row 4-5: palette 2 (緑)
}

nes_puts(2, 0, "WHITE TITLE");
nes_puts(2, 2, "RED HIGHLIGHT");
nes_puts(2, 4, "GREEN BODY");
```

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
