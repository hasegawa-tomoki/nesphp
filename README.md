# 基本仕様

* 6502でPHP opcodeを実行するPHP VM。
* フル機能は不要。別マシンでphpコマンドからopcodeを吐き出し、それを実行する
* opcodeは一部の実装で良い
  * mvpではechoのみ実装
  * その後の延長ゴールで以下を実装
    * 制御構造(if, loop系）
    * 標準入力からの入力
    * ファミコンのコントローラーボタンを標準入力からの文字列として取り扱う
    * スプライトの実装
      * PHPからどのようにスプライト関連の命令のopcodeを出すか要検討
      * PHP拡張を作って命令を増やす？
* 最終的にはファミコン上で実行する
  * ファミコンで実行できる .nes ファイルを作る
* 延長ゴール:
  * echoで画面に文字を吐き出し、コントローラ入力で文字を上下左右に動かしたりボタンで文字を変更したりするところをひとまずのゴールにする
  * 同様にスプライトを動かす

## License

MIT License. See [LICENSE](./LICENSE).

### PHP compatibility note

This project references Zend VM opcode numbers and struct layouts (`zend_op`, `zval`, `zend_string`) from PHP 8.4 source for binary interoperability. No PHP source code is included or redistributed.

### Trademarks

"NES", "Famicom", and "Nintendo" are trademarks of Nintendo. This project is not affiliated with, endorsed by, or sponsored by Nintendo.
