# nesphp 仕様書

6502 (ファミコン) 上で、実際の `php` コマンドが吐いた Zend opcode を実行する PHP VM。実用ではなくロマン重視。

## 動作確認バージョン

- **PHP: 8.4.x** (version lock 必須、根拠は [05-toolchain](./05-toolchain.md))
- cc65: `brew install cc65`
- 開発ホスト: macOS (NTS x64 PHP ビルド前提)
- エミュレータ: Mesen (PPU/CPU 精度優先)

## 目次

| # | ファイル | 内容 |
|---|---|---|
| 0 | [00-overview](./00-overview.md) | プロジェクト方針、3 層アーキテクチャ、L3 採用理由、やらないこと |
| 1 | [01-rom-format](./01-rom-format.md) | L3 ROM バイナリフォーマット (Zend 互換)、hex dump 例 |
| 2 | [02-ram-layout](./02-ram-layout.md) | WRAM マップ、ゼロページ、4B tagged value |
| 3 | [03-vm-dispatch](./03-vm-dispatch.md) | 6502 VM fetch-dispatch 設計、jump table |
| 4 | [04-opcode-mapping](./04-opcode-mapping.md) | Zend opcode → ハンドラ対応表 (MVP + 延長) |
| 5 | [05-toolchain](./05-toolchain.md) | 抽出、シリアライザ、ビルドパイプライン |
| 6 | [06-display-io](./06-display-io.md) | PPU 表示、コントローラ入力、スプライト |
| 7 | [07-roadmap](./07-roadmap.md) | MVP / 延長ゴール実装ステップ |
| 8 | [08-risks](./08-risks.md) | 主要リスクと緩和策 |
| 9 | [09-verification](./09-verification.md) | 受け入れ基準とロマン検証 |

## 最短読み方

初めて読む場合は `00-overview` → `01-rom-format` → `09-verification` の順で、設計思想 → 実体 → 成功条件が掴めます。実装を始める場合は追加で `02-ram-layout` `03-vm-dispatch` `07-roadmap` を読んでください。
