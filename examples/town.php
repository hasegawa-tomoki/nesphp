<?php
// ドラクエ風の街 (スクロール + 4 方向勇者 + A ボタンで扉/宝箱/町人)
//
// データ: examples/town_map.php を require で取り込む (map-edit/index.html が出力、手で編集
//         しない。require はホスト側 tools/pack_src.php がインライン展開する)。
//         マップ / NPC / 宝箱 / メッセージ / グリフの本体は examples/town.data.bin
//         (PRG-ROM bank 2 = GAMEDATA)。起動時に nes_rom_copy で先頭 8KB を PRG-RAM bank 3 に
//         展開し nes_peek_ext で読む。配列リテラルは 1 要素 1 op で op 上限 (617) を食うため。
//   bank 3 レイアウト (map-edit/export.js が作る):
//     0     .. : マップ 1 byte/マス。0x40 + 種類、通行可なら 0x60 + 種類 (bit 5)
//     4080  .. : 種類 → BG パレット表 16 byte (nes_map_cfg が読む)
//     4096  .. : オブジェクト [x, y, 種類, msg, パレット] 5 byte。種類 0xFF = 宝箱 (sprite なし)
//     4864  .. : メッセージ 1 件 84 byte: [グリフ ROM offset lo, hi][グリフ数][予備] + 3 行 × 26 byte
//                (タイル番号列、0 終端。ASCII は常駐フォント、日本語はグリフスロット 0xC0-0xF7)
//   ROM bank 2 の 8192 以降: グリフ (16 byte/タイル)。窓を開くとき nes_chr_copy で CHR-RAM へ
//
// 画面構成:
//   * マップは 16x16 px のメタタイル。種類 t のタイルは CHR 0x88 + t*4 から 2x2。
//     矩形の描画は VM の nes_map_rect (bank 3 のマップを直接読む) に任せる。
//     PHP で nes_put を並べると矩形描画だけで約 70 op を食い、op 上限 (617) に収まらない。
//   * カメラ (cx, cy) は 16x15 メタタイルの表示窓の左上。勇者を中央に保ち、マップ端では
//     クランプする。nametable は横 2 枚 (64 列) を横スクロールに使い、縦は 30 行 = 240px
//     で wrap する。マップ座標 → nametable: 列 = (mx*2) & 63、行 = (my*2) % 30。
//   * 1 歩 = 8px × 2 半歩。各半歩は nes_cam_move が NMI 側で毎フレーム $sp px ずつ scroll と
//     NPC sprite をずらす (VM の速度に関係なく滑らか)。横は隠れている隣の nametable に
//     入ってくる列を歩き始めに書く。縦は上下 8 行のオーバースキャン (TV/fceux では非表示)
//     に入ってくるタイル行を各半歩の前に書く (ファミコンの一般的なやり方)。縦の行は
//     nes_map_cfg のモード (上段だけ / 下段だけ、attr 有無) で 1 タイル行に絞る。
//     カメラがマップ端で止まっているときは勇者 sprite の方を動かす (nes_cam_move の bit 8)。
//   * NPC の sprite は nes_obj_draw (VM) がレコードから一括配置する。
//   * メッセージ窓は画面下 (行 20-27)。開くと窓のブロックをパレット 0 にし、そのメッセージの
//     日本語グリフを CHR-RAM (タイル 0xC0-0xF7) に転送してから文字を 1 文字ずつ置く。
//     窓に重なる sprite (画面 y >= 145) だけ隠し、閉じるときにその範囲のメタタイルを描き直して
//     sprite も戻す。
//   * on-NES コンパイラの制約: 関数なし / op 上限 617 / ネスト 7 段 (elseif は 2 段消費) /
//     「(式) 演算子 ...」の形は不可 (「リテラル 演算子 (式)」は可) / && || は 1 個 5 op /
//     nes_map_rect の 4 引数目は CV 変数のみ。
//
// 操作: 十字キー = 歩く (押しっぱなしで連続)、A = 目の前の扉を開ける / 宝箱を調べる /
//       町人と話す。メッセージ表示中は A で閉じる。

nes_bg_color(0x0F);
nes_palette(0, 0x30, 0x10, 0x00);   // 石 (石壁, 階段, 鉄格子, 窓)
nes_palette(1, 0x27, 0x26, 0x06);   // レンガ床, 木製品
nes_palette(2, 0x27, 0x1A, 0x0A);   // 草, 木, みかんの象 (橙)
nes_palette(3, 0x30, 0x21, 0x13);   // 水, ベッド, PHP ロゴ (紫)
nes_palette(4, 0x30, 0x21, 0x0F);   // 勇者, 兵士の体 (水色の鎧)
nes_palette(5, 0x36, 0x28, 0x0F);   // ジェンヌ・女性の頭 (金髪)
nes_palette(6, 0x36, 0x11, 0x0F);   // 町人, 若者 (青), 兵士の頭 (青い兜)
nes_palette(7, 0x36, 0x25, 0x0F);   // ジェンヌ, 女性の体 (桃色の服)

require 'town_map.php';
nes_map_cfg($MW, 0);                // マップ幅 + パレット表 (bank 3 の 4080) を VM に渡す

// 勇者: マップ座標 (hx, hy: town_map.php が初期値を与える)、ピクセル (hpx, hpy)、向き d: 0=上 1=右 2=下 3=左 と (dx, dy)、歩行フレーム f
$d = 2;
$dx = 0;
$dy = 1;
$f = 0;
$hpx = $hx << 4;
$hpy = $hy << 4;

// カメラ (メタタイル cx, cy / ピクセル cpx, cpy)
$cx = $hx - 7;
if ($cx < 0) { $cx = 0; }
if ($cx > $MW - 16) { $cx = $MW - 16; }
$cy = $hy - 7;
if ($cy < 0) { $cy = 0; }
if ($cy > $MH - 15) { $cy = $MH - 15; }
$cpx = $cx << 4;
$cpy = $cy << 4;
nes_scroll($cpx & 511, $cpy % 240);

// 状態
$rx = 0; $ry = 0; $rw = 16; $rh = 15;   // 描き直す矩形 (カメラ相対メタタイル)、rh > 0 で実行
$rm = 0;                                // nes_map_cfg のモード (縦スクロール用): 5 = 上段のみ attr なし, 6 = 下段のみ attr なし
$rd = 1;                                // 1 = sprite (勇者 + NPC) を位置から描き直す
$rt = 0;                                // 1 = 勇者のタイル (向き / 歩行フレーム) だけ差し替える
$fl = 0;                                // 1 = nes_cam_move の補間が進行中 (次の歩き出し前に nes_cam_wait)
$ms = 0;                                // 歩行: 2 = 前半 8px, 1 = 後半 8px, 0 = 待機
// 歩く速さは 2 px/フレーム (8 フレームで 1 歩)。1 px にするなら nes_cam_move の $dx * 2 / $dy * 2 を $dx / $dy に、$fr = 4 を 8 に
$h1 = 1; $h15 = 15;                     // nes_map_rect の 4 引数目は変数限定
$pf = 9;                                // 先読み済みの列/行の向き (cdx + cdy*2、9 = なし)
$win = 0;                               // 1 = メッセージ窓を表示中
$wo = 0;                                // 1 = 窓を開く要求
$msg = 0;
$ap = 0;                                // 前フレームの A (0 / 128)
$cdx = 0; $cdy = 0;

while (true) {
    // ---- (1) マップ矩形の描き直し (初期描画 / スクロールで入ってくる列・行 / 窓を閉じる / 扉) ----
    if ($rh > 0) {
        nes_map_rect($cx + $rx, $cy + $ry, $rw, $rh);
        nes_map_cfg($MW, 0);            // モードを通常 (2x2 + attr) に戻す
        $rh = 0;
    }

    // ---- (2) sprite: 勇者のタイル (rt) / 位置と NPC (rd) ----
    if ($rd | $rt) {
        // 向きと歩行フレームからタイル基点 b、左右入替 sw、attr j (0x40 = 水平反転)
        $b = 0x80 + ($f * 40);                      // 正面 A/B = 0x80/0xA8
        $sx = 0;                                    // sx = 左右入替フラグ (一時、左右向きだけ)
        if ($d === 0) { $b = 0x84 + ($f * 40); }    // 後ろ A/B = 0x84/0xAC
        if ($d === 3) { $b = 0x88 + ($f << 2); $sx = 0; }
        if ($d === 1) { $b = 0x88 + ($f << 2); $sx = 1; }
        $j = 0;
        $t0 = $b;
        $t1 = $b + 1;
        if ($sx === 1) { $j = 64; $t0 = $b + 1; $t1 = $b; }
        nes_sprite_tile(0, $t0); nes_sprite_tile(1, $t1); nes_sprite_tile(2, $t0 + 2); nes_sprite_tile(3, $t1 + 2);
        nes_sprite_attr(0, $j); nes_sprite_attr(1, $j); nes_sprite_attr(2, $j); nes_sprite_attr(3, $j);
        $rt = 0;
    }
    if ($rd === 1) {
        // 位置は補間が終わってから (補間中は NMI が sprite を動かしているので触らない)
        $sx = $hpx - $cpx;
        $sy = $hpy - $cpy - 1;
        nes_sprite_at(0, $sx, $sy, 0); nes_sprite_at(1, $sx + 8, $sy, 0);
        nes_sprite_at(2, $sx, $sy + 8, 0); nes_sprite_at(3, $sx + 8, $sy + 8, 0);
        nes_sprite_tile(0, $t0); nes_sprite_tile(1, $t1); nes_sprite_tile(2, $t0 + 2); nes_sprite_tile(3, $t1 + 2);
        nes_obj_draw($cpx, $cpy, $NPC_N);     // NPC は VM がレコードから一括配置
        $rd = 0;
    }

    if ($ms === 0) { nes_vsync(); }                 // 待機中だけ 1 フレーム刻み (歩行中は補間が刻む)

    // 状態を 1 つ選ぶ (elseif 連鎖はネスト段数を消費するので平坦な if に分ける)
    $st = 5;                                        // 待機中 (入力)。歩きの後半の補間中にも走る
    if ($win === 1) { $st = 4; }                    // 窓表示中
    if ($wo === 1) { $st = 3; }                     // 窓を開く
    if ($ms > 0) { $st = 2; }                       // 歩行中 (前半 / 後半の開始処理)

    if ($st === 2) {
        // ---- (3) 歩き: 半歩 (8px) ごとに nes_cam_move (NMI が毎フレーム $sp px 進める) ----
        $fr = 4;                                    // 2 px × 4 フレーム = 半歩
        if ($cm === 0) { $fr = 260; }               // カメラ固定 (マップ端): 勇者 sprite を動かすモード (bit 8)
        if ($ms === 2) {
            // 前半。前の歩きの補間が残っていれば待つ (連続歩行ではここでつながる)
            nes_cam_wait();
            if ($fl === 1) { $fl = 0; nes_scroll($cpx & 511, $cpy % 240); }   // shadow 再同期
            $ry = 15; $rm = 5;
            if ($cdy < 0) { $ry = 0 - 1; $rm = 6; }
            // 入ってくる列/行の 1 枚目。同じ向きで先読み済みなら省略。横は列が画面のすぐ外に
            // あるので NMI キューが流れ切る 2 フレームを待つ。縦の行は隠れ帯にあり、動き出しても
            // 4 フレームは隠れたまま (上下 8 行の帯を抜けて反対側の帯に回る) なので待たない
            $tx = $cdy << 1;
            $tx = $tx + $cdx;
            if ($tx !== $pf) { $pf = 9; }
            // rx は先読みの有無にかかわらず毎回設定する。扉や窓の描き直しが rx を書き換えるので、
            // 先読み済みで下の分岐を飛ばすと古い rx で先読み列が別の列に書かれ、端の列が抜ける
            $rx = 16;
            if ($cdx < 0) { $rx = 0 - 1; }
            if ($pf === 9) {
                if ($cdx !== 0) {
                    nes_map_rect($cx + $rx, $cy, 1, $h15);
                    nes_cam_move(0, 0, 2);
                }
                if ($cdy !== 0) {
                    nes_map_cfg($MW, $rm);
                    nes_map_rect($cx, $cy + $ry, 16, $h1);
                    nes_map_cfg($MW, 0);
                }
            }
            nes_cam_move($dx * 2, $dy * 2, $fr);        // 前半 8px (待たずに戻る)
            // 横なら次の列をこの間に先読み (画面外の隣の nametable なので無害)
            $pf = 9;
            if ($cdx !== 0) {
                $tx = $cx + $cdx + $cdx;
                $pf = $cdx;
                if ($tx < 0) { $pf = 9; }
                if ($tx > $MW - 16) { $pf = 9; }
                if ($cm === 0) { $pf = 9; }
                if ($pf !== 9) { nes_map_rect($cx + $rx + $cdx, $cy, 1, $h15); }
            }
            $f = 1 - $f;
            $rt = 1;                                // 歩行フレーム切替 (次の周回で描く)
            $ms = 1;
        } else {
            // 後半。前半の補間が終わるのを待ってから 2 枚目の行を書く
            nes_cam_wait();
            if ($cdy !== 0) {
                nes_map_cfg($MW, 7 - $rm);          // 反対側のタイル行 + attr (5→2, 6→1)
                nes_map_rect($cx, $cy + $ry, 16, $h1);
                nes_map_cfg($MW, 0);
            }
            nes_cam_move($dx * 2, $dy * 2, $fr);        // 後半 8px (待たずに戻る = この間に次の入力判定)
            $fl = 1;
            $hx = $hx + $dx;
            $hy = $hy + $dy;
            $cx = $cx + $cdx;
            $cy = $cy + $cdy;
            $hpx = $hx << 4;
            $hpy = $hy << 4;
            $cpx = $cx << 4;
            $cpy = $cy << 4;
            $f = 1 - $f;
            $rt = 1;
            $ms = 0;
        }
    }
    if ($st === 3) {
        // ---- (4) メッセージ窓を開く (画面行 20-27、列 2-29 = 左右 16px ずつ空ける) ----
        // 16px 空けるのは、パレットが 16x16 ブロック単位のため (8px だと窓の外側の地面が
        // 窓のパレットに染まる)。左右 1 ブロックは attr を触らないので地面の色のまま
        // まず窓に重なる sprite だけ隠す (16px の sprite は画面 y >= 145 で窓 y 160-223 に重なる)。
        // NPC は nes_obj_draw のしきい値 (3 引数目の上位 byte = 145 → 145*256 = 37120)、
        // 勇者は自前で判定。OAM は次の NMI で反映され、枠の書き込みはその後のフレームで
        // キューから流れるので、sprite が消えてから窓が現れる順になる (閉じるとき rd=1 で全部戻る)
        nes_obj_draw($cpx, $cpy, $NPC_N + 37120);
        $sy = $hpy - $cpy;
        if ($sy > 144) {
            nes_sprite_at(0, 0, 240, 0); nes_sprite_at(1, 0, 240, 0);
            nes_sprite_at(2, 0, 240, 0); nes_sprite_at(3, 0, 240, 0);
        }
        nes_vsync();                                // 隠した OAM を先に反映
        // 枠は 1 行 = 1 つの nes_puts (64 列で折り返すので nametable の継ぎ目をまたいでも良い)
        $wc = $cpx >> 3;
        $wc = $wc + 2;
        $wc = $wc & 63;
        $j2 = $cpy >> 3;
        $j2 = $j2 + 20;
        $j = 0;
        while ($j < 8) {
            $ntr = $j2 + $j;
            $ntr = $ntr % 30;
            nes_puts($wc, $ntr, "\xFB                          \xFC");
            if ($j === 0) { nes_puts($wc, $ntr, "\xF8\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xF9\xFA"); }
            if ($j === 7) { nes_puts($wc, $ntr, "\xFD\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFE\xFF"); }
            $j = $j + 1;
        }
        // 窓のブロック (メタタイル行 10-13、列 1-14) をパレット 0 に (左右 1 ブロックは地面のまま)
        $j = 10;
        while ($j < 14) {
            $by = $cy + $j;
            $by = $by % 15;
            $i = 1;
            while ($i < 15) {
                nes_attr(31 & ($cx + $i), $by, 0);
                $i = $i + 1;
            }
            $j = $j + 1;
        }
        // テキスト: メッセージ msg (1 始まり)。まずグリフを CHR-RAM に載せ (1 フレーム黒くなる)、
        // 3 行を行 22-24、列 4 から 1 文字ずつ置く (0 で行終端、最大 25 文字)
        $wc = 63 & ($wc + 2);                       // テキスト開始列 (画面列 4)
        $o = $msg * 84;
        $o = $o + 4780;                             // 4864 + (msg - 1) * 84
        $mi = nes_peek16_ext($o);                   // グリフの ROM offset
        $c = nes_peek_ext($o + 2);                  // グリフ数
        if ($c > 0) { nes_chr_copy(192, $mi, $c); } // グリフスロット 0xC0 から
        $o = $o + 4;
        $j = 0;
        while ($j < 3) {
            $ntr = $j2 + 2 + $j;
            $ntr = $ntr % 30;
            $i = 0;
            $c = nes_peek_ext($o);
            while ($c !== 0) {                      // 0 = 行の終端
                nes_put(63 & ($wc + $i), $ntr, $c);
                $i = $i + 1;
                $c = nes_peek_ext($o + $i);
            }
            $o = $o + 26;
            $j = $j + 1;
        }
        $wo = 0;
        $win = 1;
        $ap = 128;
    }
    if ($st === 4) {
        // ---- (5) 窓表示中: A を離して押し直すと閉じる ----
        $k = nes_btn();
        $k = $k & 128;
        $ae = 128 - $ap;                            // A の立ち上がり = 今押していて前は離していた
        $ae = $ae & $k;
        if ($ae !== 0) {
            $win = 0;
            $rx = 0; $ry = 10; $rw = 16; $rh = 4;
            $rd = 1;                                // NPC を戻す
        }
        $ap = $k;
    }
    if ($st === 5) {
        // ---- (6) 待機中: 入力 ----
        $k = nes_btn();
        $mv = 0;
        if ($k & 8) { $d = 0; $dx = 0; $dy = 0 - 1; $mv = 1; }
        if ($k & 4) { $d = 2; $dx = 0; $dy = 1; $mv = 1; }
        if ($k & 2) { $d = 3; $dx = 0 - 1; $dy = 0; $mv = 1; }
        if ($k & 1) { $d = 1; $dx = 1; $dy = 0; $mv = 1; }
        $j = $k & 128;
        $ae = 128 - $ap;
        $ae = $ae & $j;                             // A の立ち上がり (0 / 128)
        $ap = $j;
        $mv = $mv | $ae;                            // 何か起きる (移動 or A) か
        if ($mv === 0) {
            if ($fl === 1) {                        // 歩き終わり: 補間完了を待って位置を確定
                nes_cam_wait();
                $fl = 0;
                nes_scroll($cpx & 511, $cpy % 240);
                $rd = 1;
                // 縦の行は先読みしない: 隠れ帯 (上下 8 ドット) には表示中の端のメタタイルの半分が
                // 入っていて空きがなく、上書きすると反対向きに歩いたとき壊れた半分が見える。
                // 行は書いてすぐ動かせる (最初の 4 フレームは隠れたまま) ので先読みの利点もない
            }
        }
        if ($mv !== 0) {
            // 目の前のマス (tx, ty) の文字 c と、そこにいるオブジェクト (hit = 1、msg)
            $tx = $hx + $dx;
            $ty = $hy + $dy;
            $mi = $ty * $MW + $tx;
            $c = nes_peek_ext($mi);                 // 外周は通行不可 (エクスポータが保証) なのでマップ外に出ない
            $hit = nes_obj_at($tx, $ty);            // 0 = なし、1 + msg = いる、+256 = sprite なし (VM がレコードを探す)
            if ($hit > 0) {
                $msg = $hit & 255;
                $msg = $msg - 1;
                $hit = 1 + ($hit >> 8);             // 1 = NPC (通行を妨げる)、2 = セリフだけ (通らない置き物や任意のマス)
            }
            if ($ae !== 0) {
                // A: 町人に話す / 宝箱を調べる (レコードの msg) / 扉を開ける
                nes_cam_wait();                     // 歩き終わりの補間中なら止まってから
                if ($fl === 1) { $fl = 0; nes_scroll($cpx & 511, $cpy % 240); $rd = 1; }
                // 目の前がカウンター (0x48) や鉄格子 (0x45) で誰もいなければ、その向こう側の人と話せる
                $k = 0;
                if ($c === 72) { $k = 1; }
                if ($c === 69) { $k = 1; }
                if ($hit !== 0) { $k = 0; }
                if ($k === 1) {
                    $hit = nes_obj_at($tx + $dx, $ty + $dy);
                    if ($hit > 0) { $msg = $hit - 1; $hit = 1; }
                }
                if ($hit > 0) { $wo = 1; }
                if ($msg === 0) { $wo = 0; }
                if ($c === 71) {                    // 0x47 = DOOR → 通行可の床 (0x61) にして描き直す
                    nes_poke_ext($mi, 97);
                    $rx = $tx - $cx; $ry = $ty - $cy; $rw = 1; $rh = 1;
                }
            }
            if ($ae === 0) {
                $rd = 1;                            // 向きだけでも変わる
                if ($hit === 1) { $c = 0; }         // NPC がいるマスには入れない (セリフだけのマスは通れる)
                if ($c & 32) {                      // bit 5 = 通行可
                    // カメラの移動量 (端ではクランプ)
                    $tx = $tx - 7;
                    if ($tx < 0) { $tx = 0; }
                    if ($tx > $MW - 16) { $tx = $MW - 16; }
                    $cdx = $tx - $cx;
                    $ty = $ty - 7;
                    if ($ty < 0) { $ty = 0; }
                    if ($ty > $MH - 15) { $ty = $MH - 15; }
                    $cdy = $ty - $cy;
                    $cm = $cdx | $cdy;              // 0 ならカメラは動かない (マップ端)
                    $ms = 2;
                }
            }
        }
    }
}
