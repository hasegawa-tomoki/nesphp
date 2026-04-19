# nesphp

PHP ソースをファミコン (6502) にそのまま持ち込み、**NES 自身がコンパイルして実行する** PHP VM。実用ではなくロマン重視。

- **L3S (self-hosted)**: PHP ソースを ROM に生のまま焼き、電源 ON で 6502 が lex/parse/codegen → Zend 互換の `zend_op 24B` / `zval 16B` を PRG-RAM に emit → 既存 VM で実行
- **L3 (host-compile) も並存**: `serializer.php` が出した L3 ROM バイナリをオラクルとして検証可能
- **マッパー**: MMC1 (mapper 1, SNROM 構成)、PRG 32KB + CHR 32KB (4KB × 8 bank) + WRAM 8KB
- **動作確認**: PHP 8.4 (version lock) + cc65 + fceux/Mesen

詳細な設計は [`spec/`](./spec/) ディレクトリ (目次は [`spec/README.md`](./spec/README.md))。**「PHP 構文の知識は NES 側にだけ存在する」**ことがロマンの核。

---

## クイックスタート

```bash
# 依存: PHP 8.4, cc65 (brew install cc65), fceux (brew install fceux)
make                      # デフォルト: build/hello.nes
make build/poll.nes       # 任意の examples/NAME.php → build/NAME.nes
make run:hello            # ビルド + fceux で実行
make run:poll             # 任意の example を指定して実行
make clean
```

`make run:NAME` で **ビルドからエミュレータ起動まで 1 コマンド**で完結します。エミュレータを変えたい場合は `make run:hello EMULATOR=other_emu`。

### ビルドパイプライン (L3S: 既定)

```
[ホスト]
  examples/foo.php
      │
      ▼  tools/pack_src.php  (u16 length を前置するだけ、~15 行)
  build/foo.src.bin
      │
      ▼  ca65 + ld65  (.segment "PHPSRC" に .incbin)
  build/foo.nes
      │
      ▼  電源 ON (NES 側)
  reset → compile_and_emit (vm/compiler.s)
        │  lex → parse → emit 24B zend_op / 16B zval
        ▼
  PRG-RAM $6000-$7FFF に op_array 完成 → main_loop で実行
```

ホスト側でやっているのは「ASCII チェック + 長さ前置」だけ。`<?php` タグも文字列リテラルも ROM にそのまま残り、**NES 側の `vm/compiler.s` が唯一の PHP パーサ**。

L3 (host-compile) オラクルは `make build/foo.host.ops.bin` で取得可能 (L3S の出力を Zend 原本と突き合わせるとき用)。詳細: [`spec/05-toolchain.md`](./spec/05-toolchain.md) と [`spec/13-compiler.md`](./spec/13-compiler.md)。

---

## PHP で書けること

### サポートされている PHP サブセット

| カテゴリ | 対応 |
|---|---|
| 整数リテラル | 10 進 / 16 進 `0x..` / 2 進 `0b..`、16bit 符号付き narrow (`-32768..32767`) |
| 文字列 | **ROM 内イミュータブル**のみ (リテラル)。連結 (`.`) は未対応、non-ASCII byte は pass through |
| 変数 | CV / TMP / VAR スロット、`$a = ...` / `$a = $b + 1` |
| 算術 | `+` / `-` |
| ビット | `&` / `\|` / `<<` / `>>` (16bit、`>>` は算術右シフト) |
| 論理 | `&&` / `\|\|` (短絡評価、結果は 0 or 1 の IS_LONG) |
| 比較 | `===` / `!==` / `==` / `!=` / `<` (`===` と `==` は同じ実装) |
| インクリメント | `$x++` / `$x--` / `++$x` / `--$x` (stmt / expr 両方) |
| 制御 | `if` / `while` / `while(true)` / `for (init; cond; upd)`、単文 body 可 |
| コメント | `//` / `#` / `/* */` (non-ASCII OK) |
| 出力 | `echo` (forced_blanking 中 or sprite_mode の NMI 同期キュー経由で透過的に動く) |
| 入力 (旧 API) | `fgets(STDIN)` → 押されたボタン 1 文字の文字列 (blocking) |
| 入力 (新 API) | `nes_btn()` (0 引数、現在状態を bitmask で返す) + `nes_vsync()` |
| 関数 | **intrinsic のみ** (下表)、ユーザ定義関数は未対応 |

文法 EBNF と全トークン一覧は [`spec/13-compiler.md`](./spec/13-compiler.md)。

### できないこと (明示的に諦めたもの)

配列 / オブジェクト / 例外 / generator / closure / double / 64bit int / 文字列連結 / 動的文字列生成 / ユーザ定義関数 / `else` / `elseif` / `<=` / `>` / `>=` / 単項 `-` / `!` / `^` (BW_XOR)。 詳細は [`spec/00-overview.md`](./spec/00-overview.md) の「やらないこと」と [`spec/13-compiler.md`](./spec/13-compiler.md) の制約節。

---

## Intrinsic 一覧

NES 側コンパイラが関数名を見て専用 custom opcode に畳み込みます (`INIT_FCALL + SEND_* + DO_*` シーケンスを単一命令化)。

| 関数 | 引数 | 説明 | opcode |
|---|---|---|---|
| `echo $v` | IS_STRING / IS_LONG | nametable の現在カーソル位置に出力 | `ZEND_ECHO` 0x28 |
| `fgets(STDIN)` | — | コントローラの 1 ボタン押下を 1 文字の文字列で返す (`"A"/"B"/"S"/"T"/"U"/"D"/"L"/"R"`)、blocking | 0xF0 |
| `nes_put($x, $y, "c")` | int, int, char リテラル | nametable (x, y) に 1 文字 | 0xF1 |
| `nes_puts($x, $y, "str")` | int, int, 文字列リテラル | nametable (x, y) から文字列を書く (行折り返しなし、len ≤255) | 0xF3 |
| `nes_cls()` | — | nametable 0 全域 ($2000-$23FF) をスペースで埋めカーソル既定位置へ | 0xF4 |
| `nes_sprite($x, $y, $tile)` | int, int, int | sprite 0 の OAM shadow 更新 (初回呼び出しで rendering + NMI を有効化) | 0xF2 |
| `nes_chr_bg($n)` | int リテラル 0-7 | BG 用 4KB CHR bank を切替 (MMC1 CHR bank 0, $0000) | 0xF6 |
| `nes_chr_spr($n)` | int リテラル 0-7 | sprite 用 4KB CHR bank を切替 (MMC1 CHR bank 1, $1000) | 0xF5 |
| `nes_bg_color($c)` | int リテラル 0x00-0x3F | 背景色を設定 (PPU $3F00、全パレット共通) | 0xF7 |
| `nes_palette($id, $c1, $c2, $c3)` | int リテラル × 4 | パレットの色 1-3 を設定。id 0-3 = BG、4-7 = sprite | 0xF8 |
| `nes_attr($x, $y, $pal)` | int, int, int リテラル 0-3 | BG attribute table: 2×2 タイル (16×16 px) ブロック単位でパレット番号を割当 | 0xF9 |
| `nes_vsync()` | — | 次 VBlank (NMI) まで spin wait。未起動なら sprite_mode を自動有効化 | 0xFA |
| `nes_btn()` | — | 現在のコントローラ状態を IS_LONG で返す (下位 1B が bitmask: A=0x80, B=0x40, Sel=0x20, Start=0x10, U=0x08, D=0x04, L=0x02, R=0x01) | 0xFB |

opcode 番号の根拠と折り畳みパターンは [`spec/04-opcode-mapping.md`](./spec/04-opcode-mapping.md)、`nes_chr_*` の詳細は [`spec/11-chr-banks.md`](./spec/11-chr-banks.md)、入力 API の使い方は [`spec/06-display-io.md`](./spec/06-display-io.md)。

### リアルタイム入力の書き方

```php
<?php
$x = 120; $y = 120;
nes_sprite($x, $y, 88);
while (true) {
    nes_vsync();                     // 60fps pacing
    $b = nes_btn();                  // 現在の押下状態を bitmask で
    if ($b & 0b00000010) { $x = $x - 1; }  // Left
    if ($b & 0b00000001) { $x = $x + 1; }  // Right
    if ($b & 0b00001000) { $y = $y - 1; }  // Up
    if ($b & 0b00000100) { $y = $y + 1; }  // Down
    nes_sprite($x, $y, 88);
}
```

### レンダリング状態の制約

表示系 intrinsic には 2 つのモードがあります:

- **forced_blanking** (初期状態): `echo` / `nes_put` / `nes_puts` / `nes_cls` が nametable を直接叩ける。`fgets` 中だけ一時的に rendering ON でボタンを待つ
- **sprite_mode** (初回 `nes_sprite` 以降): rendering 常時 ON、NMI ハンドラが毎 VBlank で OAM DMA を実行。**Phase 3 の NMI 同期書き込みキュー**により、`echo` / `nes_put` / `nes_puts` は透過的に動く (実際の PPU 書き込みは次 VBlank に遅延)。`nes_cls` は **Phase 3.1 の brief force-blanking** 方式で動く (1-2 フレームの黒フラッシュを伴うトランジション)

一度 sprite_mode に入ると戻れません。典型パターンは「初期 echo で説明 → `nes_sprite` でゲームループに突入 (sprite + 動的テキスト + スライド遷移 すべて共存可能)」。詳細は [`spec/06-display-io.md`](./spec/06-display-io.md)、sprite_mode 同居サンプルは `examples/livetext.php` と `examples/livereset.php`。

---

## 同梱サンプル

| ファイル | できること | 主な使用機能 |
|---|---|---|
| [`examples/hello.php`](./examples/hello.php) | `HELLO, NES!` を表示 | `echo` |
| [`examples/arith.php`](./examples/arith.php) | 16bit 整数演算の表示 | CV/TMP、`+` `-` |
| [`examples/loop.php`](./examples/loop.php) | `01234` を順に出力 | `while`, `<`, 16bit 比較 |
| [`examples/iftest.php`](./examples/iftest.php) | `if` + 比較の動作確認 | `if`, `===`, `!==`, 単文 body |
| [`examples/for.php`](./examples/for.php) | `for` ループ + `++` / `--` | `for`, `PRE_INC`, `POST_INC`/`DEC` |
| [`examples/comments.php`](./examples/comments.php) | `//` `#` `/* */` すべて通る | コメント parser |
| [`examples/bintest.php`](./examples/bintest.php) | 2 進 / 16 進 / 10 進混在 + `&` `\|` | `0b..`, `0x..`, ビット演算 |
| [`examples/logtest.php`](./examples/logtest.php) | `&&` `\|\|` `<<` `>>` の挙動確認 | 短絡評価、シフト |
| [`examples/button.php`](./examples/button.php) | 押したボタン文字を表示 (blocking) | `fgets(STDIN)` |
| [`examples/poll.php`](./examples/poll.php) | 十字キーで `X` を 60fps 連続移動 | `nes_vsync` + `nes_btn` + `&` |
| [`examples/move.php`](./examples/move.php) | 十字キーで `X` をタイル単位移動 | `nes_put`, `===` |
| [`examples/sprite.php`](./examples/sprite.php) | 十字キーで `A` をピクセル単位移動 | `nes_sprite`, NMI |
| [`examples/slides.php`](./examples/slides.php) | ボタンで 1 行ずつ進むプレゼン | `nes_puts`, `nes_cls` |
| [`examples/presen.php`](./examples/presen.php) | マルチスライド長尺プレゼン | `nes_puts`, CHR バンク切替 |
| [`examples/presen_cv.php`](./examples/presen_cv.php) | CV で状態管理するプレゼン | CV + `if` + `while` |
| [`examples/chrdemo.php`](./examples/chrdemo.php) | BG pattern table / CHR バンク切替 | `nes_chr_bg`, `nes_chr_spr` |
| [`examples/livetext.php`](./examples/livetext.php) | スプライト移動中にテキストを動的描画 | `nes_sprite` + `nes_puts` 同居 |
| [`examples/livereset.php`](./examples/livereset.php) | スプライト表示中にスライドをクリア+切替 | `nes_sprite` + `nes_cls` 同居 |
| [`examples/color.php`](./examples/color.php) | カラフルプレゼン: 行ごとの色分け | `nes_palette` + `nes_attr` + `nes_bg_color` |
| [`examples/err_syntax.php`](./examples/err_syntax.php) | わざと構文エラー → NES 画面にエラー表示 | コンパイラ error reporting |

各サンプルの受け入れ基準と xxd 検証パターンは [`spec/09-verification.md`](./spec/09-verification.md)。

---

## カスタム CHR で絵を差し替える

`chr/font.chr` は 32KB = 4 × 8KB の CNROM バンクです。`chr/make_font.php` が生成しているので、そこを書き換えて `php chr/make_font.php` で再生成 → `make` で再ビルド。

標準の内容:
- **Bank 0 / pattern table 0**: 5×7 のシンプル ASCII フォント
- **Bank 0 / pattern table 1**: 上記の **インバース** (`nes_chr_bg(1)` で白抜き風)
- **Bank 1-3**: Bank 0 のコピー (プレゼン用に差し替える想定)

全バンク・全 pattern table の中身を自由に編集する手順は [`spec/11-chr-banks.md`](./spec/11-chr-banks.md#カスタム-chr-の作り方) に詳細。

---

## License

MIT License. See [LICENSE](./LICENSE).

### PHP compatibility note

This project references Zend VM opcode numbers and struct layouts (`zend_op`, `zval`, `zend_string`) from PHP 8.4 source for binary interoperability. No PHP source code is included or redistributed.

### Trademarks

"NES", "Famicom", and "Nintendo" are trademarks of Nintendo. This project is not affiliated with, endorsed by, or sponsored by Nintendo.
