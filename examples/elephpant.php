<?php
// elePHPant sprite demo: 十字キーで 16x16 の elePHPant を動かす
//
// * スプライト 4 枚 (2x2 タイル) を並べて 16x16 に見せる
//   上半身 CHR 0x10/0x11、下半身 0x12/0x13 (立ち) / 0x14/0x15 (歩き)
// * 左右移動で向きが変わる: nes_sprite_attr の bit6 ($40) = 水平反転 +
//   左右のタイルを入れ替え (反転は向き変更時のみ設定)
// * 移動中は 4 周期ごとに脚フレームを交互切替して歩行アニメ
// * 横移動は慣性つき (1/4px 固定小数点)。地上: 加速 2/摩擦 2、空中: 加速 1 の
//   弱いエアコントロールで、ボタンを離しても慣性で滑空する (マリオ挙動)
// * B = ダッシュ (最高速 2px→4px/周期、脚の切替も倍速)
// * A = ジャンプ (マリオ風可変ジャンプ: 押しっぱなしで大 (91px)、早く離すと
//   小ジャンプ。上昇は重力 -1、下降は -2 で「落ちは速い」)。一度跳んだら
//   A を離すまで次のジャンプは撃てない ($arm)
// * 浮きブロック (上面 jz=80) の上に着地でき、上を歩ける。端から出ると落下
// * sprite palette 0 (= nes_palette id 4) に PHP パープルを設定

nes_puts(11, 2, "ELEPHPANT!");

// --- スーパーマリオ風シーン ---
nes_bg_color(0x21);                 // 空 (SMB 風の水色)
nes_palette(1, 0x27, 0x17, 0x07);   // 地面/ブロック用の茶系 (明橙/レンガ/濃茶)

// 地面: 下 4 行をレンガタイルで敷き詰め (palette 1 で茶色に見せる)
$r = 26;
while ($r <= 29) {
    $c = 0;
    while ($c < 32) {
        nes_put($c, $r, 0x0C);
        $c = $c + 1;
    }
    $r = $r + 1;
}
$c = 0;
while ($c < 16) {
    nes_attr($c, 13, 1);
    nes_attr($c, 14, 1);
    $c = $c + 1;
}

// 浮きブロック列 (rows 16-17): 16x16 ブロック単位。地面から 64px の高さで、
// フルジャンプ (91px) なら上に乗れる。レンガ 2 + ? + レンガ 2 (cols 6-15) と
// 単独 ? (cols 20-21)
$r = 16;
while ($r <= 17) {
    $c = 6;
    while ($c <= 9) { nes_put($c, $r, 0x0C); $c = $c + 1; }
    $c = 12;
    while ($c <= 15) { nes_put($c, $r, 0x0C); $c = $c + 1; }
    $r = $r + 1;
}
nes_put(10, 16, 0x1A);
nes_put(11, 16, 0x1B);
nes_put(10, 17, 0x1C);
nes_put(11, 17, 0x1D);
nes_put(20, 16, 0x1A);
nes_put(21, 16, 0x1B);
nes_put(20, 17, 0x1C);
nes_put(21, 17, 0x1D);
$c = 3;
while ($c <= 7) { nes_attr($c, 8, 1); $c = $c + 1; }
nes_attr(10, 8, 1);

// 雲 (2x2 タイル、palette 0 の白)
nes_put(4, 4, 0x16);
nes_put(5, 4, 0x17);
nes_put(4, 5, 0x18);
nes_put(5, 5, 0x19);
nes_put(17, 7, 0x16);
nes_put(18, 7, 0x17);
nes_put(17, 8, 0x18);
nes_put(18, 8, 0x19);
nes_put(26, 5, 0x16);
nes_put(27, 5, 0x17);
nes_put(26, 6, 0x18);
nes_put(27, 6, 0x19);

// sprite palette 0: 紫ボディ / 濃紫 (輪郭・瞳) / 白 (目・牙)
nes_palette(4, 0x22, 0x03, 0x30);

$x = 120;
$x4 = 480;     // x の 1/4px 固定小数点表現 (= $x * 4)
$vx = 0;       // 横速度 (1/4px/周期、符号つき)
$arm = 1;      // ジャンプ許可 (A を離すと再装填)
$y = 192;      // 接地位置 (地面 row 26 の上に立つ)
$face = 0;     // 0 = 左向き (絵の素の向き) / 1 = 右向き (水平反転)
$pface = 9;    // 前回の向き (初回は必ず attr 設定が走るよう範囲外に)
$anim = 0;     // 脚フレーム 0/1
$walk = 0;     // 歩行アニメ周期カウンタ
$jz = 0;       // ジャンプ高さ (地面からのオフセット)
$jv = 0;       // ジャンプ速度 (上向き正)

while (true) {
    nes_vsync();
    $b = nes_btn();
    // 接地判定 (移動前の位置で): 地面 (jz=0) または ブロック上面 (jz=80 かつ帯上)
    $onb = 0;
    if ($x > 36 && $x < 125) { $onb = 1; }
    if ($x > 148 && $x < 173) { $onb = 1; }
    $ground = 0;
    if ($jz === 0) { $ground = 1; }
    if ($jz === 80 && $onb) { $ground = 1; }

    // --- 横移動 (慣性つき) ---
    $mx = 8;
    if ($b & 0x40) { $mx = 16; }                 // B = ダッシュ (最高速 2 倍)
    $tv = 0;
    if ($b & 0x02) { $tv = 0 - $mx; $face = 0; } // 左
    if ($b & 0x01) { $tv = $mx; $face = 1; }     // 右
    $acc = 1;                                    // 空中: 弱いエアコントロール
    if ($ground === 1) { $acc = 2; }             // 接地: きびきび加速
    if ($tv === 0) {
        if ($ground === 1) {
            // 入力なし: 接地中だけ摩擦。空中は慣性がそのまま残る
            if ($vx > 0) { $vx = $vx - 2; if ($vx < 0) { $vx = 0; } }
            if ($vx < 0) { $vx = $vx + 2; if ($vx > 0) { $vx = 0; } }
        }
    } elseif ($vx < $tv) {
        $vx = $vx + $acc;
        if ($vx > $tv) { $vx = $tv; }
    } elseif ($vx > $tv) {
        $vx = $vx - $acc;
        if ($vx < $tv) { $vx = $tv; }
    }
    $x4 = $x4 + $vx;
    if ($x4 < 32)  { $x4 = 32; $vx = 0; }        // 壁に当たると慣性は消える
    if ($x4 > 928) { $x4 = 928; $vx = 0; }
    $x = $x4 >> 2;

    // 着地判定用に移動後の位置でブロック帯を再計算
    $onb = 0;
    if ($x > 36 && $x < 125) { $onb = 1; }
    if ($x > 148 && $x < 173) { $onb = 1; }

    // ジャンプ物理 (マリオ風)。一度跳んだら A を離すまで再ジャンプ不可
    if (($b & 0x80) === 0) { $arm = 1; }
    if ($ground === 1 && $jv === 0) {
        if (($b & 0x80) && $arm === 1) { $jv = 13; $arm = 0; }   // 発射 (フルで 91px)
    } else {
        $pz = $jz;
        $jz = $jz + $jv;
        if ($jv > 0) {
            $jv = $jv - 1;                       // 上昇: 重力 -1
            if (($b & 0x80) === 0 && $jv > 3) { $jv = 3; }   // A 離し → 小ジャンプ
        } else {
            $jv = $jv - 2;                       // 下降: 重力 -2 (落ちは速い)
            if ($jv < 0 - 12) { $jv = 0 - 12; }  // 終端速度
        }
        if ($jv < 0 && $onb) {
            if ($pz >= 80 && $jz <= 80) { $jz = 80; $jv = 0; }   // ブロックに着地
        }
        if ($jz < 1) { $jz = 0; $jv = 0; }       // 地面に着地
    }

    // 歩行アニメ: 空中はストライドポーズ固定、接地中は移動中だけ脚を動かす
    if ($ground === 0) {
        $anim = 1;
    } elseif ($vx !== 0) {
        $walk = $walk + 1;
        $wt = 4;
        if ($b & 0x40) { $wt = 2; }              // ダッシュ中は脚も倍速
        if ($walk >= $wt) { $walk = 0; $anim = 1 - $anim; }
    } else {
        $walk = 0;
        $anim = 0;
    }
    $ry = $y - $jz;

    // 向きが変わった時だけ 4 枚まとめて反転属性を更新
    if ($face !== $pface) {
        $pface = $face;
        $at = $face * 64;      // bit6 = 水平反転
        nes_sprite_attr(0, $at);
        nes_sprite_attr(1, $at);
        nes_sprite_attr(2, $at);
        nes_sprite_attr(3, $at);
    }

    // タイル配置 (nes_sprite_at の tile はリテラル必須なので分岐で書き分け)
    // 右向きは各タイルが水平反転される分、左右の並びも入れ替える。
    if ($face === 0) {
        nes_sprite_at(0, $x, $ry, 0x10);
        nes_sprite_at(1, $x + 8, $ry, 0x11);
        if ($anim === 0) {
            nes_sprite_at(2, $x, $ry + 8, 0x12);
            nes_sprite_at(3, $x + 8, $ry + 8, 0x13);
        } else {
            nes_sprite_at(2, $x, $ry + 8, 0x14);
            nes_sprite_at(3, $x + 8, $ry + 8, 0x15);
        }
    } else {
        nes_sprite_at(0, $x, $ry, 0x11);
        nes_sprite_at(1, $x + 8, $ry, 0x10);
        if ($anim === 0) {
            nes_sprite_at(2, $x, $ry + 8, 0x13);
            nes_sprite_at(3, $x + 8, $ry + 8, 0x12);
        } else {
            nes_sprite_at(2, $x, $ry + 8, 0x15);
            nes_sprite_at(3, $x + 8, $ry + 8, 0x14);
        }
    }
}
