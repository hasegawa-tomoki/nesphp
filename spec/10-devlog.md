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

## 関連ドキュメント

- [01-rom-format](./01-rom-format.md) — 現在の ROM バイナリ仕様
- [04-opcode-mapping](./04-opcode-mapping.md) — 実装済み opcode 一覧
- [07-roadmap](./07-roadmap.md) — フェーズ毎の進捗
- [09-verification](./09-verification.md) — 各デモの受け入れ基準
