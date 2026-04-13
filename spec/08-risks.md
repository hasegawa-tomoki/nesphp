# 08. 主要リスクと緩和策

[← README](./README.md) | [← 07-roadmap](./07-roadmap.md) | [→ 09-verification](./09-verification.md)

## リスク一覧

| # | リスク | 影響 | 緩和策 |
|---|--------|------|--------|
| 1 | Zend opcode 番号の PHP バージョン間変動 | シリアライザが出すバイナリが動かない | PHP 8.4 に version lock。opcache ダンプ先頭の `(PHP X.Y.Z)` 行をパースして一致確認、不一致なら serializer が abort。VM 側は op_array header の `php_version_major/minor` を起動時に確認 |
| 2 | `zend_op` レイアウトが PHP ビルド設定 (ZTS/NTS, 32/64bit, debug/release) で変動 | 24B 構造体レイアウトが崩れる | 対応するのは **NTS x64 PHP 8.4 リリースビルド** (macOS `brew install php`) のみ。`spec/README.md` に明記 |
| 3 | 2KB RAM が狭すぎる | VM が早期に RAM 枯渇 | ゼロページに VM レジスタを集約、動的アロケーションゼロ、RAM マップを [02-ram-layout](./02-ram-layout.md) で決め打ち。16B zval は ROM 内のみ、RAM は 4B tagged に縮退 |
| 4 | PHP の 64bit 整数・double・配列・オブジェクト | セマンティクスを守れない | **切る**。IS_LONG は 16bit に narrow、double/配列/オブジェクトは serializer で compile error。[00-overview](./00-overview.md) の「やらないこと」で明示 |
| 5 | 可変長文字列と GC | ヒープ管理が必要になる | MVP は ROM 内 `zend_string` のみ (immutable)。`ZEND_CONCAT` 導入時は固定 256B バッファ 1 本方式で GC 不要 ([06-display-io](./06-display-io.md)) |
| 6 | Zend opcode 200+ を全て揃えたくなる誘惑 | 実装量爆発 | MVP は 2 opcode、延長で合計 20 opcode と決め打ち。未対応は handle_unimpl でフォールバック ([04-opcode-mapping](./04-opcode-mapping.md)) |
| 7 | opcache テキストダンプの書式が PHP リリース間で微変動 | シリアライザのパースが壊れる | MVP が動いたら早期に自作拡張 `nesphp_dump.so` に昇格し、テキストパース層を殺す。その間は regex を粗結合に保つ |
| 8 | PPU タイミング (実行中の nametable 書き込みは壊れる) | 画面がグリッチる | MVP は強制 blanking 中 (`$2001=0`) にのみ書き込む。延長段階で VBlank 転送方式に昇格 ([06-display-io](./06-display-io.md)) |
| 9 | コントローラの DPCM グリッチ | 入力がたまに壊れる | NESdev Wiki のリトライ付き読み取りルーチンをそのまま使う |
| 10 | Zend はレジスタマシン、6502 は素朴 | 変換ロジックが複雑になる | ハンドラは op1_type/op2_type で `resolve_op1/op2` resolver を呼び、どの種別でも統一的にフェッチできる作り。速度より実装量を優先 |
| 11 | 自作拡張が PHP ABI 更新で壊れる | 第 2 段階の再ビルド必要 | `PHP_API_VERSION` でコンパイル時ガード。動作確認 PHP バージョンを `nesphp_dump/README.md` に明記 |
| 12 | バンクスイッチの要否 | 32KB を超えたら動かない | MVP は NROM 32KB で十分。延長ゴールで溢れたら UxROM に昇格 (VM を固定バンク、op_array を切替バンク) |
| 13 | 実機とエミュレータの挙動差 | 実機で動かない | 主に Mesen でデバッグ (精度が高い)、最後に FCEUX と Everdrive で確認 |
| 14 | PHP ソースの非 ASCII 文字 | NES フォントに入らず文字化け | serializer で非 ASCII literal を検出したら compile error |
| 15 | Zend の TMP_VAR / VAR / CV のオフセット解釈が PHP バージョンで変動 | operand resolver が壊れる | `spec/03-vm-dispatch.md` の resolver を PHP 8.4 に合わせて実装、version lock で他バージョン拒否 |
| 16 | 文字列プールが PRG-ROM 容量を超える | ビルド失敗 | serializer がサイズチェックし、超えたら compile error。将来的に UxROM 昇格で解決 |
| 17 | 6502 の 16bit 演算が遅い (`ZEND_MUL` 等) | 実時間で破綻 | 乗除は最後に実装、除算は必要に応じて省略 |

---

## 最重要リスクの深掘り

### PHP バージョンロックの徹底

このプロジェクト最大のリスクは **「PHP 8.3 で書いたコードが 8.4 で動かない」ような相互運用性問題**ではなく、**「動いていた 8.4 が 8.5 では opcode 番号が変わって壊れる」こと**。

#### 対策の多層化

1. **serializer 側**: `php -v` を内部から実行し、8.4 でなければ abort
2. **opcache ダンプパーサ**: ダンプ先頭の `(PHP X.Y.Z)` コメント行 (opcache が出す) を確認
3. **VM 側 (ROM)**: op_array header の `php_version_major/minor` を起動時に確認、不一致なら halt 画面
4. **ドキュメント**: `spec/README.md` の動作確認欄に明記。CI を組む場合は 8.4.x を pin

### RAM 2KB の綱渡り

[02-ram-layout](./02-ram-layout.md) の RAM マップは MVP + 延長第 1 段階までは余裕があるが、延長第 5 段階 (スプライト) で OAM シャドウ 256B が必須になる。さらにその先 (配列等) を実装しようとすると確実に破綻する。

**方針**: 配列は **絶対に実装しない**。代わりに「複数変数を使う PHP」と「関数呼び出しベースのハードウェア制御」で表現する。

### 未実装 opcode に対するユーザ体験

ユーザが `echo [1, 2, 3];` のような配列コードを書いた時、どこでエラーになるかを明確にする:

1. serializer が `ZEND_INIT_ARRAY` を検出
2. 未対応 opcode として compile error、`hello.php:1: unsupported opcode ZEND_INIT_ARRAY (arrays are not supported in nesphp)` のようなメッセージ
3. ビルド abort

「ビルドは通ったが NES で動かない」状況を作らない。

---

## リスクを受け入れる決断

以下は **修正しないリスク** (ロマンを守るため):

- **実用には使えない**: PHP の大半の機能が使えないので Web 開発等には無意味
- **速度は出ない**: 6502 で解釈実行なので 1 秒あたり 1000 opcode 程度。本気の PHP より 1000 万倍遅い
- **PHP の深いセマンティクス (type juggling 等) は再現しない**: 必要最小限の挙動のみ

これらは「ネタプロジェクト」という前提を受け入れる。

---

## 関連ドキュメント

- [00-overview](./00-overview.md) — 「やらないこと」の詳細
- [02-ram-layout](./02-ram-layout.md) — RAM 2KB の具体的な配分
- [05-toolchain](./05-toolchain.md) — PHP バージョンロックの実装手段
- [09-verification](./09-verification.md) — リスクを検出するテスト項目
