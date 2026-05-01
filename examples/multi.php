<?php
// マルチスプライトデモ: 8 個のスプライトを for で一度に配置・更新する。
//
// 操作:
//   十字キー = 全 8 スプライト連動で 1px ずつ移動
//
// ポイント:
//   - nes_sprite_at の第 1 引数 ($idx) が runtime int 可なので
//     for ($i = 0; $i < 8; $i++) でループ展開できる
//   - nes_sprite_attr で各 sprite に別パレット (0-3) を割り当て
//     (sprite palette 4-7 を nes_palette で 4 色セットしておく)
//   - $tile (第 4 引数) はリテラル必須なので全部同じ tile 65 ('A')
//   - 括弧式 (...) 未対応なので、x 座標はループ前に $bx を初期化して
//     毎反復 $bx = $bx + 8 で進める

// sprite palette 0-3 (= NES のパレット番号 4-7) を 4 色違いで設定
nes_palette(4, 0x16, 0x27, 0x30);  // palette 0: 赤 / 橙 / 白
nes_palette(5, 0x12, 0x23, 0x30);  // palette 1: 青 / 水 / 白
nes_palette(6, 0x1A, 0x2A, 0x30);  // palette 2: 緑 / 黄緑 / 白
nes_palette(7, 0x14, 0x24, 0x30);  // palette 3: 紫 / 桃 / 白

$x = 100;
$y = 120;

// 初期配置: 8 個を横 8px 間隔で並べ、palette を 0-3 ローテ
$bx = $x;
for ($i = 0; $i < 8; $i++) {
    nes_sprite_at($i, $bx, $y, 65);
    $pal = $i & 3;
    nes_sprite_attr($i, $pal);
    $bx = $bx + 8;
}

while (true) {
    nes_vsync();
    $b = nes_btn();
    if ($b & 0x02) { $x = $x - 1; }  // L
    if ($b & 0x01) { $x = $x + 1; }  // R
    if ($b & 0x08) { $y = $y - 1; }  // U
    if ($b & 0x04) { $y = $y + 1; }  // D

    // 全 8 スプライトの y/tile/x を毎フレーム更新 (attr は触らない)
    $bx = $x;
    for ($i = 0; $i < 8; $i++) {
        nes_sprite_at($i, $bx, $y, 65);
        $bx = $bx + 8;
    }
}
