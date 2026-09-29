# 14. スクロールするマップ、実行時タイルの sprite、街デモ

[← README](./README.md) | [← 13-compiler](./13-compiler.md)

`examples/town.php` (歩き回れるドラクエ風の街) のために追加した VM 機能と、その
設計を決めた制約をまとめる。数値はすべて on-NES コンパイラ (L3S) で実測したもの。

## 追加した intrinsic

| intrinsic | opcode | 引数 | 内容 |
|---|---|---|---|
| `nes_scroll($x, $y)` | 0xE7 | どちらも runtime | BG スクロール。`$x` 0-511 (bit 8 = 右の nametable)、`$y` 0-239 (nametable は 30 行 = 240px で wrap)。forced blanking では shadow を直接更新、sprite_mode では NMI キューに scroll エントリを積むので、その前に積んだ nametable 書き込みと同じ VBlank で反映される |
| `nes_sprite_tile($idx, $tile)` | 0xE6 | どちらも runtime | `OAM[$idx*4+1] = $tile`。`nes_sprite_at` の tile はリテラル限定なので、向きや NPC 種類で変わるときはこちらで差し替える (分岐 1 つ分の op を節約できる) |
| `nes_map_cfg($mw, $mode)` | 0xE5 | どちらも runtime | マップ幅 (メタタイル数) と `nes_map_rect` の描画モード (bit 0-1: 0 = 2x2 全部 / 1 = 上段タイル行のみ / 2 = 下段のみ、bit 2 = attr を書かない)。bank 3 の offset 4080 (`MAP_PALTAB_EXT`) から種類→パレット表 16 byte も RAM に取り込む |
| `nes_rom_copy($dst, $src, $len)` | 0xE3 | すべて runtime | PRG-ROM bank 2 (`GAMEDATA` segment = `build/data.bin`、example ごとの `examples/NAME.data.bin`) の offset `$src` から `$len` byte を PRG-RAM bank 3 の `$dst` へコピー。起動時に 1 回、マップ / オブジェクト / メッセージを展開する (8KB ≈ 0.15 秒) |
| `nes_chr_copy($tile, $src, $n)` | 0xE2 | すべて runtime | PRG-ROM bank 2 の offset `$src` から 16 byte タイル × `$n` を CHR-RAM の BG タイル `$tile` 以降へコピー。sprite_mode では nes_cls と同じ一時ブランキング (1 フレーム黒)。日本語グリフはこれでパターンテーブルに載せる |
| `nes_obj_draw($cpx, $cpy, $n)` | 0xE0 | すべて runtime | bank 3 の offset 4096 にあるオブジェクトレコード (5 byte: `x, y, type, msg, pal`) `$n` 個を、カメラ px `($cpx, $cpy)` 基準の 16×16 sprite として OAM slot 4+4i に配置。画面外と宝箱 (`type = 0xFF`) は隠す。`$n` の上位 byte (0 以外) は画面 y のしきい値で、それ以上の sprite も隠す (街はメッセージ窓を開くとき `$NPC_N + 145*256` を渡し、窓に重なる sprite だけ消す)。PHP のループ (NPC 1 体 ≈30 op) の置き換え |
| `$r = nes_obj_at($x, $y)` | 0xDF | 式 | マス `(x, y)` にオブジェクトがなければ 0、あれば `1 + msg`。個数は直近の `nes_obj_draw` のもの。レコードの `pal` byte は bit 0-1 = 上 2 枚 (頭)、bit 2-3 = 下 2 枚 (体) の sprite パレットで、1 体で 4 色使える (金髪 + 桃色の服)。街では目の前のマスを調べ、そこが COUNTER で誰もいなければさらに 1 マス先も調べる (カウンター越しの会話) |
| `nes_cam_move($dx, $dy, $frames)` | 0xE1 | すべて runtime | カメラ補間を開始: NMI が毎フレーム scroll に `(dx, dy)` を足し、世界に固定された sprite (slot 4-63) からは引く。`$frames` フレーム続け、画面外に出た sprite は隠す。`$frames` の bit 8 = 「勇者モード」(scroll ではなく slot 0-3 を `(dx, dy)` 動かす。カメラがマップ端で止まっているとき)。前の補間を待ってから設定し、すぐ戻るので、画面が動いている間に PHP が次の歩きを判定できる |
| `nes_cam_wait()` | 0xDE | なし | 進行中の補間が終わるまで待つ |
| `nes_map_rect($mx, $my, $w, $h)` | 0xE4 | `$h` は **CV 変数限定** | PRG-RAM bank 3 のマップ (1 byte/マス、`my * mw + mx`) からメタタイル矩形を nametable に描く。マス byte の下位 5 bit = 種類 `t` → CHR `0x88 + t*4` (TL, TR, BL, BR)、bit 5 はゲームが自由に使う (街では通行可)。nametable 列 = `(mx*2) & 63`、行 = `(my % 15) * 2`、attr ブロック `(mx & 31, my % 15)`、パレット `PALTAB[t]`。4 引数目は型情報のない `extended_value` で渡すのでコンパイラが CV に限定する |

`nes_put` / `nes_puts` / `nes_attr` は x 0-63 (attr はブロック x 0-31) を受け付ける。
列 32-63 は nametable 1 (`$2400` / `$27C0`)。`nes_puts` は列 63 をまたぐ文字列を隣の
nametable の同じ行に続けて書くので、スクロール中でもメッセージ窓の 1 行を 1 回で
書ける。attribute shadow は 128 byte (`$0608-$0687`、nametable ごとに 64) に拡張。

MMC1 は **vertical mirroring** (control `$1E`、bit 1-0 = `10`): nametable 0/1 が横に
並ぶので横スクロールは継ぎ目なし、縦は 1 枚の中で 240px wrap。

## 街のスクロール方式 (ファミコンの定石を NMI で滑らかに)

- 表示窓は 16×15 メタタイル。カメラ (`cx`, `cy`) は勇者を中央に保ち、端でクランプ。
  1 歩 = 8px の半歩 2 回。各半歩は `nes_cam_move(dx*2, dy*2, 4)` の補間 (2px/フレーム、
  1 歩 8 フレーム = ドラクエの歩調) で、NMI が全部やるので VM の速度に依存しない。
  勇者の歩行フレームは半歩ごとに `nes_sprite_tile` で切り替える。
- **横**: 入ってくる列は隣の nametable (画面外) にあるので、補間を始める前に列ごと
  (`nes_map_rect` で `w = 1, h = 15`) 描く。歩いている間に *次の* 列を先読みする
  (まだ隠れている) ので、連続歩行では待ちなし。向きを変えたときだけ列を書いてキューが
  流れる 2 フレームを待つ。
- **縦**: 隠れた行がない (30 行 = 画面全体) ので、各半歩で「今、上下 8px の
  オーバースキャン帯 (TV や fceux の 224 行表示では見えない) にあるタイル行」だけを
  描く。nametable の行は上の帯から (240px の wrap で) 下の帯へ回るので、半歩の頭で
  書いた行は補間の最初の 4 フレームは隠れたまま → 待ちは不要。行の選択は
  `nes_map_cfg` のモード 1/2、attr は 2 枚目と一緒に書く。下へ: 入ってくる行の上段を
  描く → 8px 補間 → 下段 + attr を描く → 8px 補間。
- 後半の補間は次の歩きの入力判定より先に始めるので、VM の入力/当たり判定 (約 30ms) は
  画面が動いている間に終わる。実測: 横 1 歩 9 フレーム、縦 1 歩 10 フレーム (2px/フレーム)。
- `nes_map_rect` はタイル行を 1 エントリ (最大 32 byte、nametable 境界で分割)、タイル列を
  縦増分フラグ付きの 1 エントリ (キューエントリのアドレス上位 byte の bit 7 で NMI が
  PPUCTRL の増分を +32 にする) で積むので、1 行が 1 VBlank で流れる。
- NPC は DQ1 風に 2 コマで足踏みする (PHP の op は 0)。NMI (`nmi_obj_anim`) が 24 フレーム
  (`ANIM_PERIOD`、約 0.4 秒) ごとに `ANIM_PHASE` を反転し、OAM slot 4-63 のタイル番号に `$20` を足し引きする。
  そのため各 NPC の 2 コマ目は sprite pattern set 1 の 1 コマ目 + `$20` に置く
  (1 コマ目 `$90 + type*4`、2 コマ目 `$B0-$C7`)。`nes_obj_draw` は配置時に `ANIM_PHASE`
  を見るので再描画しても位相が続く。`OAM_BUSY` 中と、まだ `nes_obj_draw` を呼んでいない
  (`OBJ_COUNT = 0`) プログラムでは何もしない。勇者はプログラム側で動かす: 半歩ごとに
  `$f` を反転し、`$80/$A8` (正面)、`$84/$AC` (後ろ)、`$88/$8C` (横、左右反転) を選ぶ。

## NMI キューの flush 予算

`flush_nmi_queue` はエントリ 1 本を **6 単位 + データ 1 byte 1 単位** (固定処理 ≈90 cycle、
1 byte 15 cycle) と数え、1 VBlank の予算 90 単位 (≈1350 cycle) に対して、エントリを
処理する**前**にコストを見て足りなければ次フレームへ回す (処理後に引く方式だと最後の
1 本が VBlank をはみ出す)。OAM DMA (513 cycle) + レジスタ退避 + `apply_scroll` で
2273 cycle のうち約 620 を使う。VBlank をはみ出した PPUDATA 書き込みは、描画が PPU の
`v` レジスタを書き換えるため無関係な場所を壊す (街の開発中に 3 回踏んだ: 33 byte の
文字列エントリ 3 本、210 byte の列、1 byte の attr 15 本 + 20 byte の列)。

`nes_pokestr_ext` の中継バッファは `$0600` から TMP page (`$0500-$05FF`) に移した
(`$0600` には `INT_PRINT_BUFFER` / attribute shadow / `MAP_PALTAB` がある)。

## ゲームデータ: `examples/town.data.bin` (PRG-ROM bank 2)

まとまったデータは PHP を通さない。配列は 1 要素 1 op (32×28 のマップで 896 op)、
文字列エスケープは 1 byte に 4 文字のソースを食うため。代わりにエクスポータがバイナリを
出し、Makefile が PRG-ROM bank 2 (`GAMEDATA` segment) に焼く (`.data.bin` のない example
は空 segment)。`town_map.php` はマップサイズ / 開始位置 / オブジェクト数と、起動時に先頭
8KB を PRG-RAM bank 3 へ展開する `nes_rom_copy(0, 0, 8192)` だけになる:

| bank 3 offset | 内容 |
|---|---|
| 0 .. | マップ 1 byte/メタタイル: `0x40 + 種類`、通行可なら `0x60 + 種類` (bit 5)。最大 4080 byte |
| 4080 | `PALTAB`: 種類 → BG パレット 16 byte (`nes_map_cfg` が読む) |
| 4096 .. | オブジェクトレコード 5 byte: `x, y, type, msg, pal`。`type = 0xFF` は宝箱 (sprite なし、A でメッセージ) |
| 4864 .. | メッセージ 1 件 84 byte: `[グリフ ROM offset lo, hi][グリフ数][予備]` + 3 行 × 26 byte の **タイル番号列**、0 終端 (最大 25 文字) |

| ROM bank 2 offset | 内容 |
|---|---|
| 8192 .. | グリフのビットマップ 16 byte/タイル (bitplane 0 = 字形、bitplane 1 = 0)、メッセージごとにまとめて配置。最大 512 グリフ |

### 日本語 (漢字込み) のメッセージ

メッセージ本文はタイル番号の列。ASCII 0x20-0x7E は常駐フォント。それ以外の文字は BDF
(misaki 8×8、Unicode エンコーディング: `chr-edit/misaki_bdf_2021-05-05/misaki_gothic.bdf`)
から字形を引き、メッセージ内で重複を除いて **グリフスロット** `0xC0 + i` (56 スロット =
タイル 0xC0-0xF7。3 行 × 25 文字で異なり字が 56 を超えることは稀) を割り当てる。窓を開くときエンジンがメッセージ
ヘッダを読み `nes_chr_copy(0xC0, offset, count)` を 1 回呼ぶので、CHR-RAM にはそのメッセージ
の字形だけが載る。街全体の会話で使える漢字の種類に上限はなく、制約は 1 行 25 文字と ROM の
グリフ 512 タイル (8KB) だけ。全角スペースは半角スペースに、BDF にない文字は警告付きで `?`
になる。

## マップエディタ

`map-edit/index.html` は単体で動くエディタ (`chr-edit` と同じ流儀)。メタタイルを
塗り、NPC / 宝箱 / 勇者を置き、各オブジェクトのメッセージ (BDF を読ませれば日本語可) を
書いて「出力」→ `town_map.php` と `town.data.bin` の両方を `examples/` に保存する。
`map-edit/export.js` が出力器と BDF パーサで、node からも使える:

```
node map-edit/gen.js map-edit/town.json examples/town_map.php examples/town.data.bin \
     chr-edit/misaki_bdf_2021-05-05/misaki_gothic.bdf
```

`chr/font.chr` を読み込むと実タイルで表示される。モデル / CHR / BDF は localStorage に
保存され、モデルは JSON で保存/読込できる (`map-edit/town.json` がサンプルの街)。
エンジンが op 節約のため境界チェックを省いているので、外周に通行可タイルがあると出力を
拒否する。

`tools/pack_src.php` は `require 'file.php';` (include 元からの相対パス) をインライン
展開し、`//` コメントとインデントを削る (行番号は保つ)。16KB のソース上限をコードに
使うため。`Makefile` は `build/town.src.bin` の依存に `examples/town_map.php` を足してある。

## op 数の実測 (on-NES コンパイラ)

op_array の容量は **617 op** (`$6010-$7CFF`、1 op 12 byte。`$7D00-$7FFF` はリテラルの
staging)。`town.php` は約 530 op。文ごとの実測:

| 文 | op |
|---|---|
| `$a = 1;` / `$a = $b;` | 1 |
| `$a = $b + $c;` (演算子 1 個ごとに +1) | 2 |
| `f($a + 1, $b, $c + 2);` (呼び出し + 式引数 1 個ごとに +1) | 3 |
| `if (cond) { ... }` | 2 + 本体 |
| `while (cond) { ... }` | 3 + 本体 |
| `$x = nes_peek_ext($o + 2);` | 3 |
| **`&&` / `\|\|` 1 個** | **約 5** |
| 配列リテラル | 1 + 要素数 |

街を書いていて踏んだコンパイラの癖: `elseif` は 1 段ごとにネストを 2 段消費する
(3 つ目の `elseif` で 7 段上限に当たる → 状態変数 + 平坦な `if` にする)。式の先頭が
括弧の部分式で、その後に演算子が続く形 (`($a + 1) & 63`) は受け付けず、
`63 & ($a + 1)` なら通る。`$t = f() - 1` のような呼び出し + 演算は 2 文に分ける。
VM の実行速度は約 2,950 op/秒 (1 op ≈ 0.34 ms)。

## ROM 構成: 128KB と RUNTIME bank

固定コード bank (`$C000` の 16KB) が一杯になったので、ROM は 8 × 16KB (iNES の PRG 数 8):
bank 0 PHPSRC、1 CHRDATA、2 GAMEDATA、**3 RUNTIME**、4-6 空き、7 CODE (固定)。PRG-ROM
bank 0 はコンパイル中しか要らないので、`compile_and_emit` の後に reset コードが bank 3 を
`$8000` にマップし、実行時専用の大きい handler (`nes_map_rect` / `nes_obj_draw` /
`nes_obj_at`) はそこの `RUNTIME` segment に置く。bank 1/2 を一時的にマップする handler
(`chr_bulk_transfer` / `nes_rom_copy` / `nes_chr_copy`) は終わりに `PRG_RUNTIME_BANK` を
戻し、固定 bank に置く。NMI から呼ぶものも固定 bank。

## 関連ドキュメント

- [04-opcode-mapping](./04-opcode-mapping.md) — opcode 番号
- [06-display-io](./06-display-io.md) — PPU 状態遷移、NMI キュー
- [11-chr-banks](./11-chr-banks.md) — タイル番号 (街メタタイル 0x88〜、窓枠 0xF8〜)
- [13-compiler](./13-compiler.md) — 文法と制約
