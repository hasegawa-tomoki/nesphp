// map-edit export: JSON (editor model) → nesphp 用データ
//
//   town_map.php  : $MW/$MH/$HX/$HY/$NPC_N と nes_rom_copy(0, 0, 8192) だけ (op を食わない)
//   town.data.bin : PRG-ROM bank 2 (GAMEDATA) に焼くバイナリ
//       0     .. : bank 3 イメージ (起動時に nes_rom_copy で PRG-RAM bank 3 へ展開)
//         0        マップ 1 byte/マス (0x40 + 種類、通行可なら 0x60 + 種類)
//         4080     PALTAB: 種類 → BG パレット 16 byte
//         4096     オブジェクト [x, y, type, msg, pal] 5 byte (宝箱は type 0xFF)
//         4864     メッセージ 1 件 84 byte: [glyph offset lo, hi][glyph 数][pad] + 3 行 × 26 byte (0 終端)
//       8192  .. : グリフ (16 byte/タイル、misaki BDF から必要な文字だけ)。メッセージごとに
//                  連続して置き、窓を開くとき nes_chr_copy(0xB8, offset, n) で CHR-RAM に載せる
//
// メッセージ本文は「タイル番号の列」: ASCII 0x20-0x7E は常駐フォントそのまま、それ以外の文字は
// そのメッセージ内で 0xC0 から順に割り当てたグリフスロット (最大 56)。
//
// ブラウザ (index.html) と node (gen.js) の両方から使う。

const TILE_NAMES = ['WALL', 'FLOOR', 'GRASS', 'TREE', 'STAIRS', 'BARS',
                    'CHEST', 'DOOR', 'COUNTER', 'WATER', 'BRIDGE', 'BED', 'PHPLOGO', 'ELEPHANT'];
const NPC_NAMES = ['SOLDIER', 'TOWNSMAN', 'SIENNE', 'YOUTH', 'WOMAN', 'BOY'];
// 種類 → sprite パレット: bit 0-1 = 頭 (上 2 枚)、bit 2-3 = 体 (下 2 枚)。nes_palette id は 4 + 値
// 1 = 肌/金/黒 (兵士、女性の金髪の頭)、2 = 肌/青/黒 (町人・若者)、3 = 肌/桃/黒 (ジェンヌ、女性の体)
const NPC_PAL = [2 | (0 << 2), 2 | (2 << 2), 3 | (3 << 2), 2 | (2 << 2), 1 | (3 << 2), 1 | (1 << 2)];
const TILE_PAL = [0, 1, 2, 2, 0, 0, 1, 1, 1, 3, 1, 3, 3, 2];   // chr/make_town_tiles.php の $bgTiles と同順 (0 = 石壁, 1 = レンガ床, 2 = 草木/象, 3 = 水/ベッド/PHP ロゴ)
const WALKABLE = new Set([1, 2, 10]); // FLOOR / GRASS / BRIDGE

const MSG_LINES = 3;
const MSG_COLS = 25;                 // 1 行の最大文字数 (窓の内側 26 列、テキストは列 4 から)
const MSG_LINE_STRIDE = 26;          // 25 文字 + 終端 0
const MSG_HDR = 4;                   // [glyph off lo, hi][count][pad]
const MSG_STRIDE = MSG_HDR + MSG_LINES * MSG_LINE_STRIDE;   // 82 → 84 に切り上げ
const MSG_STRIDE_ALIGNED = 84;
const GLYPH_SLOT0 = 0xC0;            // グリフスロット 0xC0-0xF7 (0xB8-0xBF = メタタイル種類 12-13、0xF8-0xFF = 窓枠)
const MAX_GLYPHS_PER_MSG = 56;       // 3 行 × 25 文字でも異なり字が 56 を超えることは稀 (超えた分は '?' + 警告)

const BANK3_SIZE = 8192;
const PALTAB_BASE = 4080;
const NPC_BASE = 4096;
const NPC_STRIDE = 5;
const MSG_BASE = 4864;
const GLYPH_BASE = 8192;             // ROM bank 2 内 offset
const ROM_BANK_SIZE = 16384;
const MAX_MAP_BYTES = 4080;
const MAX_MSGS = Math.floor((BANK3_SIZE - MSG_BASE) / MSG_STRIDE_ALIGNED);   // 46
const MAX_NPCS = Math.floor((MSG_BASE - NPC_BASE) / NPC_STRIDE);            // 153

function mapChar(t) {
  return String.fromCharCode((WALKABLE.has(t) ? 0x60 : 0x40) + t);
}

// --- BDF (misaki_gothic.bdf など、ISO10646 = Unicode エンコーディング) ---
// 戻り値: Map<codepoint, Uint8Array(8)> (chr-edit/editor.js の parseBdf と同じ整列規則)
function parseBdf(text) {
  const map = new Map();
  const lines = text.split(/\r?\n/);
  let fbbHeight = 8;
  let fbbYoff = 0;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('FONTBOUNDINGBOX')) {
      const p = line.split(/\s+/);
      if (p.length >= 5) { fbbHeight = parseInt(p[2], 10) || 8; fbbYoff = parseInt(p[4], 10) || 0; }
    } else if (line.startsWith('STARTCHAR')) {
      let encoding = -1;
      let bbxYoff = fbbYoff;
      let bbxXoff = 0;
      const bits = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('ENDCHAR')) {
        const ln = lines[i];
        if (ln.startsWith('ENCODING ')) {
          encoding = parseInt(ln.substring(9).trim(), 10);
        } else if (ln.startsWith('BBX ')) {
          const p = ln.substring(4).trim().split(/\s+/).map(Number);
          bbxXoff = p[2] || 0;
          bbxYoff = p[3] || 0;
        } else if (ln === 'BITMAP') {
          i++;
          while (i < lines.length && !lines[i].startsWith('ENDCHAR')) {
            const hex = lines[i].trim();
            if (hex.length >= 2) bits.push(parseInt(hex.substring(0, 2), 16));
            i++;
          }
          break;
        }
        i++;
      }
      if (encoding >= 0) {
        const glyph = new Uint8Array(8);
        const h = Math.min(bits.length, 8);
        const ascent = Math.max(1, Math.min(8, fbbHeight + fbbYoff));
        const baselineRow = ascent - 1;
        const topRow = baselineRow - bbxYoff - h + 1;
        for (let y = 0; y < h; y++) {
          const ty = topRow + y;
          if (ty >= 0 && ty < 8) glyph[ty] = (bbxXoff > 0 ? bits[y] >> bbxXoff : bits[y]) & 0xFF;
        }
        map.set(encoding, glyph);
      }
    }
    i++;
  }
  return map;
}

// --- メッセージのエンコード ---
// 戻り値: { lines: [Uint8Array...] (各行のタイル番号列), glyphs: [Uint8Array(8)...], warnings }
function encodeMessage(text, bdf, label) {
  const warnings = [];
  const raw = (text || '').replace(/\r/g, '').split('\n');
  if (raw.length > MSG_LINES) { warnings.push(`${label}: ${MSG_LINES} 行を超える分は無視`); raw.length = MSG_LINES; }
  const slots = new Map();   // codepoint → tile
  const glyphs = [];
  const lines = [];
  for (let li = 0; li < raw.length; li++) {
    const chars = Array.from(raw[li]);
    if (chars.length > MSG_COLS) { warnings.push(`${label}: ${MSG_COLS} 文字を超える行を切り詰め (行 ${li + 1})`); chars.length = MSG_COLS; }
    const bytes = [];
    for (const ch of chars) {
      let cp = ch.codePointAt(0);
      if (cp === 0x3000) cp = 0x20;                       // 全角スペース → 半角
      if (cp >= 0x20 && cp <= 0x7E) { bytes.push(cp); continue; }
      if (slots.has(cp)) { bytes.push(slots.get(cp)); continue; }
      const g = bdf ? bdf.get(cp) : null;
      if (!g) {
        warnings.push(`${label}: グリフなし '${ch}' (U+${cp.toString(16).toUpperCase()}) → '?'` + (bdf ? '' : ' (BDF 未読込)'));
        bytes.push(0x3F);
        continue;
      }
      if (glyphs.length >= MAX_GLYPHS_PER_MSG) {
        warnings.push(`${label}: 異なり文字が ${MAX_GLYPHS_PER_MSG} を超えた → '?'`);
        bytes.push(0x3F);
        continue;
      }
      const tile = GLYPH_SLOT0 + glyphs.length;
      slots.set(cp, tile);
      glyphs.push(g);
      bytes.push(tile);
    }
    lines.push(Uint8Array.from(bytes));
  }
  return { lines, glyphs, warnings };
}

// 互換: エディタの入力チェック用 (行数/文字数の警告だけ返す)
function splitMessage(text, label) {
  const r = encodeMessage(text, null, label);
  return { lines: r.lines, warnings: r.warnings.filter((w) => !w.includes('グリフなし')) };
}

// msg id の割り当て: NPC 順に 1.., 続けて宝箱。0 = メッセージなし
function assignMessages(data) {
  const msgs = [];
  const npcMsg = data.npcs.map((n) => {
    if (!n.msg) return 0;
    msgs.push({ label: `NPC(${n.x},${n.y})`, text: n.msg });
    return msgs.length;
  });
  const chestMsg = data.chests.map((c) => {
    if (!c.msg) return 0;
    msgs.push({ label: `MSG(${c.x},${c.y})`, text: c.msg });
    return msgs.length;
  });
  return { msgs, npcMsg, chestMsg };
}

function validate(data, msgs) {
  if (data.w * data.h > MAX_MAP_BYTES) throw new Error(`map too large: ${data.w}x${data.h} > ${MAX_MAP_BYTES}`);
  if (data.w > 255) throw new Error('map width must be <= 255');
  if (data.w < 16 || data.h < 15) throw new Error('map must be at least 16x15');
  if (msgs.length > MAX_MSGS) throw new Error(`too many messages: ${msgs.length} > ${MAX_MSGS}`);
  if (data.npcs.length + data.chests.length > MAX_NPCS) throw new Error('too many objects');
  for (let x = 0; x < data.w; x++) {
    if (WALKABLE.has(data.map[0][x]) || WALKABLE.has(data.map[data.h - 1][x])) throw new Error('外周 (上下の行) に通行可能なタイルがあります');
  }
  for (let y = 0; y < data.h; y++) {
    if (WALKABLE.has(data.map[y][0]) || WALKABLE.has(data.map[y][data.w - 1])) throw new Error('外周 (左右の列) に通行可能なタイルがあります');
  }
}

// data + bdf → { php, bin: Uint8Array, warnings }
function exportMapPhp(data, bdf) {
  const { msgs, npcMsg, chestMsg } = assignMessages(data);
  validate(data, msgs);
  const warnings = [];
  const bank3 = new Uint8Array(BANK3_SIZE);
  // マップ
  for (let y = 0; y < data.h; y++) for (let x = 0; x < data.w; x++) bank3[y * data.w + x] = mapChar(data.map[y][x]).charCodeAt(0);
  // PALTAB
  for (let t = 0; t < 16; t++) bank3[PALTAB_BASE + t] = TILE_PAL[t] || 0;
  // オブジェクト
  let o = NPC_BASE;
  data.npcs.forEach((n, i) => { bank3.set([n.x, n.y, n.type, npcMsg[i], NPC_PAL[n.type]], o); o += NPC_STRIDE; });
  data.chests.forEach((c, i) => { bank3.set([c.x, c.y, 0xFF, chestMsg[i], 0], o); o += NPC_STRIDE; });
  // メッセージ + グリフ
  const glyphBytes = [];
  msgs.forEach((m, i) => {
    const r = encodeMessage(m.text, bdf, m.label);
    warnings.push(...r.warnings);
    const base = MSG_BASE + i * MSG_STRIDE_ALIGNED;
    const goff = GLYPH_BASE + glyphBytes.length;
    bank3[base] = goff & 0xFF;
    bank3[base + 1] = goff >> 8;
    bank3[base + 2] = r.glyphs.length;
    r.lines.forEach((line, li) => bank3.set(line, base + MSG_HDR + li * MSG_LINE_STRIDE));
    for (const g of r.glyphs) { for (let y = 0; y < 8; y++) glyphBytes.push(g[y]); for (let y = 0; y < 8; y++) glyphBytes.push(0); }
  });
  if (GLYPH_BASE + glyphBytes.length > ROM_BANK_SIZE) throw new Error(`グリフが多すぎます (${glyphBytes.length / 16} 個、上限 ${(ROM_BANK_SIZE - GLYPH_BASE) / 16})`);
  const bin = new Uint8Array(BANK3_SIZE + glyphBytes.length);
  bin.set(bank3, 0);
  bin.set(glyphBytes, BANK3_SIZE);

  const out = [];
  out.push('<?php');
  out.push('// map-edit/index.html が生成 (手で編集しない)。examples/town.php が require で取り込む。');
  out.push(`// マップ ${data.w}x${data.h} メタタイル、NPC/宝箱 ${data.npcs.length + data.chests.length}、メッセージ ${msgs.length} 件、グリフ ${glyphBytes.length / 16} タイル。`);
  out.push('// 本体は examples/town.data.bin (PRG-ROM bank 2 = GAMEDATA) にあり、起動時に bank 3 へ展開する。');
  out.push(`$MW = ${data.w};`);
  out.push(`$MH = ${data.h};`);
  out.push(`$hx = ${data.hero.x};`);
  out.push(`$hy = ${data.hero.y};`);
  out.push(`$NPC_N = ${data.npcs.length + data.chests.length};`);
  out.push(`nes_rom_copy(0, 0, ${BANK3_SIZE});`);
  return { php: out.join('\n') + '\n', bin, warnings };
}

if (typeof module !== 'undefined') {
  module.exports = { TILE_NAMES, NPC_NAMES, NPC_PAL, MSG_LINES, MSG_COLS, WALKABLE, parseBdf, encodeMessage, exportMapPhp, splitMessage, mapChar };
}
