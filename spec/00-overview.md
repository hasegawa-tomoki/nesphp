# 00. プロジェクト概要

[← README](./README.md)

## 目的

実用ではなく**ロマン**。「我々が使っている `php` コマンドが実際に吐いた Zend opcode を、ファミコン (6502) で実行する」こと自体がゴール。

## 成功の定義

- `<?php echo "HELLO, NES!";` を含む `.php` を入力すると `.nes` が出来上がる
- Mesen で起動すると画面に `HELLO, NES!` が表示される
- `strings hello.nes` で `HELLO, NES!` がヒットする (PHP ソースの文字列が NES ROM 内にそのまま存在する)
- `xxd hello.nes` で ZEND_ECHO の opcode バイト列 (`28 01 08 08`) がヒットする (Zend 互換番号)

詳細な受け入れ基準は [09-verification](./09-verification.md) を参照。

## 3 層アーキテクチャ

```
[ホスト (macOS)]                                [ターゲット (NES)]
 input.php
   │
   ▼  ★ここが実 php コマンド
 php -dopcache.enable_cli=1
     -dopcache.opt_debug_level=0x10000 ...
   │  (第2段階では自作拡張 nesphp_dump.so)
   ▼
 Zend opcode ダンプ (テキスト or バイナリ)
   │
   ▼  serializer.php : Zend op_array → L3 ROM バイナリ
   │    - zend_op を 24B にパック (handler 除去)
   │    - literals を 16B zval 配列に配置
   │    - zend_string を 24B ヘッダ + content に配置
   │    - CONST offset を NES ROM 内相対オフセットに解決
 ops.bin (L3 ROM イメージ)
   │
   ▼  ca65 + ld65 (.incbin "ops.bin")
 nesphp.nes ──────────────────────────▶  6502 VM
                                          - PC を op[i] に進める
                                          - opcode バイトで jump table 分岐
                                          - op1_type で operand 解釈切替
                                          - CONST → literals[] → zend_string → PPU
```

### 各層の責務

| 層 | 役割 |
|----|------|
| 層 0 (Zend) | 実 php が PHP ソースを公式コンパイル。`zend_op_array` を生成。**完全に無改造** |
| 層 1 (抽出) | opcache テキストダンプ (MVP) / 自作拡張 (第 2 段階) で `zend_op_array` を取り出す |
| 層 2 (シリアライザ) | Zend レイアウトを NES ROM 向けに「ポインタ解決 + handler 除去 + version lock」でパック。**レイアウトは Zend 互換のまま** |
| 層 3 (6502 VM) | ca65 アセンブリ。opcode バイトで jump table 分岐、op1_type/op2_type で operand 解釈切替 |

詳細は [05-toolchain](./05-toolchain.md)。

### L3S (self-hosted) バリアント

**L3S はホスト側の層 0-2 を NES 側に取り込む**。PHP ソースを生テキストのまま ROM に焼き、電源 ON で 6502 自身が lex/parse/codegen する:

```
[ホスト (macOS)]                              [ターゲット (NES)]
 input.php
   │
   ▼ tools/pack_src.php (~15 行、薄皮)
   │    u16 length を前置するだけ
 input.src.bin
   │
   ▼ ca65 + ld65
   │    src.bin を .segment "PHPSRC" に焼く
 output.nes ────────────────────────────▶  reset
                                              │
                                              ▼ compile_and_emit (6502)
                                              │  - lex <?php echo "..." ;
                                              │  - emit 24B zend_op / 16B zval
                                              │    (zend_string は使わず zval に
                                              │     ROM offset + length を直接埋め込む)
                                              │
                                              ▼ VM main_loop で実行
```

層 0-2 が NES 側の `vm/compiler.s` に集約される。zend_string 省略の理由や byte レベル仕様は [13-compiler](./13-compiler.md) と [12-zend-diff](./12-zend-diff.md) 改変 10 を参照。

## 忠実度レベル: L3 / L3S

| 段階 | 内容 | 採用 |
|------|------|------|
| L1 | 独自 nesphp-bc に翻訳。opcode 番号・operand 符号化・zval 全て独自 | × (ロマン不足) |
| **L3** | **Zend の `zend_op` 構造体を handler 抜きで ROM にそのまま焼く。literals は 16B zval のまま。6502 VM が Zend のフィールドオフセットを直読み**。PHP ソースはホスト側 `serializer.php` が opcode にコンパイルして ROM に焼く | **○** (host-compile 経路) |
| **L3S** | **L3 の発展。PHP ソースを ROM に生で焼き、NES 起動時に 6502 自身が lex/parse/codegen。zend_string 構造体は省略し、zval に (ROM offset, length) を直接埋め込む**。詳細は [13-compiler](./13-compiler.md) | **○** (self-hosted 経路、`make build/X.nes` がデフォルト) |
| L4 | L3 + zval 16B もそのまま RAM、IS_LONG 64bit 完全再現 | × (2KB RAM 不足) |

L3 と L3S は**並存**。ホスト側 `serializer.php` は検証オラクルとして残置し、`make build/X.host.nes` で L3 経路のビルドも可能。詳細は [01-rom-format](./01-rom-format.md) と [02-ram-layout](./02-ram-layout.md) と [13-compiler](./13-compiler.md)。

## やらないこと (明示的に諦めるもの)

物理的・実装コスト的に不可能なので、serializer で検出次第 compile error にする:

- **配列 (`HashTable`)**: 56B + bucket 36B、ファミコン RAM に入らない
- **オブジェクト**: `HashTable` を内包、同様に不可能
- **`double` (IEEE 754)**: softfloat ルーチン 1-2KB、諦めた方が幸せ
- **`IS_LONG` の完全な 64bit 再現**: **16bit に narrow**、範囲外リテラルは serializer で早期 compile error
- **例外処理 / generator / closure**
- **nikic/php-parser 経由の独自バイトコード**: ロマン評価を損ねるので不採用

## 先行事例

- [Ice-Forth](https://github.com/RussellSprouts/ice-forth) — NES 上の自己ホスト Forth。6502 で ~6000 行。L3 の nesphp VM ~1200 行は十分ペイする規模
- [Family BASIC](https://ja.wikipedia.org/wiki/%E3%83%95%E3%82%A1%E3%83%9F%E3%83%AA%E3%83%BC%E3%83%99%E3%83%BC%E3%82%B7%E3%83%83%E3%82%AF) — 任天堂公式の NES 上 BASIC。2KB RAM + カートリッジ RAM で BASIC が動いた実例

## 次に読む

→ [01-rom-format](./01-rom-format.md): ROM バイナリフォーマット (Zend 互換レイアウト詳細)
