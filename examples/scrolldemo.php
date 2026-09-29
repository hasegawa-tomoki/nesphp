<?php
// scrolldemo.php — ファミコンの横スクロールの仕組みデモ (PHP Conference Ehime 資料用)
//
// 画面 (256px = 32 文字) の右隣にもう 1 画面ぶんの nametable があり (vertical mirroring)、
// 2 枚で 512px のリングになっている。スクロールは PPU に「どこから表示するか」を教える
// だけで、リングの中身は勝手には変わらない。
//   STOP : 最初の状態。2 画面ぶんの絵を書いて止まっている (A でスクロール開始)
//   LOOP : リングを 1px/フレームで右にぐるぐる回すだけ (書き換えなし → 最初に書いた 2 画面が
//          繰り返す。画面の境目で文章が縦に切れているのがそのまま見える)
//   DRAW : 同じ速さで回しながら、画面の右端に入ってきた 1 列 27 文字だけを毎回書き直す →
//          行ごとに 1 文字ずれた HELLO PHP! の帯が境目なしに無限に続く。
//          本物のゲームは見えない列 (右端のすぐ外) を書くが、このデモは概念を見せるために
//          右端の列 (入ってきたばかりで見えている列) を書く。左に消えた古い列が右から入ってきて、
//          その場で新しい文字に書き換わるのが見える
//   SLOW : DRAW を 1px / 8 フレームでゆっくり (fceux の Debug > Name Table Viewer と一緒に見る)
// A ボタンでモード切替 (STOP → LOOP → DRAW → SLOW → STOP、STOP に戻ると絵も最初に戻る)。
// 左下のスプライトが現在のモード。
//
// 最初の画面: 行 r は左から (r mod 11) マス空けて文を繰り返し、右端で切る (行ごとに 1 文字ずれる)。
// DRAW が書く列: 世界列 c、行 r の文字 = "HELLO PHP! "[(c - r) mod 11] (空白なしの無限の帯)。
// 1px ずつの移動は VM の NMI (nes_cam_move) が毎フレーム行い、PHP はその間に次の列を書く。
// 1 列 (8px) = 8 フレーム ≈ 133ms の間に PHP が書けるのは ≈390 op、列 1 本 27 文字 ≈ 280 op。

nes_bg_color(0x0F);
nes_palette(0, 0x30, 0x00, 0x00);   // 白
nes_palette(1, 0x28, 0x00, 0x00);   // 黄
nes_palette(2, 0x2C, 0x00, 0x00);   // 水色
nes_palette(3, 0x25, 0x00, 0x00);   // 桃
nes_palette(4, 0x16, 0x00, 0x00);   // sprite: モード表示 (赤)
nes_chr_spr(0);                     // sprite もフォント (CHR set 0) を使う

// パレット: 2 行 (16px) ごとに 0,1,2,3 を繰り返す (attribute table は 16x16 単位)
$y = 0;
while ($y < 15) {
    $p = $y & 3;
    $x = 0;
    while ($x < 32) { nes_attr($x, $y, $p); $x = $x + 1; }   // x 0-31 = 2 画面ぶん (512px)
    $y = $y + 1;
}


// 文章は bank 3 に 4 回繰り返して置く。列 c の行 0 は index (c mod 11) + 33 から始めて
// 行ごとに 1 ずつ引く (行 26 でも index >= 7 なので mod が要らない)。
nes_pokestr_ext(0, "HELLO PHP! HELLO PHP! HELLO PHP! HELLO PHP! ");

$m = 0;          // モード 0 STOP / 1 LOOP / 2 DRAW / 3 SLOW
$w = 0;          // これまでにスクロールした列数 (= 画面左端のリング列)
$ap = 0;         // 前回の A
$hold = 0;       // この周回で A を見た (nes_btn を何度も見て取りこぼしを防ぐ)
$lb = 1;         // モード表示を描き直す
nes_scroll(0, 0);

while (true) {
    if ($lb === 1) {
        // モード表示 (sprite 0-3、y=216 の行)。sprite はスクロールしない
        if ($m === 0) { nes_sprite_at(0, 8, 215, 0x53); nes_sprite_at(1, 16, 215, 0x54); nes_sprite_at(2, 24, 215, 0x4F); nes_sprite_at(3, 32, 215, 0x50); }   // STOP
        if ($m === 1) { nes_sprite_at(0, 8, 215, 0x4C); nes_sprite_at(1, 16, 215, 0x4F); nes_sprite_at(2, 24, 215, 0x4F); nes_sprite_at(3, 32, 215, 0x50); }   // LOOP
        if ($m === 2) { nes_sprite_at(0, 8, 215, 0x44); nes_sprite_at(1, 16, 215, 0x52); nes_sprite_at(2, 24, 215, 0x41); nes_sprite_at(3, 32, 215, 0x57); }   // DRAW
        if ($m === 3) { nes_sprite_at(0, 8, 215, 0x53); nes_sprite_at(1, 16, 215, 0x4C); nes_sprite_at(2, 24, 215, 0x4F); nes_sprite_at(3, 32, 215, 0x57); }   // SLOW
        if ($m === 0) {
            // STOP: 最初の状態に戻す。スクロール 0、リング全部 (2 画面 = 64 列) を画面 0 の絵で埋める。
            // 列 32-63 が右の nametable。2 画面が同じなので LOOP は継ぎ目なしに回る。
            // 行 27-29 はモード表示用に空けておく
            nes_scroll(0, 0);
            $w = 0;
        nes_puts(0, 0, "HELLO PHP! HELLO PHP! HELLO PHP!"); nes_puts(32, 0, "HELLO PHP! HELLO PHP! HELLO PHP!");
        nes_puts(0, 1, " HELLO PHP! HELLO PHP! HELLO PHP"); nes_puts(32, 1, " HELLO PHP! HELLO PHP! HELLO PHP");
        nes_puts(0, 2, "  HELLO PHP! HELLO PHP! HELLO PH"); nes_puts(32, 2, "  HELLO PHP! HELLO PHP! HELLO PH");
        nes_puts(0, 3, "   HELLO PHP! HELLO PHP! HELLO P"); nes_puts(32, 3, "   HELLO PHP! HELLO PHP! HELLO P");
        nes_puts(0, 4, "    HELLO PHP! HELLO PHP! HELLO "); nes_puts(32, 4, "    HELLO PHP! HELLO PHP! HELLO ");
        nes_puts(0, 5, "     HELLO PHP! HELLO PHP! HELLO"); nes_puts(32, 5, "     HELLO PHP! HELLO PHP! HELLO");
        nes_puts(0, 6, "      HELLO PHP! HELLO PHP! HELL"); nes_puts(32, 6, "      HELLO PHP! HELLO PHP! HELL");
        nes_puts(0, 7, "       HELLO PHP! HELLO PHP! HEL"); nes_puts(32, 7, "       HELLO PHP! HELLO PHP! HEL");
        nes_puts(0, 8, "        HELLO PHP! HELLO PHP! HE"); nes_puts(32, 8, "        HELLO PHP! HELLO PHP! HE");
        nes_puts(0, 9, "         HELLO PHP! HELLO PHP! H"); nes_puts(32, 9, "         HELLO PHP! HELLO PHP! H");
        nes_puts(0, 10, "          HELLO PHP! HELLO PHP! "); nes_puts(32, 10, "          HELLO PHP! HELLO PHP! ");
        nes_puts(0, 11, "HELLO PHP! HELLO PHP! HELLO PHP!"); nes_puts(32, 11, "HELLO PHP! HELLO PHP! HELLO PHP!");
        nes_puts(0, 12, " HELLO PHP! HELLO PHP! HELLO PHP"); nes_puts(32, 12, " HELLO PHP! HELLO PHP! HELLO PHP");
        nes_puts(0, 13, "  HELLO PHP! HELLO PHP! HELLO PH"); nes_puts(32, 13, "  HELLO PHP! HELLO PHP! HELLO PH");
        nes_puts(0, 14, "   HELLO PHP! HELLO PHP! HELLO P"); nes_puts(32, 14, "   HELLO PHP! HELLO PHP! HELLO P");
        nes_puts(0, 15, "    HELLO PHP! HELLO PHP! HELLO "); nes_puts(32, 15, "    HELLO PHP! HELLO PHP! HELLO ");
        nes_puts(0, 16, "     HELLO PHP! HELLO PHP! HELLO"); nes_puts(32, 16, "     HELLO PHP! HELLO PHP! HELLO");
        nes_puts(0, 17, "      HELLO PHP! HELLO PHP! HELL"); nes_puts(32, 17, "      HELLO PHP! HELLO PHP! HELL");
        nes_puts(0, 18, "       HELLO PHP! HELLO PHP! HEL"); nes_puts(32, 18, "       HELLO PHP! HELLO PHP! HEL");
        nes_puts(0, 19, "        HELLO PHP! HELLO PHP! HE"); nes_puts(32, 19, "        HELLO PHP! HELLO PHP! HE");
        nes_puts(0, 20, "         HELLO PHP! HELLO PHP! H"); nes_puts(32, 20, "         HELLO PHP! HELLO PHP! H");
        nes_puts(0, 21, "          HELLO PHP! HELLO PHP! "); nes_puts(32, 21, "          HELLO PHP! HELLO PHP! ");
        nes_puts(0, 22, "HELLO PHP! HELLO PHP! HELLO PHP!"); nes_puts(32, 22, "HELLO PHP! HELLO PHP! HELLO PHP!");
        nes_puts(0, 23, " HELLO PHP! HELLO PHP! HELLO PHP"); nes_puts(32, 23, " HELLO PHP! HELLO PHP! HELLO PHP");
        nes_puts(0, 24, "  HELLO PHP! HELLO PHP! HELLO PH"); nes_puts(32, 24, "  HELLO PHP! HELLO PHP! HELLO PH");
        nes_puts(0, 25, "   HELLO PHP! HELLO PHP! HELLO P"); nes_puts(32, 25, "   HELLO PHP! HELLO PHP! HELLO P");
        nes_puts(0, 26, "    HELLO PHP! HELLO PHP! HELLO "); nes_puts(32, 26, "    HELLO PHP! HELLO PHP! HELLO ");
        }
        $lb = 0;
    }

    if ($m === 0) {
        // STOP: 何もせず A を待つ
        nes_vsync(); $k = nes_btn(); $hold = $hold | $k;
    }
    if ($m > 0) {
        // ---- 1 列 (8px) ぶんスクロール ----
        if ($m === 3) {
            // SLOW: 1px 動かして 7 フレーム待つ、を 8 回
            $p = 0;
            while ($p < 8) {
                nes_cam_move(1, 0, 1);
                $v = 0;
                while ($v < 7) { nes_vsync(); $k = nes_btn(); $hold = $hold | $k; $v = $v + 1; }
                $p = $p + 1;
                // 1 列に 1 秒かかるので、A はここでも判定して待たせない (SLOW の次は STOP)
                $hold = $hold & 128;
                $ae = 128 - $ap;
                $ae = $ae & $hold;
                $ap = $hold;
                $hold = 0;
                if ($ae === 128) { $m = 0; $lb = 1; $p = 8; }
            }
        } else {
            // LOOP / DRAW: NMI が 8 フレームかけて 1px ずつ動かす (この関数はすぐ戻る)
            nes_cam_move(1, 0, 8);
        }
        $w = $w + 1;
        if ($w === 3520) { $w = 0; }        // 64 (リング) と 11 (文の長さ) の公倍数で折り返す

        if ($m === 1) {
            // LOOP: 書き換えなし。次の列が来るまで A だけ見る
            $v = 0;
            while ($v < 6) { nes_vsync(); $k = nes_btn(); $hold = $hold | $k; $v = $v + 1; }
        } else {
            // DRAW / SLOW: 画面の右端の列 (リング列 (w+31) & 63) に、世界列 w+31 の列を書く。
            // (見えないうちに書くなら w+32。ここでは書き換えを見せるためにわざと画面内に書く)
            // 行 r の文字 = 文[(c - r) mod 11] なので、行を下るごとに index を 1 ずつ引く
            $c = $w + 31;
            $i = $c % 11;
            $i = $i + 33;
            $x = $c & 63;                       // リング上の列 (0-63)
            $r = 0;
            while ($r < 13) {                   // 前半 13 行
                $ch = nes_peek_ext($i); nes_put($x, $r, $ch); $i = $i - 1;
                $r = $r + 1;
            }
            $k = nes_btn(); $hold = $hold | $k;  // 途中で A を見る (取りこぼし防止)
            while ($r < 27) {                   // 後半 14 行
                $ch = nes_peek_ext($i); nes_put($x, $r, $ch); $i = $i - 1;
                $r = $r + 1;
            }
            $k = nes_btn(); $hold = $hold | $k;
        }
    }

    // ---- A の立ち上がりでモード切替 ----
    $hold = $hold & 128;
    $ae = 128 - $ap;
    $ae = $ae & $hold;
    $ap = $hold;
    $hold = 0;
    if ($ae === 128) {
        $m = $m + 1;
        if ($m === 4) { $m = 0; }
        $lb = 1;
    }
}
