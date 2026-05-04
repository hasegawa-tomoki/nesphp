# 10. 開発ログ: 設計判断の経緯

[← README](./README.md)

本プロジェクトの各フェーズで「何を作ったか」ではなく「**なぜそれを選んだか**」「**何で躓いたか**」を時系列で記録する。仕様書 (01〜09) が「今の設計」、これは「そこに至るまでの思考」。

---

## Phase 0: プロジェクト前提の確定

### 核心の選択: L1 vs L3 vs L4

「6502 で PHP opcode を実行する」と言ったとき、忠実度には段階がある。

| レベル | 中身 | 評価 |
|---|---|---|
| L1 | 独自の痩せたバイトコードに翻訳 (opcode 番号もオリジナル) | **不採用** — ロマンが出ない |
| L3 | `zend_op` 構造体 (32B) を `handler` ポインタだけ抜いて ROM にそのまま焼く。literals は Zend の 16B `zval`。6502 VM は Zend のフィールドオフセットを直読み | **採用** — `xxd` で Zend 互換 byte が見える |
| L4 | L3 + zval を RAM にも 16B そのまま持ち、IS_LONG を 64bit で再現 | 不採用 — 2KB RAM が枯渇 |

**決定の根拠**: L1 は実装が最も楽だが「PHP opcode を持ち込んだ」感が薄い。L4 は 64bit 多倍長演算 + 16B RAM zval で 2KB WRAM を即枯渇させる。L3 が「Zend 互換レイアウト + 6502 で実行可能」の唯一の交点。

### 抽出手段の選択

| 手段 | 判定 |
|---|---|
| VLD 拡張 | 追加 `pecl install` が必要。サブ候補 |
| **opcache.opt_debug_level=0x10000** | **MVP 採用** — stock PHP 同梱、追加インストール不要 |
| 自作 Zend 拡張 (C) | 第 2 段階の理想形。テキストパース層を殺せる |
| opcache ファイルキャッシュ直読み | 却下 — 非公開フォーマット、メモリアドレス依存 |

---

## Phase 1: MVP (echo のみ → `hello.nes`)

### ゴール

```php
<?php echo "HELLO, NES!";
```

を `.nes` にして Mesen で表示する。

### 決定事項

- **PHP 8.4 版ロック**: opcode 番号は PHP マイナー版で動くので、`/opt/homebrew/Cellar/php/8.4.6/include/php/Zend/zend_vm_opcodes.h` を直接見て定数をハードコード
- **ROM レイアウト**: iNES NROM-256 (32KB PRG + 8KB CHR)、PRG 前半 ($8000-$BFFF) に `ops.bin`、後半 ($C000-$FFFF) に VM 本体
- **CHR-ROM フォント**: 5×7 bitmap を手書きで 96 タイル分、タイル番号 = ASCII コード配置。これで `zend_string.val[]` のバイトを nametable にそのまま書ける
- **RAM 常駐値**: 16B zval を全て RAM に持つと足りないので、**4B tagged value** (type 1B + payload 3B) に narrow

### 躓き 1: spec が書いた仮値と実際の定数のズレ

spec/01-rom-format.md 初版は以下を仮値で書いていた:

- `ZEND_ECHO = 0x28` (仮) → **実際は 0x88 (136)**
- `ZEND_RETURN = 0x3e` (仮) → 正しかった (偶然)
- `IS_UNUSED = 8`, `IS_CV = 16` → **誤り**。正しくは `IS_UNUSED=0, IS_CV=8`

最初の実装時に `zend_vm_opcodes.h` と `zend_compile.h` を直接 grep して確定し、spec を訂正。以降は「仮値禁止、必ず実ヘッダから取る」をルール化。

### 躓き 2: `xxd` の既定フォーマット

spec に `xxd build/hello.nes | grep '28 01 08 08'` と書いていたが、`xxd` 既定は 2 バイトグループ (`2801 0808`) で出るのでヒットしなかった。**`xxd -g 1`** を明示する必要。

### 成果

`build/hello.nes` (40976 バイト):

```
strings hello.nes → HELLO, NES!
xxd -g 1 hello.nes | grep '88 01 00 00'  → ZEND_ECHO (IS_CONST)
xxd -g 1 hello.nes | grep '3e 01 00 00'  → ZEND_RETURN (IS_CONST)
```

Mesen で画面中央に `HELLO, NES!` が表示される。

---

## Phase 2: 整数演算 + ローカル変数 (`arith.nes`)

### ゴール

```php
<?php $a = 1; $a = $a + 2; echo $a;  // → 3
```

### 決定事項

- **対応 opcode 追加**: `ZEND_ASSIGN (22)`, `ZEND_ADD (1)`, `ZEND_SUB (2)`, `ZEND_QM_ASSIGN (31)`
- **CV / TMP slot 番号の表現**: `op.var` フィールドに `slot_num * 16` を埋め込む (Zend runtime の byte offset 慣習に近似、ただし `sizeof(zend_execute_data)` オフセットは除去)
  - VM 側は `LSR LSR` (/4) で `slot * 4` を得て `VM_CVBASE` に加算 → 4B tagged value のスロットアドレス
- **Operand resolver**: `resolve_op1` / `resolve_op2` を汎用化して `IS_CONST / IS_CV / IS_TMP_VAR / IS_VAR` を全て 4B tagged value に narrow。ハンドラ側は統一的に `OP1_VAL` / `OP2_VAL` を見る
- **int16 → ASCII**: decimal 変換は 6502 スタックに桁を push して pop しながら PPUDATA に出力。divmod by 10 は標準的な shift-and-subtract

### 躓き: echo の integer 対応

`echo $a;` の `$a` は IS_LONG (IS_CONST や IS_CV 経由で 4B tagged value)。これまで ECHO handler は IS_STRING のみを想定していたので、IS_LONG の枝を追加して `print_int16` ルーチンを呼ぶ形に。

`print_int16` は書いたバイト数を `pi_count` (zero page) に返し、`echo_long` 側で `PPU_CURSOR += pi_count` を更新。

### 成果

`arith.nes` → 画面に `3`。実態は ASSIGN → ADD → ASSIGN → ECHO (IS_LONG) → RETURN の 5 命令を 6502 がそのまま実行。

---

## Phase 3: 制御フロー (`loop.nes`)

### ゴール

```php
<?php $i = 0; while ($i < 5) { echo $i; $i = $i + 1; }  // → 01234
```

### 決定事項

- **対応 opcode 追加**: `ZEND_JMP (42)`, `ZEND_JMPZ (43)`, `ZEND_JMPNZ (44)`, `ZEND_IS_SMALLER (20)`, `ZEND_IS_EQUAL (18)`
- **ジャンプ先のエンコード**: opcache dump では `JMP 0005` / `JMPNZ T4 0002` のように raw 4 桁 op_index で表記。serializer はこの数値を対応 operand フィールド (JMP は op1、JMPZ/JMPNZ は op2) に uint16 で埋め込み、operand type は `IS_UNUSED (0)`
- **VM 側の計算**: `VM_PC = OPS_FIRST_OP + op_index * 24`。乗算 24 = 16+8 を `<<3` + `<<1` (保存して加算) の shift で
- **is_truthy ヘルパ**: `OP1_VAL` を評価して A=1/0 を返す (Z フラグ同期)。`IS_NULL/IS_FALSE/IS_UNDEF`: falsy、`IS_TRUE`: truthy、`IS_LONG`: 値 ≠ 0 なら truthy、`IS_STRING`: 常に truthy (簡略化、PHP の `""`/`"0"` は falsy だが未対応)

### 発見: while は bottom-test にコンパイルされる

opcache 出力:

```
0000 ASSIGN CV0($i) int(0)
0001 JMP 0005            ← condition check へ
0002 ECHO CV0($i)        ←┐ body
0003 T2 = ADD CV0($i) int(1)  │
0004 ASSIGN CV0($i) T2   ←┘
0005 T4 = IS_SMALLER CV0($i) int(5)  ←┐ condition
0006 JMPNZ T4 0002       ←┘
0007 RETURN int(1)
```

最初に `JMP 0005` で condition block へ行き、真なら body へ戻る。C コンパイラの while ループ最適化と同じ構造。

### 躓き: 符号付き 16bit 比較のイディオム

IS_SMALLER は `op1 < op2` を 16bit 符号付きで計算する必要。6502 の標準イディオム:

```
SEC
LDA op1_lo ; SBC op2_lo
LDA op1_hi ; SBC op2_hi
BVC :+           ; オーバーフローしていれば
EOR #$80         ; 符号を反転
:
BMI is_smaller_true
```

オーバーフロー補正が必要なのは、2 つの符号付き 16bit の差が 16bit に収まらないケース。`BVC + EOR #$80` の組み合わせで符号が正しく得られる。

---

## Phase 4: コントローラ入力 (`button.nes`)

### ゴール

```php
<?php echo "Press: "; $k = fgets(STDIN); echo $k;
```

ボタンを押すと対応する文字 (A/B/S/T/U/D/L/R) が表示される。

### 決定事項

- **custom opcode**: `NESPHP_FGETS = 0xF0` (Zend は 0-209 を使うので 0xE0-0xFF 帯を nesphp 独自領域に)
- **serializer のパターン畳み込み**: `INIT_FCALL "fgets" + FETCH_CONSTANT "STDIN" + SEND_VAL + DO_ICALL` の 4 命令シーケンスを `NOP + NOP + NOP + NESPHP_FGETS` に置換。op_index の並びは保つ (ジャンプ先が壊れないように)
- **pre-baked 1 文字 zend_string**: `button_str_a` 〜 `button_str_r` を VM CODE セグメントに固定配置 (ca65 マクロ `ONE_CHAR_ZSTR`)。fgets が返す IS_STRING は対応する ROM オフセット
- **rendering の on/off toggle**: fgets 中だけ rendering を enable → wait → disable。これで echo (forced blanking 前提) と fgets (rendering 必須) を同居
- **コントローラ読み取り**: $4016 ラッチ + シフトで bit 7=A ... bit 0=R の 1 バイトに。優先度順 (A > B > S > T > U > D > L > R) で最初の押下を文字にマッピング

### 躓き: `opcache.file_update_protection=2` のトラップ

`touch examples/hello.php && make` でビルドすると **dump が空になる** 症状。数時間追跡した結果、原因は:

- opcache のデフォルト `file_update_protection = 2` は「mtime が現在から 2 秒以内の新しいファイルはキャッシュしない」という race condition 対策
- キャッシュしない = optimizer が走らない = `opt_debug_level` も走らない → stderr に何も出ない

対策: Makefile で `-d opcache.file_update_protection=0` を常に付ける。これで触りたてのファイルでも optimizer 経由で dump が出る。

これは spec/05-toolchain.md に根拠込みで記録した。

### 躓き: ECHO の PPUADDR 再セット

fgets 中に rendering を on/off すると PPU 内部 latch 状態が壊れる。以降の ECHO が想定位置に書けなくなる。

対策: ECHO handler を「毎回 `PPUADDR = PPU_CURSOR` をセット」に変更。以前は reset で 1 回セットするだけで auto-increment 任せだったが、PPU state が壊れるケースを考慮して冪等化。同時に `PPU_CURSOR += written_bytes` を RAM で追跡する実装に。

---

## Phase 5A: タイル単位の文字移動 (`move.nes`)

### ゴール

```php
<?php
$x = 16; $y = 14;
nes_put($x, $y, "X");
while (true) {
    $k = fgets(STDIN);
    nes_put($x, $y, " ");
    if ($k === "L") $x = $x - 1;
    // ...
    nes_put($x, $y, "X");
}
```

十字キーで `X` が 8×8 タイル単位で動く。

### 決定事項

- **新 custom opcode**: `NESPHP_NES_PUT = 0xF1` — `(x, y, char)` の 3 引数を取って nametable に 1 文字書く
- **引数 encoding**: op1 = x, op2 = y, extended_value = char literal の byte offset (常に `IS_CONST`)
- **`===` (IS_IDENTICAL) 対応**: これまで `IS_EQUAL` は 4B tagged value の byte 比較しかしていなかったので、ROM 内 `button_str_l` (CODE セグメント) とユーザリテラル `"L"` (ops.bin セグメント) が別アドレスでマッチしない
  - → `values_equal_content` ヘルパを追加: 文字列なら `zend_string.len + val[]` を読む content 比較
  - `IS_IDENTICAL` と `IS_EQUAL` は同じ実装を共用 (PHP の type juggling は簡略化のため未対応)

### 躓き: opcache が出す opcode のバリエーション

opcache 出力で `nes_put(...)` は `INIT_FCALL_BY_NAME` を使う (internal 関数でないので `INIT_FCALL` にならない)。そして `SEND_VAR_EX` / `SEND_VAL_EX` など `_EX` 接尾辞付き variant も出てくる。serializer の畳み込みパターンを拡張:

```php
if (preg_match('/^SEND_(VAL|VAR)(_EX|_NO_REF(_EX)?)?$/', $mnemonic)) { ... }
```

あと `DO_ICALL` (129) と `DO_FCALL_BY_NAME` (131) と `DO_FCALL` (60) は全て同じ畳み込み先に。

### 躓き: PHP 実行時エラー = make 失敗

`nes_put` は PHP に存在しない関数なので、opcache dump 後に PHP runtime がこの関数を呼ぼうとして fatal error で非 0 exit する。make が `.DELETE_ON_ERROR` で ops.txt を削除し、永久に失敗。

対策: Makefile の opcache dump コマンドに `|| true` を追加し、PHP の exit code を無視。dump 本体は error より前に stderr に書かれているので内容は保全される。

---

## Phase 5B: ハードウェアスプライトでピクセル移動 (`sprite.nes`)

### ゴール

```php
<?php
$x = 120; $y = 120;
nes_sprite($x, $y, 65);  // 65 = 'A'
while (true) {
    $k = fgets(STDIN);
    if ($k === "L") $x = $x - 2;
    // ...
    nes_sprite($x, $y, 65);
}
```

`A` がスプライトとして表示され、十字キーで 2 ピクセルずつピクセル移動する。

### 決定事項

- **新 custom opcode**: `NESPHP_NES_SPRITE = 0xF2`。形は nes_put と同じ 3 引数。内部的には常に sprite 0 を操作
- **OAM shadow $0200-$02FF**: reset で y=$FF 初期化 (64 個のスプライトを全て画面外に隠す)
- **NMI ハンドラ実装**: 毎 VBlank で `STA $4014` による OAM DMA (256 バイト転送、~513 サイクルで CPU 停止)。スクロールを (0, 0) にリセット
- **sprite_mode_on フラグによる遅延遷移**: 初回 `nes_sprite` 呼び出しで以下を実行:
  1. VBlank 待ち
  2. 初回 OAM DMA (隠しスプライトを反映)
  3. `PPUCTRL` bit 7 で NMI enable
  4. `PPUMASK` で BG + sprite rendering 有効化
  5. `sprite_mode_on = 1`
  以降 `fgets` は rendering の toggle をスキップし、rendering は常時 ON

### 設計上のトレードオフ

| 選択肢 | 採否 | 理由 |
|---|---|---|
| Reset で即 rendering ON + NMI | ❌ | 初期の echo (forced blanking 前提) が壊れる |
| 全 echo を VBlank 同期化 | ❌ | 実装コスト高、echo のセマンティクスが複雑化 |
| **初回 nes_sprite で遷移** | ✅ | ユーザパターン (「初期 echo → sprite 無限ループ」) に合致 |

**制限**: `echo` / `nes_put` は `nes_sprite` より **前** にしか使えない。sprite_mode 後に呼ぶと rendering 中の nametable 書きで画面破壊。spec に明記。

### 躓き: 4 引数が `zend_op` に入らない

元々「`nes_sprite($id, $x, $y, $tile)`」と 4 引数で考えていたが、`zend_op` には op1/op2/result/extended_value の 4 フィールドしかなく、しかも result は通常「書き戻し先」として使うので source として流用しづらい。

→ 妥協: **sprite 0 固定**にして 3 引数 `nes_sprite($x, $y, $tile)` に。多スプライトは後日の拡張課題。

---

---

## Phase 5C: プレゼンテーション用途 (`slides.nes`)

### ゴール

```php
<?php
$p = 0;
while (true) {
    $k = fgets(STDIN);
    $p = $p + 1;
    if ($p === 7) { $p = 1; }
    if ($p === 1) { nes_cls(); nes_puts(4, 4, "NESPHP PRESENTATION"); }
    if ($p === 2) { nes_puts(4, 7, "1. PHP ON FAMICOM"); }
    // ...
}
```

ボタンを押すごとに行が追加表示され、最後まで行ったら次のボタン押下で画面クリアして先頭から。LT 向けプレゼン資料を NES 上で動かす。

### 決定事項

- **新 custom opcode 2 種**: `NESPHP_NES_PUTS = 0xF3`, `NESPHP_NES_CLS = 0xF4`
  - `nes_puts($x, $y, "literal")`: nes_put と同じ 3 引数パターン。op1=x, op2=y, extended_value=string literal の zval offset。VM は `zend_string.len + val[]` を PPUDATA に一括流し込み。行折り返しは実装せず (呼び出し側で y を明示)
  - `nes_cls()`: 引数 0、nametable 0 全域 ($2000-$23FF 1024B) を空白 ($20) で埋め、`PPU_CURSOR` を既定位置に戻す
- **serializer の畳み込み拡張**: nes_put / nes_sprite の 3 引数ブランチを `$customMap` で配列化して nes_puts を追加。nes_cls は 0 引数なので DO_FCALL_BY_NAME 直後に別ブランチで畳み込み
- **どちらも forced_blanking 前提**: nes_put と同じ制約。fgets 中に rendering が ON → nes_puts/nes_cls 実行時は rendering が OFF なので PPUDATA 書き込みが安全。sprite_mode 中は呼び出し不可 (ドキュメントに明記)

### 設計上のトレードオフ

| 選択肢 | 採否 | 理由 |
|---|---|---|
| echo を NMI 同期化して行追加 | ❌ | ロードマップ第 3 段階の大型改修、プレゼン用には過剰 |
| 「全行ハードコード」で nes_put を文字数分呼ぶ | ❌ | 数百行の PHP になる、読めない |
| **nes_puts + nes_cls の intrinsic 追加** | ✅ | Phase 5A と同じ畳み込みパターンの素直な拡張、実装 1-2h |
| 行折り返しを VM 側で実装 | ❌ | コストに見合わない。プレゼンでは各行の (x,y) を明示する方が制御しやすい |

### 成果

`slides.nes`: 58 ops / 19 literals / 1988 バイトの ops.bin。ボタン押下で 5 行が順に表示され、6 回目で先頭に戻る。`xxd -g 1 build/slides.nes | grep f3` / `grep f4` で `NESPHP_NES_PUTS` / `NESPHP_NES_CLS` のバイトがヒット。

### 発見: `nes_cls()` の opcache 出力は素直

0 引数の internal-likeな関数呼び出しは:

```
INIT_FCALL_BY_NAME 0 string("nes_cls")
DO_FCALL_BY_NAME
```

の 2 命令に落ちる (SEND_* なし)。畳み込みは `$pendingArgs === []` を確認するだけで済む。一方 `nes_puts` の string 3 引数は `SEND_VAL_EX string("...") 3` の形で出るので、既存の `parse_operand` がそのまま IS_CONST/TYPE_STRING として解決してくれる。serializer 側の変更量は最小。

---

## Phase 3: NMI 同期書き込み (`livetext.nes`)

> ロードマップ的には第 3 段階として以前から残っていた課題。Phase 5B (sprite_mode) の
> 副作用で「sprite_mode 中は echo / nes_put / nes_puts / nes_cls 不可」という制約が
> 発生して以来、この解決はずっと保留だった。プレゼン用途で sprite と動的テキストを
> 併用したくなった契機で実装した。

### ゴール

sprite_mode 中 (rendering 常時 ON) でも `echo` / `nes_put` / `nes_puts` を動かす。
呼び出し側は今まで通りに書けて、VM 側が透過的に「直書き」と「NMI 同期書き込み」を
切り替える。

### 決定事項

**NMI 同期書き込みキュー方式**を採用。メインループでは `nmi_queue_write` に
エントリを積むだけで、実際の PPU 書き込みは NMI ハンドラが VBlank 中に
`flush_nmi_queue` で実行する。

- **キュー実体**: RAM `$0300-$03FF` 256 バイトのリングバッファ
- **フォーマット**: `[addr_hi, addr_lo, len, data[len]]` のエントリ列
- **head 方式**: `nmi_queue_write` (producer = main) と `nmi_queue_read` (consumer = NMI) が独立、両方ともモノトニック増加の uint8
- **ハンドラ共有**: `ppu_write_bytes` ヘルパに (TMP0=addr, TMP1=src ptr, TMP2=len) を渡して `sprite_mode_on` で直書き/queue に分岐。3 個のハンドラ (echo/nes_put/nes_puts) が同じヘルパを使う

### 検討した代替案

| 案 | 採否 | 理由 |
|---|---|---|
| rendering を一時 OFF → 書いて → 再度 ON | ❌ | 1 フレーム画面が消えてちらつく。sprite_mode の体験を壊す |
| CHR-RAM で nametable を PRG に複製 | ❌ | マッパー変更と複雑度増。割に合わない |
| **VBlank 同期書き込みキュー** | ✅ | 標準的な NES パターン、実装 150 行程度、既存 API を壊さない |
| double buffer (シャドウ nametable を VM 側に持つ) | ❌ | 2KB RAM を使い切る、nesphp の tagged value RAM と衝突 |

### 躓き 1: `nes_cls` が 1 VBlank で終わらない

最初は「nes_cls も NMI 同期化する」方向で設計していたが、nes_cls は
nametable 0 全域 = 960 バイト (+ 属性 64B = 1024B) を空白で埋める動作。

- 1 PPUDATA 書き込み = `LDA abs; STA abs` で最低 4 サイクル (データをあらかじめ
  A に持っていれば 4)
- 1024 バイト × 4 cycle = 4096 cycle
- VBlank 予算 ~2273 cycle では 1 フレームに収まらない

選択肢:
1. chunked clear (4 フレーム = 67ms に分散)
2. sprite_mode では nes_cls を未対応のままにする

2 を選択。nes_cls はスライド遷移にしか使わないので、forced_blanking 限定で
十分 (プレゼンは「初期 echo で intro → nes_sprite に入って interactive」という
構造)。chunked clear は実装と NMI ハンドラの状態機械が複雑化するので見送り。

### 躓き 2: head リセットの race condition

初版では NMI が flush の末尾で `nmi_queue_read = nmi_queue_write = 0` にして
バッファを先頭から再利用する設計にしていた。しかしこれには race がある:

```
main:  LDX nmi_queue_write   ; X = W_old
       (NMI fires here)
NMI:   flushes 0..W_old-1
       sets read = write = 0
main:  (resumes) writes bytes at positions X, X+1, ..., X+N-1
                 using the STALE X = W_old
       STX nmi_queue_write   ; write = W_old + N
```

これにより `read=0, write=W_old + N` という不整合になり、次 NMI は 0..W_old+N-1
を flush → 既に flushed 済みの 0..W_old-1 を**再度 PPU に出力**してしまい
画面破壊。

**修正**: head をリセットせず、**両方ともモノトニック増加**させる。256 で
自然 wrap するので、バッファは ring buffer になる。`NMI_QUEUE_ADDR = $0300`
をページ境界に揃えると、`LDA NMI_QUEUE_ADDR, X` の X 自動 wrap でエントリが
終端をまたいでも透過アクセスできる。

この変更で:
- main は `write` のみ更新、NMI は `read` のみ更新 → writer / reader 排他
- main の X cache が NMI の影響を受けない (NMI は reset しないので)
- 空き容量は `(read - write - 1) & $FF` で計算 (ring buffer の標準式)
- main が free を計算中に NMI が read を進めると free は過小評価されるが、
  安全側に傾くだけで corruption にはならない

トータル 60 行程度の書き直しで race-free になった。

### 躓き 3: `print_int16` が PPUDATA 直書き

Phase 2 以来、`print_int16` は divmod で桁を出しながら直接 PPUDATA に
書き込んでいた。これは forced_blanking 中前提で、sprite_mode では当然動かない。

**修正**: `print_int16` を「`INT_PRINT_BUFFER = $0600` に出力」にリファクタ。
`pi_count` に長さを返すのは従来通り。呼び出し側 (echo_long) は buffer を
`ppu_write_bytes` に渡す。これで forced_blanking / sprite_mode 両対応。

副作用として echo_long のコード構造が echo_string と対称になり、2 つの分岐が
共通の `echo_write` ラベルに合流できるようになった (クリーンアップ)。

### 躓き 4: ハンドラ間での TMP0/TMP1/TMP2 の意味の衝突

既存の `handle_nesphp_nes_put` は TMP2 に 1 文字ぶんの char コードを持って
いたが、`enqueue_ppu_nt` では TMP2 = len (バイト長)。同じ zero page を違う
意味で使っていた。

**修正**: nes_put ハンドラ内で char を `INT_PRINT_BUFFER[0]` に移し、TMP1 =
INT_PRINT_BUFFER, TMP2 = 1 の形で統一。これで echo / nes_put / nes_puts 全て
同じ「TMP0=addr, TMP1=src ptr, TMP2=len」契約で `ppu_write_bytes` に委譲できる。

### 解けた連鎖的な制限

Phase 3 実装の副産物として、以下も同時に解決:

1. **sprite_mode で動的テキスト表示**: プレゼン用途のゲーム化 (sprite + スライド)
2. **sprite_mode でのスコア/ステータス更新**: echo による整数表示も動く
3. **sprite と静的テキストの共存**: livetext.nes で demo

ただし以下は Phase 3 スコープ外として残る:
- nes_cls (1 VBlank で終わらない)
- nes_chr_bank / nes_chr_bg の tearing (CHR 切替は即時反映で VBlank 同期しない。
  これらの NMI 同期化は別途必要だが、プレゼン用途ではスライド遷移時のみの使用
  なので優先度低)

### 成果

`build/livetext.nes`: sprite が画面中央でユーザ操作により動く中、A ボタン押下で
「HIT!」テキストが 1 行ずつ下に追加される。従来は sprite_mode 中に nes_puts を
呼ぶと PPU latch 汚染で画面全体が崩れていたが、Phase 3 では NMI 経由の書き込み
なのでスプライトも背景も無傷。

既存 example (hello/arith/loop/button/move/sprite/slides/chrdemo) は全て
無変更で引き続き動作。forced_blanking パスが echo_string / echo_long / nes_put /
nes_puts いずれもリファクタ前と等価な直書きを維持しているため。

---

## Phase 3.1: sprite_mode での nes_cls (`livereset.nes`)

> Phase 3 直後に発覚した未解決の footgun。`nes_cls` は NMI キュー方式を使えない
> (1024B / VBlank 予算 ~2273 cycle) ので別アプローチが必要だった。プレゼン用途
> でスライド遷移に nes_cls を使いたいという要求から、Phase 3 の直後に実装した。

### 発覚した問題

Phase 3 でハンドラ dual-path 化を進めたが `handle_nesphp_nes_cls` は対象外
だったため、sprite_mode 中に nes_cls を呼ぶと無条件で PPUADDR / PPUDATA 直書き
していた。実際に発生する破壊:

1. `STA PPUADDR` × 2: rendering 中の PPUADDR 書き込みは PPU 内部 v register
   ($2000 に直接上書き) を汚染 → scroll と現在 scanline の nametable 参照
   位置がいきなり飛ぶ
2. `STA PPUDATA` × 1024: rendering 中の PPUDATA は undefined behavior。
   CPU の v 自動インクリメントと PPU render pipeline の v 更新がバッティング
   し、1024 バイトの $20 が nametable にランダム散布
3. 所要 ~5000 cycle ≈ 18 scanline で可視領域が汚染される
4. スプライトは OAM shadow 別系統で無傷、背景だけ穴だらけ

### 選択肢検討

| 案 | コスト | 副作用 | 採否 |
|---|---|---|---|
| (A) runtime no-op guard | 極小 | クリアできない | ❌ 機能喪失 |
| (B) handle_unimpl で halt | 極小 | プレゼン中に止まる | ❌ UX 悪 |
| (C) compile-time エラー | 小 | nes_sprite → nes_cls フロー不可 | ❌ 過剰 |
| **(D) brief force-blanking** | 中 | 1-2 フレームの黒フラッシュ | ✅ **採用** |
| (E) chunked clear via NMI queue | 大 | tearing なし、flash なし | ❌ 実装肥大化、NMI 状態機械追加 |

(D) を採用した理由: プレゼン用途では「スライド遷移 = ぱっと切り替わる」が期待
動作で、1-2 フレームの黒フラッシュはむしろトランジションとして機能する。
実装コストが低く、既存の Phase 3 設計を壊さない。

### 実装: brief force-blanking

`handle_nesphp_nes_cls` の先頭で `sprite_mode_on` をチェックし、sprite_mode
中は以下を実行:

```
1. ppu_ctrl_shadow をスタックに退避
2. PPUCTRL bit 7 クリア (NMI 無効化)
3. PPUMASK = 0 (rendering 停止)
4. 1024B clear loop (既存コード)
5. BIT PPUSTATUS → BPL で次 VBlank 待ち
6. STA $4014 で OAM DMA 手動実行 (NMI 無効化期間の補償)
7. PPUSCROLL = 0, 0
8. PPUMASK = %00011110 (rendering 再開)
9. PPUCTRL を shadow から復元 (NMI 再有効化)
10. PPU_CURSOR 戻し、JMP advance
```

forced_blanking パスは完全に無変更。`sprite_mode_on == 0` のときは従来どおり
最高速の直書き (初期表示の hello.nes や slides.nes に影響なし)。

### 躓き 1: NMI 無効化が必須だった

最初は「rendering を一時オフにするだけで clear できるだろう」と考えていたが、
sprite_mode 中は NMI が自動発火していて、NMI ハンドラは `flush_nmi_queue` で
PPUADDR を触る。これが clear 途中に割り込むと PPUADDR 状態が壊れて clear が
意図しない位置に書かれる。

PPUCTRL bit 7 を一時クリアして NMI 自体を発生させないようにすることで解決。
`ppu_ctrl_shadow` を 6502 スタックに PHA → 終わったら PLA で原子的に復元。

### 躓き 2: OAM DMA を補償しないとスプライトが古いままになる

NMI 無効化期間中は自動 OAM DMA が止まる。~1-2 フレームの間、スプライトが
前フレームの位置のまま表示される (気付きにくいが、移動中だと visual hitch)。

clear 末尾の VBlank 内で手動 `STA $4014` を 1 回発行することで、最低限の
OAM 更新を補う。完全な補償ではないが (1 フレームぶんは遅れる)、連続的な
スプライト移動が「ちょっとだけ止まる」程度で済む。

### 躓き 3: VBlank 待ちループが NMI 有効だと取りこぼす

`BIT PPUSTATUS; BPL` で VBlank flag を待つが、NMI が有効だと VBlank 発生時に
NMI ハンドラが割り込んで先に PPUSTATUS を読んでしまい (`BIT PPUSTATUS`)、flag
が消費される。その後のメインループの `BIT PPUSTATUS` は flag がクリアされた
状態を見てさらに 1 フレーム待つ → 挙動が不安定になる。

躓き 1 の NMI 無効化によりこれも解決 (NMI が割り込まないので flag を他の
コードが読まない)。

### 成果

`build/livereset.nes`: 初期スライド表示 → sprite_mode → A 押下で画面クリア
+ 次スライド描画が循環。sprite 位置はそのまま維持され、黒フラッシュは 1-2
フレーム (体感 ~30ms) で視覚的には「次スライドへのトランジション」として
違和感なし。

既存 example (hello/arith/loop/button/move/sprite/slides/chrdemo/livetext) は
全て無変更で動作。forced_blanking パスを `sprite_mode_on == 0` ブランチで
保護しているため、従来の高速直書き動作は完全に保たれる。

### 残課題 (Phase 3.1 スコープ外)

- `nes_chr_bank` / `nes_chr_bg` は sprite_mode 中に依然 tearing する。
  これらも NMI キューに「CHR 切替コマンド」として載せる方式で解決可能だが、
  VBlank 予算の配分と、切替直後に nametable を描き直す連鎖処理 (バンク切替
  だけで絵が化けるため) が絡むので、単純な queue 拡張では済まない
- MMC3 昇格は sprite と BG で別 CHR bank を持てるので、そもそも「切替で
  sprite が化ける」問題自体がなくなる。ただし mapper 実装コストは大きい

---

## Phase 5D: パターンテーブル切替 (`chrdemo.nes`)

### ゴール

プレゼンを「カッコイイ」方向に振るため、スライド毎にフォントやタイルセットを
差し替えたい。最低でも 2 系統、できれば 4-8 系統。

### 決定事項: (A) PPUCTRL bit 4 と (B) CNROM の併用

検討した 4 案:

| 案 | 粒度 | コスト | 採否 |
|---|---|---|---|
| (A) PPUCTRL bit 4 のみ | 同一 CHR 内 2 面 | 最小 (マッパー変更なし) | ✅ |
| (B) CNROM (mapper 3) のみ | 4 × 8KB バンク | マッパー昇格 | ✅ |
| (C) UxROM + CHR-RAM | 無限、スライド毎に任意タイル | マッパー実装 + RAM 転送ルーチン | ❌ (過剰) |
| (D) MMC3 + scanline IRQ | mid-frame 切替 | IRQ 処理、タイミング敏感 | ❌ (プレゼンには不要) |

(A) と (B) を**両方** 採用。組み合わせで **4 × 2 = 8 面の pattern table** を
取れる。(A) だけでは 2 面で物足りない、(B) だけではバンク内切替の細かさが
出ない、という補完関係。

### マッパー昇格: NROM-256 → CNROM (mapper 3)

- iNES ヘッダ: CHR 容量を 1 → 4 (4 × 8KB)、Flags 6 = `%00110000` (mapper LSB
  nibble = 3)
- `vm/nesphp.cfg`: CHR MEMORY 領域を `size = $2000` → `size = $8000`
- `chr/make_font.php`: 8KB 単位で `build_bank()` し、4 バンクぶんを連結して
  32KB の `font.chr` を出力

serializer には影響なし (ops.bin レイアウトは不変)。

### 躓き: バス衝突 (bus conflict)

CNROM は「CPU が $8000-$FFFF のどこかに STA した瞬間に mapper がバンク番号を
ラッチする」動作。ここで一部の実機では、書き込み先 ROM セルの値と書き込む値が
違うと挙動が壊れる (data bus に両者が同時に出力されるため)。

対策: ROM 内に「index 自身が入った LUT」を置き、`STA cnrom_bank_lut, X` で
書き込む。例えば bank 2 に切替えたいときは X=2, A=2 で書き込み、ROM の
`cnrom_bank_lut[2]` も `$02` なので衝突しない。

```asm
cnrom_bank_lut:
    .byte $00, $01, $02, $03
```

Mesen は bus conflict を無視しても動くが、実機互換性のためこのパターンを採用。

### `ppu_ctrl_shadow` の導入

`PPUCTRL` ($2000) は write-only なので、bit 4 だけ切り替えたい (= 他の bit を
保存したい) ときに現在値を知る手段がない。`ppu_ctrl_shadow` を zero page に
1 バイト確保して、書き込みの度に shadow と実レジスタを同期させる。

これで `nes_chr_bg` は sprite_mode で既にセットされた NMI enable bit (bit 7)
を壊さずに BG pattern table を切り替えられる。将来的に sprite pattern table
(bit 3) 切替 intrinsic `nes_chr_spr` を足すときもこの shadow に乗る。

### インバースフォントの自動生成

(A) をすぐ体感できるように、`make_font.php` が pattern table 1 に
「インバース字体」を自動生成するようにした:

```php
$bank[$t1 + $y] = chr($rows[$y] ^ 0xF8);  // 5 列幅でビット反転
```

space (0x20) だけは 0 のまま残して、nametable の未使用セルが埋まらないように。
`nes_chr_bg(1)` を呼ぶと、以降のテキストは「5 ピクセル幅の solid 背景にグリフ
形にくり抜かれた」ハイライト表示になる。タイトル強調用途にそのまま使える。

### バンク 1-3 の中身

初期状態では bank 1-3 は bank 0 のコピー。`chr/make_font.php` の `$banks`
配列を書き換えれば各バンクに独自タイルを入れられる。

「差し替え前提」のスタンスにした理由: デモ段階で想定できる絵柄 (ロゴ / 装飾
フォント) をコミットすると将来のプレゼン内容と合わない。使う人が自分のスライド
に合わせて生成するのが正しい。

### 成果

`chrdemo.nes`: 5 状態を遷移するサンプル。押すたびに NORMAL → INVERSE → NORMAL
→ BANK1 → BANK0 → ... と `nes_chr_bg` / `nes_chr_bank` が呼ばれる。xxd で
`f5 01 00 00` (NES_CHR_BANK with IS_CONST op1) と `f6 01 00 00` (NES_CHR_BG)
のバイト列が見える。ROM サイズは 16 + 32KB PRG + 32KB CHR = 65552 バイト。

### 既存 example への影響

マッパー昇格でビルド成果物のサイズは倍増するが、hello.nes / arith.nes /
loop.nes / button.nes / move.nes / sprite.nes / slides.nes は全て再ビルド
成功、`make verify` も通る。serializer と op_array レイアウトは無変更なので
ゾーンとしては隔離されている。

---

## 各フェーズ横断の学び

### 1. 「Zend に似せる」と「6502 で動く」の綱引き

L3 方針は「ROM レイアウトを Zend 互換」に固めたが、RAM 表現は 4B tagged に妥協した。結果として:

- **ROM 側 (ops.bin)**: Zend の `zend_op` / `zval` / `zend_string` を byte-for-byte 互換
- **RAM 側 (VM working state)**: 4B tagged value の独自形式

というハイブリッドに落ち着いた。「ROM を見れば Zend、RAM を見れば nesphp」の二面性。

### 2. opcache の debug output は思ったより癖が強い

- `opcache.opt_debug_level=0x10000` は optimizer 内で dump するが、cache 対象にならないファイルは optimizer が走らない
- `file_update_protection=2` (デフォルト) で 2 秒以内の mtime はスキップ
- CLI で SHM を使う設計なので、プロセス終了でキャッシュ消える (はず) だが、macOS で挙動不安定
- エラー時の exit code が 0 以外だと make が壊れる → `|| true` で防御

自作 Zend 拡張に移行すれば上記すべて解決するが、MVP では opcache パスで押し切った。

### 3. 関数呼び出し畳み込み: 「単一命令化」の判断

Zend の function call は 3〜5 命令 (INIT_FCALL + SEND_* + DO_*) に展開される。これを 6502 で逐命令実行するのは call stack 管理が必要で複雑。

→ serializer 側で「関数名 + 引数列」をパターン認識して **1 命令の custom opcode** に畳み込む方針で一貫。fgets / nes_put / nes_sprite 全てこのパターン。

この折り畳みは「serializer が関数名を知っている」という前提で成立する。**新しい intrinsic を足すたびに serializer のパターンマッチが必要**で、スケールしない。将来: 汎用的な `DO_FCALL_BY_NAME` を残して、VM 側で関数名テーブルを見る実装もあり得る (ROM に関数名表をもつ)。

### 4. 「Zend opcode 番号 = 事実データ」は本当にそうなのか

Oracle v. Google 以降、数値定数は著作物でないというのが通説。PHP 8.4 の opcode 番号一覧を spec に転記しているが、これは `zend_vm_opcodes.h` を直接読んだ結果の事実であり、コード断片のコピペではない。MIT で公開しても法的問題なしと判断 (spec/README の license note で明記済み)。

### 5. 「ファミコンで動く PHP」を正直に言語化すると

今回できたのは以下の PHP subset:

- 整数 (16bit narrow)
- 文字列 (ROM 内 immutable のみ、RAM 文字列なし)
- CV / TMP / VAR スロット
- if / while
- `===` / `==` / `<` (類似比較)
- echo
- intrinsic: fgets(STDIN), nes_put, nes_sprite

できない:
- 64bit int / double / 配列 / オブジェクト / 例外 / generator / closure
- 文字列連結 (ZEND_CONCAT 未実装)
- 関数定義 (ユーザ関数の呼び出しは INIT_FCALL_BY_NAME 経由で intrinsic に限定)
- 動的 echo (rendering 中の nametable 書きは未サポート)

でも、**`strings hello.nes` で `HELLO, NES!` が見え、`xxd -g 1 hello.nes | grep '88 01 00 00'` で ZEND_ECHO のバイト列がヒットする**のは事実。それでロマンは十分に成立した。

---

## Phase 5E: パレット + attribute + カスタムタイル

### ゴール

プレゼンテーション用途で「行ごとに色を変えたカラフルな画面」を PHP から作れるようにする。NES の PPU パレットと attribute table を PHP intrinsic 経由で操作し、カスタムタイルで簡単なグラフィック (日本国旗) も表示する。

### 設計判断: 3 つの intrinsic に分離

パレット操作を 1 つの「万能 API」にまとめる案もあったが、NES のハードウェア構造に素直に対応させて 3 つに分離した:

| intrinsic | NES ハードウェア対象 | 理由 |
|---|---|---|
| `nes_bg_color($c)` | PPU $3F00 (universal background) | 背景色は 1 色だけ、1 引数で完結 |
| `nes_palette($id, $c1, $c2, $c3)` | PPU $3F01+id*4 (3 色) | パレットのエントリ単位操作。BG (0-3) / sprite (4-7) を同じ API で統一 |
| `nes_attr($x, $y, $pal)` | attribute table ($23C0-$23FF) | 空間的な色割り当て。パレット設定とは独立 |

この分離により「背景色だけ変える」「パレットだけ差し替える」「行ごとの色割り当てだけ変える」がそれぞれ独立して呼べる。

### 4 引数 intrinsic のエンコーディング

`nes_palette($id, $c1, $c2, $c3)` は nesphp 初の 4 引数 intrinsic。zend_op の 24 バイトに 4 つの引数を収めるため、**result フィールドを入力として流用**した:

```
op1           = $id   (パレット番号)
op2           = $c1   (色 1)
result        = $c2   (色 2)  ← 通常は「出力先」だが入力に流用
extended_value = $c3   (色 3)
```

Zend の慣習から逸脱するが、custom opcode 領域 (0xE0-0xFF) なので問題ない。serializer の `pendingArgs` 配列に 4 要素を蓄積して DO_FCALL_BY_NAME で一括エンコードする。

### Attribute table の RAM shadow

NES の attribute table は 1 バイトに 4 つの 2×2 タイルブロックの情報が 2bit ずつ詰まっている。個別ブロックだけを書き換えるには read-modify-write が必要だが、PPU VRAM は読み出しにバッファ遅延があり直接 RMW が困難。

解決策として **64 バイトの RAM shadow** を `ATTR_SHADOW = $0608` に配置:

1. 起動時に shadow を $00 (全ブロック = palette 0) で初期化
2. `nes_attr` 呼び出しで: バイトオフセット = y/2 * 8 + x/2、ビット位置 = ((y&1)*2 + (x&1)) * 2
3. shadow のバイトを AND マスクで該当 2bit をクリア → OR で新パレット番号を挿入
4. 変更後のバイトを PPU $23C0+offset に書き出す

### カスタムタイルシステム

`chr/make_font.php` に `$customTiles` 配列を追加。ASCII フォントが使わないタイル番号 0x00-0x1F に自由なグラフィックを配置できるようになった。

日本国旗のデモでは 4 つのタイル (0x01-0x04) で 2×2 = 16×16 ピクセルの旗を表現:

- **bitplane 0** (色 1) = 白: 旗の背景 (全面白)
- **bitplane 1** (色 2) = 赤: 日の丸の円

`nes_palette` で色 1 = 白 ($30)、色 2 = 赤 ($16) を設定し、`nes_put` でタイル番号 0x01-0x04 を 2×2 に配置する。NES の 2 bitplane 方式を活用した最小限のグラフィック表現。

### 成果

`examples/color.php` → `build/color.nes`: 黒背景に赤タイトル、白本文、緑強調、水色フッタ、そして日本国旗。行ごとの色分けが PHP のコードだけで制御できることを実証。

---

## Phase W6: peek/poke + USER_RAM (zval オーバーヘッド回避)

### 動機: テトリス Phase 5b (回転) で 8KB PRG-RAM が枯渇

7 ピース × 4 回転 = 28 個の shape を保持するために配列 `$shapes = [...]` を使うと、1 要素 16B × 28 = **448 byte** を ARR_POOL から食う。$grid (20 entry × 16B = 320B) と合わせて 768B、ARR_POOL の残り (~460B) を超える。op_array (296×24=7104B) + literals (40×16=640B) もすでに 7.7KB を占めており、回転テーブルが入らない。

### 解決策の比較

| 案 | 評価 |
|---|---|
| 4×2 bbox の 8-bit shape のみ | I-piece の縦回転が 4×1 なので入らない、却下 |
| 重複排除した 19 個の shape | それでも 304B、ARR_POOL に入らず |
| 算法的回転 (`(x,y) → (3-y,x)` を PHP で計算) | op_array が +30〜50 op、上限ぎりぎり超過 |
| **peek/poke + USER_RAM** | **採用** — 1 byte あたり 1 byte のオーバーヘッドゼロ表現 |

### 設計

CV symbol table ($0700-$07FF, 256B) は L3S コンパイル中だけ使い、runtime では未使用。同領域を **USER_RAM** として peek/poke で再利用する。

新規 intrinsic 4 つ:
- `nes_peek($offset)` — USER_RAM[$offset] を IS_LONG で返す (byte 1 個)
- `nes_peek16($offset)` — little-endian 2byte を IS_LONG で返す
- `nes_poke($offset, $byte)` — USER_RAM[$offset] = byte (下位 1B)
- `nes_pokestr($offset, $string)` — 文字列の生バイトを USER_RAM にバルクコピー

**`nes_pokestr` が決め手**: 28 回転 × 2byte = 56byte の shape table を 1 op (= 1 文字列リテラル) で初期化できる。バラバラに 56 回 poke すると compile 時の op_array が 56 op 増えて即破綻。文字列なら str_pool に 56byte 載るだけで op は 1 個。

### 検討した「`$user_mem[$x]` 構文糖」却下理由

ユーザは「PHP の配列構文で書ければ自然」と提案したが、却下した:
- 既存 PHP 配列は 16B zval / ARR_POOL 管理 / `count()` 可能 — `$user_mem` だけバイト配列にすると同じ `[]` 構文で 2 種類のセマンティクスが混ざる
- parser に `$user_mem` 識別子の特例分岐が必要 (`[]` を見たら FETCH_DIM_R じゃなく NES_PEEK を emit、等)
- 既存 intrinsic パターン (`nes_put` 等) と一貫しない

**結論**: 関数 intrinsic の方が今の設計と地続き。op コストも同じ (どちらも 1 zend_op に compile される)。後付けで構文糖を被せるのは可能だが現時点で必要なし。

### Phase 5b の付随修正

回転対応に踏み込んでみたら、tetris.php の規模拡大で複数の潜在バグが顕在化した:

1. **CV / TMP slot 解決の 8-bit only バグ** (24 CV ある tetris で発覚): zend_op の `op.var` は `slot * 16` の 16-bit だが、resolver は下位 1B しか読んでなかった。slot ≥ 16 で alias が起きて `$write_row` が `$grid` を破壊する激しいバグ。`cv_addr_y` / `tmp_addr_y` ヘルパで 16-bit 化して全箇所修正
2. **CMP_TMP_COUNT が文間でリセットされない**: TMP slot 64 上限が長いプログラムで枯渇していた。`cmp_dispatch_stmt` の入口で PHA / 出口で PLA する設計に変更。1 文の中で発行された TMP slot は文境界で寿命終わるため文間で再利用できる
3. **op_array 上限なし → CMP_LIT_STAGE 領域を破壊**: `cmp_op_finish` に 16-bit bound check 追加 (`HEAD < CMP_LIT_STAGE` を SBC で評価)
4. **`nes_rand() % N` が負を返す**: rand は unsigned 16-bit を返すが PHP の `%` は被除数の符号で sign 決定するため、上位 bit 立つと負になる。tetris 側で `(nes_rand() & 0x7FFF) % N` でマスクする慣習を確立 (spec/13-compiler に明記)

### メモリレイアウト調整

PRG-RAM 8KB の中で op_array / literals / arr_pool / str_pool の境界を Phase 5b の規模に合わせて再配置:

```
$6010-$7CFF  op_array + literals (~308 op × 24 + 40 lit × 16 ≈ 8KB の 90%)
$????-$7F7F  ARR_POOL (literal 終端から成長)
$7D00-$7F7F  CMP_LIT_STAGE (compile 中、768B = 48 zval staging)
$7F80-$7FFF  STR_POOL (128B、tetris の 56byte shape data + UI 文字列を吸収)
$0700-$07FF  USER_RAM (256B、コンパイル後の CV table 領域を再利用)
```

CV table 上限も 32 → 64 に拡張 ($0700-$077F → $0700-$07FF 全域)。tetris.php Phase 5b は 33 CV 必要で、32 では足りなかった。

### 成果

`examples/tetris.php`: 7 種ピース + 4 回転 + ライン消去 + スコア + 簡易 game over。Phase 5a (286 op、$shapes 配列方式) → Phase 5b (278 op、peek16 経由) で機能増えてるのに op 減。USER_RAM の効率がよく効いた例。

`examples/peek_test.php`: peek/poke/pokestr のスモークテスト。

### 制約として残ったもの (Phase 5b 時点、Phase 5c で解消)

- ライン消去後の全面再描画 (200 cell) は op_array 不足で省略 → cleared 行が ghost として残る
- GAME OVER メッセージなし (静止のみ)
- NEXT preview / speed up は未実装 (Phase 5c へ持越)

---

## Phase W7: SXROM 標準準拠化 (PRG-ROM 64KB / CHR-RAM 8KB / PRG-RAM 32KB)

### 動機: ARR_POOL の容量プレッシャ

Phase 5b の tetris.php では bank 0 8KB のうち op_array 6.7KB + literals 640B +
header 16B + STR_POOL 128B = 7.5KB を占有し、ARR_POOL 残量が **720B (~45 zval)**。
`$grid` 20 行 = 320B でほぼ満杯、Phase 5c の全面再描画追加が op 数とメモリ両方で
収まらない状態だった。

### 設計決定の流れ

「PRG-RAM を増やしたい」という素直な欲求から始まり、対話の中で:

1. **どの mapper variant か**: SNROM (現状、8KB)、SOROM (16KB、bit 3)、SUROM (PRG-ROM 増、無関係)、SXROM (32KB、bit 2-3) を比較。SXROM で PRG-RAM を 4 倍にする路線を採用
2. **bit 衝突問題**: SXROM は CHR bank 0 reg ($A000) bit 2-3 を PRG-RAM bank に流用。bit 0-2 で 8 CHR banks 切替する現構成と衝突
3. **CHR-RAM 化を受け入れる**: 標準 SXROM は CHR-RAM 8KB のみ。CHR-RAM では bank 切替が消え bit 衝突が解消。代償は CHR 総容量 32KB → 8KB
4. **CHR データの置き場**: PRG-ROM を 64KB に拡張、bank 1 に CHRDATA 16KB (4 セット × 4KB) を置く。`nes_chr_bg/spr` は bulk transfer に変更
5. **op_array の bank 跨ぎは延期**: 当面 op_array は bank 0 8KB に収まるので、bank 跨ぎ dispatch は将来課題に

「現 nesphp は実は SNROM ではなく SIROM 相当」という気付きもあった (CHR-ROM 32KB
+ PRG-RAM 8KB + 32KB PRG-ROM の組み合わせは SIROM)。`vm/nesphp.s` の "SNROM 構成"
コメントは長らく不正確だった。

### bank 配分

```
PRG-RAM (32KB、4 × 8KB):
  bank 0: op_array + literals + ARR_POOL (旧) + STR_POOL  ← bank 0 = 現状維持
  bank 1: ARR_POOL 8KB                                    ← 配列専用
  bank 2: USER_RAM_EXT 8KB (peek/poke_ext)                ← 新規
  bank 3: 予約
```

**配置の根拠**: 「op_array 以外を bank 1 へ逃す」案 (literals/STR_POOL/ARR_POOL を
全て bank 1) は literals アクセスが毎 opcode 発生するので bank 切替コストで 30-50%
スローダウン → 却下。「配列だけ bank 外」(= 案 X) は配列が触るときだけ切替なので
overhead は 10% 程度に抑えられる。

ARR_POOL bank 切替は handler 入口で `PRG_RAM_BANK1` 出口で `PRG_RAM_BANK0` の atomic
パターン (5 つの配列 handler を全て修正)。dispatch loop には一切手を入れない。

### CHR-RAM 化の影響

- 起動時に 8KB を PRG_BANK1 → PPU $0000-$1FFF に bulk 転送 (~50 ms、L3S compile に
  比べれば誤差)
- `nes_chr_bg/spr($n)` は MMC1 register 書込から、PRG_BANK1 → PPU への 4KB bulk
  transfer に変更。`cls_sprite_mode` 同様の brief force-blanking パターン (~25 ms
  blackout / 1.5 frame) で sprite_mode/forced_blanking 両対応
- chrdemo / presen* の "BG inverse" 演出は CHR セット差替えとして引き続き機能
- tetris は `nes_chr_bg/spr` を呼ばないので影響なし

### 新 intrinsic 4 種

USER_RAM_EXT (bank 2, 8KB) アクセス用:
- `nes_peek_ext($ofs)` → byte
- `nes_peek16_ext($ofs)` → 16-bit LE
- `nes_poke_ext($ofs, $byte)` → 1 byte 書込
- `nes_pokestr_ext($ofs, $string)` → bulk copy (string max 255B、内蔵 RAM $0600 を中継)

opcode 0xE8-0xEB を割当、INT_PEEK_EXT 等を compiler.s に追加。

### Phase 5b/5c 帳尻合わせ

ARR_POOL 8KB に拡大したことで、`tetris.php` の Phase 5c (全面再描画 + GAME OVER)
が op_array に収まるようになった。ライン消去後の 200 セル走査ループは
`lineclear_test.php` のパターン (1 セルごとに " " 描画 → 必要なら "\x05" 上書き) を
流用、else 分岐を消して op 削減。

### 移行作業の刻み (8 commits)

1. FCEUX-based smoke test harness 追加 (regression detection 用)
2. PRG-ROM 32KB → 64KB (4 × 16KB bank、linker config 拡張)
3. CHR-RAM 化 (iNES CHR-ROM=0 申告、起動時 8KB bulk transfer)
4. `nes_chr_bg/spr` を bulk transfer に再実装
5. PRG-RAM 8KB → 32KB 申告 + ZP `cur_prg_ram_bank` 追加
6. ARR_POOL を bank 1 に移動 (5 handler に PRG_RAM_BANK1/0 wrap)
7. USER_RAM_EXT (bank 2) + 4 ext intrinsic 追加
8. tetris.php Phase 5c

各段階で smoke test (37/40 PASS、baseline 維持) を回し regression を防いだ。

### 性能

- bank 切替 1 回 = MMC1 シリアル書込 ~30 cycles
- 配列 handler は 2 回切替 (in/out) = ~60 cycles overhead per op
- tetris で配列アクセス ~50 回/フレーム → 3000 cyc/frame ≈ 1.7 ms ≈ 10% スロー
  ダウン (60fps→54fps、許容範囲)

### 制約として残ったもの

- op_array は bank 0 限定で **最大 308 op** のまま (bank 跨ぎ dispatch は未実装)
- bank 1 の dispatch 中アクセスは ARR_POOL のみ (op_array overflow を逃すには
  cross-bank PC 管理が必要)
- 標準 SXROM は CHR-RAM のみで CHR-ROM 構成は非標準 → 将来 64KB CHR-ROM が必要に
  なれば SOROM (CHR 8 bank 維持 + 16KB PRG-RAM のみ) に分岐するか別 mapper 検討

---

## Phase W8: STR_POOL bank 2 化と NES 2.0 ヘッダ移行

### 動機: 文字列リテラル 128B 制限が顕在化

W7 で PRG-RAM を 32KB に拡張したものの、STR_POOL は依然 bank 0 内の `$7F80-$7FFF`
**128 byte** に閉じ込められたままだった。tetris.php (UI 文字列 + shape table の
56 byte 文字列) はギリギリ収まっていたが、

- `examples/color.php` (134 byte の解説文字列) → ERR L78 C27 (行 78 でちょうど 128B
  境界を踏み越え、`cln_string` の overflow 検出で停止)
- tetris タイトル `"TETRIS"` が `EF 1F 01 00 00 00` のような bogus byte で表示

の 2 種類のバグが噴出。後者は overflow 検出が抜けていた頃の症状で、コミット
3bf8e8f (string dedup + bound check) で「描けるが ERR で止まる」状態には変わったが、
根本的に**プレゼン用ロムを書く分の容量が無い**点は解決していない。

### 案: bank 1 を全面占有する STR_POOL 専用 bank

最初に挙がったのは「STR_POOL を bank 1 ARR_POOL と同居させる」案だが、
ARR_POOL は配列 handler 単位で bank 切替する atomic 設計なので同居は破綻する
(string handler が bank 1 をマップしている隙に array op が走ると ARR_POOL が
読めない)。bank 2 を **STR_POOL 専用**にし、bank 1 = ARR_POOL / bank 2 = STR_POOL /
bank 3 = USER_RAM_EXT (W7 で bank 2 にあったものを bank 3 へずらす) という
**全 4 bank 使い切り**の構成に再配置することにした。

`vm/nesphp.s` の bank 切替対象は以下:

- `cln_string` (compile 時に decoded bytes を STR_POOL に書き込む)
- `echo_write` (`echo` で STR_POOL を読んで PPU に書き出す)
- `vec_string` (文字列等価比較)
- `np_from_string` (`nes_put` の 1-byte 切り出し)
- `handle_nesphp_nes_puts` (PPU bulk write のソース)
- `handle_nesphp_nes_pokestr` (USER_RAM 内蔵 RAM への bulk copy)
- `handle_nesphp_nes_pokestr_ext` stage 1 (STR_POOL → 内蔵 RAM。stage 2 は bank 3)

入口で `PRG_RAM_BANK2`、出口で `PRG_RAM_BANK0` を atomic に呼ぶ典型パターン。
W7 の ARR_POOL bank 切替と同じ流儀。

### 罠: FCEUX が iNES 1.0 で PRG-RAM banking を無視する

実装後、`hello.nes` の "HELLO, NES!" が `02 00 40 00 02 00 00 00 00 00 08` のような
**bank 0 op_array ヘッダ bytes** として描画された。bank 切替コードは正しいので
「FCEUX が banking 命令を無視しているのでは」と疑う。

調査の結果、**iNES 1.0 ヘッダだと FCEUX は PRG-RAM サイズを 8KB 固定として扱い、
MMC1 の bank 切替を no-op にしてしまう**ことが判明。NES 2.0 ヘッダで PRG-RAM 32KB
を明示的に申告する必要がある:

- Flags 7 = `0b00001000` (bit 2-3 = `10` → NES 2.0 marker)
- byte 10 = `$09` (PRG-RAM = 64 << 9 = 32KB volatile)
- byte 11 = `$07` (CHR-RAM = 64 << 7 = 8KB volatile)

ヘッダ書き換え後、`hello.nes` 再ビルドで `48 45 4C 4C 4F 2C 20 4E 45 53 21` =
"HELLO, NES!" が正しく描画されることを確認。続いて `color.nes` (134 byte 文字列)
も含む 41 example 中 40 個が PASS (err_syntax は意図的 fail)。

### 副産物: CMP_LIT_STAGE が 40 → 48 zval に拡大

旧 STR_POOL 領域 `$7F80-$7FFF` (128 B) が解放されたので、`CMP_LIT_STAGE_END = $8000`
に引き上げ、zval staging が 40 → 48 entries に拡大した。tetris のような literal
が多いプログラムで余裕が出る。

### 残課題

- spec/02-ram-layout.md・spec/13-compiler.md の bank 配置図を更新 (本コミットで対応)
- `cur_prg_ram_bank` ZP の用途は「次に dispatch loop 入る前にどの bank にいるか」を
  覚えるためだが、現状全 handler が出口で必ず bank 0 に戻すので**事実上 unused**。
  将来 bank 跨ぎ最適化を入れるなら活躍する余地はあるが、当面はデッドコード気味
- op_array bank 跨ぎ dispatch は未実装のままで W7 から進展なし。bank 2/3 が
  STR_POOL/USER_RAM_EXT に占有されたので、op_array > 8KB の cross-bank dispatch
  を後でやるなら**新たに bank 4 以降を増やす (= SXROM 32KB → 64KB?)** か、
  PRG-ROM bank に opcode を逃がすかの判断が必要

---

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — 現在の ROM バイナリ仕様
- [04-opcode-mapping](./04-opcode-mapping.md) — 実装済み opcode 一覧
- [07-roadmap](./07-roadmap.md) — フェーズ毎の進捗
- [09-verification](./09-verification.md) — 各デモの受け入れ基準
