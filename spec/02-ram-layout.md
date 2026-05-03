# 02. RAM レイアウトと 4B tagged value

[← README](./README.md) | [← 01-rom-format](./01-rom-format.md) | [→ 03-vm-dispatch](./03-vm-dispatch.md)

ROM 側は Zend 互換 16B zval を守る ([01-rom-format](./01-rom-format.md)) が、**RAM 側は 4B に縮退**する。2KB RAM でヒープなしの制約を守るため。

## 方針

- ROM: Zend 互換 16B zval (faithful)
- RAM: 4B tagged value (縮退、ただし type ID は Zend 互換)
- 動的アロケーションは一切しない。全スロットは固定オフセットで決め打ち
- VM は ROM から 16B zval を fetch → その場で 4B tagged に narrow → スタックに push

## WRAM マップ ($0000-$07FF, 2KB)

```
$0000-$007F  ゼロページ: VM レジスタ (PC/SP/LITBASE/CVBASE/TMP 等)
             + L3S コンパイラ作業領域 (CMP_* 群、コンパイル中のみ生存)
$0080-$00FF  ゼロページ: コントローラ状態, NMI 作業変数, 一時 TMP
$0100-$01FF  6502 ハードウェアスタック (256B)
$0200-$02FF  OAM シャドウ (256B, 延長ゴール用。MVP では未使用)
$0300-$03FF  VM データスタック (4B × 64 エントリ = 256B)
$0400-$04FF  CV スロット (4B × 最大 64 エントリ = 256B)
$0500-$05FF  TMP スロット (4B × 最大 64 エントリ = 256B)
$0600-$06FF  テキスト行バッファ / CONCAT 作業領域
             (コンパイル中は print_int16 出力先、エラー表示で使用)
$0700-$07FF  L3S 時: CV シンボル表 (4B × 最大 64 = 256B)
             runtime: USER_RAM (peek/poke 用 256B 汎用バイト領域)
```

L3S (on-NES コンパイラ) は電源 ON 直後の一瞬だけ走り、その後 VM runtime が起動する。コンパイル中と runtime では **WRAM を時間的に分離して共用**する。詳細は [13-compiler](./13-compiler.md)「WRAM 共用契約」を参照。

### 2KB 利用合計

- MVP ではスタック・CV・TMP すべてフルに使う必要はない。`examples/hello.php` は **VM データスタック 1 段、CV/TMP 0 個**で動く
- 延長ゴール (`while ($i < 10) { ... }`) で CV 1-2 個、TMP 2-4 個、VM stack 2-3 段程度
- 64 段 VM スタック + 32 CV + 64 TMP で合計 640B、RAM 予算の 30%

---

## ゼロページ VM レジスタ (実装済み)

ゼロページに置くと `LDA (zp),Y` の間接アドレッシングと `LDX zp` の即値が使えて、6502 で最速。ca65 `.segment "ZEROPAGE"` で `.res` 宣言し、ld65 が自動配置する。現在の配置:

| label | サイズ | 用途 |
|---|---|---|
| `VM_PC` | 2 | 現在の zend_op の ROM アドレス (fetch 元) |
| `VM_LITBASE` | 2 | literals 配列の ROM アドレス (= OPS_BASE + literals_off) |
| `VM_CVBASE` | 2 | CV スロット配列の RAM アドレス (= $0400) |
| `VM_TMPBASE` | 2 | TMP スロット配列の RAM アドレス (= $0500) |
| `PPU_CURSOR` | 2 | nametable 書き込み位置 ($2000 ベースの絶対 PPU アドレス) |
| `OP1_VAL` | 4 | resolve_op1 が書き込む 4B tagged value |
| `OP2_VAL` | 4 | resolve_op2 が書き込む 4B tagged value |
| `RESULT_VAL` | 4 | handler が write_result で書き戻す 4B tagged value |
| `TMP0` | 2 | 汎用 16bit 作業レジスタ |
| `TMP1` | 2 | 汎用 16bit 作業レジスタ |
| `TMP2` | 2 | 汎用 16bit 作業レジスタ |
| `DIV_COUNTER` | 1 | (予約、未使用) |
| `buttons` | 1 | コントローラ状態 (bit 7=A, 6=B, ..., 0=R) |
| `pi_count` | 1 | `print_int16` が出力したバイト数 (echo_long で PPU_CURSOR 更新に使用) |
| `sprite_mode_on` | 1 | `0 = forced_blanking` / `1 = sprite_mode` の状態フラグ |

合計 ~34 バイト。ZP 予算 256B のうち 13% 程度しか使っていないので、今後も余裕あり。

---

## 4B tagged value の仕様

```
byte 0: type ID    (Zend 互換)
byte 1: payload lo
byte 2: payload hi
byte 3: payload ext (type により意味が変わる、下表)
```

### type ID (Zend `zend_types.h` と互換)

| 値 | 名前 | byte 1-2 の意味 | byte 3 の意味 |
|----|------|----------------|----------------|
| 0 | IS_UNDEF | 0 | 0 |
| 1 | IS_NULL | 0 | 0 |
| 2 | IS_FALSE | 0 | 0 |
| 3 | IS_TRUE | 0 | 0 |
| 4 | IS_LONG | **16bit 符号付き整数** | 0 (将来符号拡張用) |
| 5 | IS_DOUBLE | **未対応** | — |
| 6 | IS_STRING | val[] への 16bit OPS_BASE 相対 offset | **L3S では文字列長 (下位 1B)**、L3 では 0 |
| 7 | IS_ARRAY | **未対応** | — |
| 8 | IS_OBJECT | **未対応** | — |

**L3 (host serializer 経路)**: IS_STRING の byte 1-2 は ROM 内 `zend_string` 構造体への offset。length は `zend_string` の offset 16 から読む。byte 3 は未使用 (0)。

**L3S (on-NES コンパイラ経路、spec/13-compiler.md)**: IS_STRING の byte 1-2 は ROM 内 val[] (生バイト列) への offset。length は byte 3 に格納 (255B 上限)。zend_string 構造体は持たない。

### narrow のルール

| ROM 側 (16B zval) | RAM 側 (4B tagged) |
|---|---|
| `IS_LONG` (8B lval) 範囲 -32768..32767 | そのまま 16bit に |
| `IS_LONG` 範囲外 | serializer で compile error (実行時には発生しない) |
| `IS_STRING` value 下位 2B | byte 1-2 にコピー (ROM offset) |
| `IS_STRING` value offset 2 (L3S のみ) | byte 3 にコピー (length) |
| `IS_TRUE/FALSE/NULL` | type ID だけコピー、payload 0 |

### narrow は誰がやるか

**VM 側のハンドラ** (`resolve_op1` / `resolve_op2`) がフェッチ時に narrow する。コンパイラ (host の serializer または NES の compiler) は ROM に Zend 互換の 16B zval を書くだけで、narrow を事前に行わない。これは「ROM は Zend のレイアウトそのまま」という L3 方針の帰結。

---

## データスタック ($0300-$03FF)

4B tagged value × 64 段 = 256B。VM_SP は `$0300` を底、`$03FF+1` を満杯として下向きに伸ばす (または上向きでもよい、要決定)。

**推奨**: 上向きに伸ばす。`push` = `STA ($02),Y : INY ×4`。底は `$0300`、満杯は `$0400`。

### push/pop マクロ

```asm
; push A/X/Y (型/lo/hi) into VM stack
.macro PUSH_LXH
    LDY #0
    STA (VM_SP),Y       ; type
    INY
    TXA
    STA (VM_SP),Y       ; lo
    INY
    TYA                 ; (reuse A)
    STA (VM_SP),Y       ; hi
    INY
    LDA #0
    STA (VM_SP),Y       ; ext
    LDA VM_SP
    CLC
    ADC #4
    STA VM_SP
    BCC :+
    INC VM_SP+1
:
.endmacro
```

(疑似コード、実際の実装は [03-vm-dispatch](./03-vm-dispatch.md) と合わせて調整)

---

## CV スロットと TMP スロット

- **CV** (`$0400-$04FF`): Zend の「コンパイル済みローカル変数」。PHP の `$a`, `$b` 等がスロット番号に割り当てられる。serializer は op_array header の `num_cvs` を出力、VM はそれを超えるスロット番号を検出したら panic
- **TMP** (`$0500-$05FF`): Zend の `IS_TMP_VAR` / `IS_VAR`。短寿命の中間値

### アクセス

```
CV slot n  →  $0400 + n*4  
TMP slot n →  $0500 + n*4  
```

どちらも 4B tagged value 1 個分。最大スロット数 64 (= 256B / 4)。

### スロット解決の 16-bit 化 (重要)

zend_op の `op.var` フィールドには **`slot * 16`** が 16-bit で入る (Zend 流)。
VM 側はこれを `/4` して `slot * 4` (RAM オフセット) を計算する。

**slot ≥ 16** のとき `slot*16 ≥ 256` となり下位 1 byte だけでは表現できないため、
解決は必ず 16-bit で行う。`vm/nesphp.s` の `cv_addr_y` / `tmp_addr_y` ヘルパーがこの計算を集約しており、
res_cv / res_tmp / wr_cv / wr_tmp / assign_to_cv / incdec_cv_addr すべてここを通る。

---

## USER_RAM ($0700-$07FF, 256B、runtime のみ)

L3S コンパイル完了後、CV シンボル表は不要になるため、同領域 256B を **peek/poke 用の汎用バイト領域**として再利用する。

| 用途 | 例 |
|---|---|
| 大きな定数テーブル | Tetris の 28 回転 shape table を 56 byte string で `nes_pokestr(0, $data)` で bulk load |
| ゲーム状態の生バイト保存 | `nes_poke(64, $byte)` / `$x = nes_peek(64)` |
| 16-bit テーブル | `nes_peek16($ofs)` で little-endian 2 byte 復元 |

**設計理由**: 配列 (`$a = [...]`) は 1 要素あたり 16 byte の zval オーバーヘッドがあるため、
バイト単位の大量データ (例: 56 byte の 28 entry shape table) では 7 倍のメモリを食う。
USER_RAM はオーバーヘッドゼロでバイトアクセスできる。

詳細は [04-opcode-mapping § peek/poke](./04-opcode-mapping.md) と [13-compiler](./13-compiler.md) を参照。

---

## PRG-RAM ($6000-$7FFF、SXROM 4 bank × 8KB = 32KB)

カートリッジ側 PRG-RAM 32KB を 8KB 窓 ($6000-$7FFF) に bank 切替で出し分ける。
MMC1 の `$A000` レジスタ bit 2-3 が PRG-RAM bank select (CHR-RAM 環境では bit 0-1
は no-op)。`cur_prg_ram_bank` ZP byte で現状を追跡。

### 各 bank の用途

| bank | 用途 | 切替タイミング |
|---|---|---|
| **0** (デフォルト) | header + op_array + literals + STR_POOL | dispatch loop の常時マップ |
| **1** | ARR_POOL 8KB (配列専用) | 配列 handler の入口/出口で atomic 切替 |
| **2** | USER_RAM_EXT 8KB (peek/poke_ext 用) | `nes_*_ext` intrinsic 内で atomic 切替 |
| **3** | 予約 | 将来の拡張 |

### bank 0 内訳 (現行 8KB レイアウト)

```
$6000-$600F  header (16 B)
$6010-...    op_array (24B × 命令数、最大 ~308 op)
...-$7CFF    literals (op_array の直後に memcpy、~40 zval × 16B)
$7D00-$7F7F  CMP_LIT_STAGE (640 B、コンパイル中のみ。post-compile は free)
$7F80-$7FFF  STR_POOL (128 B、文字列 pool)
```

ARR_POOL が bank 1 に移ったため、旧 ARR_POOL 領域 ($7000-$7CFF) は post-compile
で完全に free。将来 op_array 拡張に転用可。

### bank 1 (ARR_POOL 専用)

```
$6000-$7FFF  ARR_POOL (8 KB、追記型成長、GC なし)
```

旧 720B (bank 0 内に分割共有) → 8 KB (専有) で **約 11 倍** に拡大。tetris の
全面再描画など、配列が増える用途のメモリ圧を解消。

### bank 2 (USER_RAM_EXT)

```
$6000-$7FFF  USER_RAM_EXT (8 KB、汎用 byte 領域)
```

`nes_peek_ext` / `nes_peek16_ext` / `nes_poke_ext` / `nes_pokestr_ext` で読み書き。
13-bit offset (0-8191)、内蔵 RAM の `nes_peek/poke` (256B) より遥かに大容量。

### bank 切替コスト

MMC1 シリアル書込は 5 STA + 4 LSR = ~30 cycles。bank 1/2 への入出口で 2 回切替
= **約 60 cycles オーバーヘッド** per intrinsic 呼出。配列 50 回/フレーム の
tetris で約 10% スローダウン (許容範囲)。

詳細は [13-compiler § PRG-RAM bank 構成](./13-compiler.md) と
[04-opcode-mapping § ext intrinsic](./04-opcode-mapping.md)。

---

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — ROM 側の 16B zval レイアウト
- [03-vm-dispatch](./03-vm-dispatch.md) — operand resolver がこのレイアウトをどう読むか
- [04-opcode-mapping](./04-opcode-mapping.md) — 各 opcode で使うスロット数
