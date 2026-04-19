// nesphp CHR editor
// 32KB CHR = 4 banks × 2 pattern tables × 256 tiles × 16 bytes
// 1 tile = 8 rows of bp0 (bytes 0-7) + 8 rows of bp1 (bytes 8-15)

const CHR_SIZE = 32768;
const BANK_SIZE = 8192;
const TABLE_SIZE = 4096;
const TILE_SIZE = 16;

const BDF_STORAGE_KEY_TEXT = 'chrEdit.bdf.text';
const BDF_STORAGE_KEY_NAME = 'chrEdit.bdf.name';

// --- NES 64-color palette (2C02) RGB lookup ---
const NES_RGB = [
  [0x52,0x52,0x52],[0x01,0x1A,0x51],[0x0F,0x0F,0x65],[0x23,0x06,0x63],
  [0x36,0x03,0x4B],[0x40,0x04,0x26],[0x3F,0x09,0x04],[0x32,0x13,0x00],
  [0x1F,0x20,0x00],[0x0B,0x2A,0x00],[0x00,0x2F,0x00],[0x00,0x2E,0x0A],
  [0x00,0x26,0x2D],[0x00,0x00,0x00],[0x00,0x00,0x00],[0x00,0x00,0x00],

  [0xA0,0xA0,0xA0],[0x1E,0x4A,0x9D],[0x38,0x37,0xBC],[0x58,0x28,0xB8],
  [0x75,0x21,0x94],[0x84,0x23,0x5C],[0x82,0x2E,0x24],[0x6F,0x3F,0x00],
  [0x51,0x52,0x00],[0x31,0x63,0x00],[0x1A,0x6B,0x05],[0x0E,0x69,0x2E],
  [0x10,0x5C,0x68],[0x00,0x00,0x00],[0x00,0x00,0x00],[0x00,0x00,0x00],

  [0xFE,0xFF,0xFF],[0x69,0x9E,0xFC],[0x89,0x87,0xFF],[0xAE,0x76,0xFF],
  [0xCE,0x6D,0xF1],[0xE0,0x70,0xB2],[0xDE,0x7C,0x70],[0xC8,0x8D,0x32],
  [0xA9,0xA0,0x00],[0x87,0xB4,0x00],[0x6C,0xBE,0x2A],[0x5D,0xBB,0x63],
  [0x5F,0xB1,0xA0],[0x5A,0x5A,0x5A],[0x00,0x00,0x00],[0x00,0x00,0x00],

  [0xFE,0xFF,0xFF],[0xBD,0xD8,0xFE],[0xCC,0xCE,0xFF],[0xDC,0xC5,0xFF],
  [0xEA,0xC1,0xF8],[0xF2,0xC2,0xDE],[0xF2,0xC8,0xC2],[0xEA,0xD0,0xAC],
  [0xDC,0xDA,0x9E],[0xCA,0xE4,0x9F],[0xBA,0xEA,0xAD],[0xB0,0xE9,0xC4],
  [0xB1,0xE4,0xDD],[0xB5,0xB5,0xB5],[0x00,0x00,0x00],[0x00,0x00,0x00],
];
function nesRgbCss(i) {
  const c = NES_RGB[i & 0x3F];
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// --- State ---
const state = {
  chr: new Uint8Array(CHR_SIZE),
  bank: 0,
  table: 0,
  tile: 0x00,
  palettes: [
    [0x30, 0x10, 0x00],  // palette 0: white, gray, black
    [0x30, 0x16, 0x27],  // palette 1: white, red, orange
    [0x30, 0x2A, 0x1A],  // palette 2: white, bright green, green
    [0x30, 0x21, 0x11],  // palette 3: white, light blue, blue
  ],
  bgColor: 0x0F,   // shared universal BG (NES $3F00)
  paletteIdx: 0,
  colorIdx: 1,     // paint color slot selection (0..3)
  bdfMap: null,    // Map<codepoint, Uint8Array(8)> once BDF loaded
};

// --- Tile data access ---
function tileOffset(bank, table, tile) {
  return bank * BANK_SIZE + table * TABLE_SIZE + tile * TILE_SIZE;
}
function getPixel(bank, table, tile, x, y) {
  const base = tileOffset(bank, table, tile);
  const bit = 7 - x;
  const bp0 = (state.chr[base + y] >> bit) & 1;
  const bp1 = (state.chr[base + 8 + y] >> bit) & 1;
  return bp0 | (bp1 << 1);
}
function setPixel(bank, table, tile, x, y, color) {
  const base = tileOffset(bank, table, tile);
  const bit = 7 - x;
  const mask = (~(1 << bit)) & 0xFF;
  state.chr[base + y] =
    (state.chr[base + y] & mask) | (((color & 1) ? 1 : 0) << bit);
  state.chr[base + 8 + y] =
    (state.chr[base + 8 + y] & mask) | (((color & 2) ? 1 : 0) << bit);
}

// --- Palette resolution (for preview rendering) ---
// Color index 0 uses shared BG color. 1-3 use palette[paletteIdx][0..2].
function resolveColor(colorIdx) {
  if (colorIdx === 0) return state.bgColor;
  return state.palettes[state.paletteIdx][colorIdx - 1];
}

// --- Canvases ---
const tileGrid = document.getElementById('tileGrid');
const tileGridCtx = tileGrid.getContext('2d');
const tileEditor = document.getElementById('tileEditor');
const tileEditorCtx = tileEditor.getContext('2d');

const GRID_SCALE = 3;   // tile = 8*3 = 24 px in grid
const EDIT_SCALE = 40;  // pixel cell = 40 px in editor

// --- Rendering ---
function renderTileGrid() {
  tileGridCtx.fillStyle = nesRgbCss(state.bgColor);
  tileGridCtx.fillRect(0, 0, tileGrid.width, tileGrid.height);
  const tileWH = 8 * GRID_SCALE;
  for (let t = 0; t < 256; t++) {
    const tx = (t & 0x0F) * tileWH;
    const ty = (t >> 4) * tileWH;
    for (let y = 0; y < 8; y++) {
      for (let x = 0; x < 8; x++) {
        const c = getPixel(state.bank, state.table, t, x, y);
        tileGridCtx.fillStyle = nesRgbCss(resolveColor(c));
        tileGridCtx.fillRect(tx + x * GRID_SCALE, ty + y * GRID_SCALE, GRID_SCALE, GRID_SCALE);
      }
    }
  }
  // Selection overlay
  const sx = (state.tile & 0x0F) * tileWH;
  const sy = (state.tile >> 4) * tileWH;
  tileGridCtx.strokeStyle = '#ff0';
  tileGridCtx.lineWidth = 2;
  tileGridCtx.strokeRect(sx + 1, sy + 1, tileWH - 2, tileWH - 2);

  document.getElementById('tileIdLabel').textContent =
    '$' + state.tile.toString(16).toUpperCase().padStart(2, '0');
}

function renderTileEditor() {
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const c = getPixel(state.bank, state.table, state.tile, x, y);
      tileEditorCtx.fillStyle = nesRgbCss(resolveColor(c));
      tileEditorCtx.fillRect(x * EDIT_SCALE, y * EDIT_SCALE, EDIT_SCALE, EDIT_SCALE);
    }
  }
  // Grid lines
  tileEditorCtx.strokeStyle = 'rgba(255,255,255,0.12)';
  tileEditorCtx.lineWidth = 1;
  for (let i = 0; i <= 8; i++) {
    tileEditorCtx.beginPath();
    tileEditorCtx.moveTo(i * EDIT_SCALE, 0);
    tileEditorCtx.lineTo(i * EDIT_SCALE, 8 * EDIT_SCALE);
    tileEditorCtx.moveTo(0, i * EDIT_SCALE);
    tileEditorCtx.lineTo(8 * EDIT_SCALE, i * EDIT_SCALE);
    tileEditorCtx.stroke();
  }
}

function renderPalettes() {
  const list = document.getElementById('paletteList');
  list.innerHTML = '';

  // BG (shared)
  const bgRow = document.createElement('div');
  bgRow.className = 'palette-row';
  const bgLabel = document.createElement('div');
  bgLabel.className = 'palette-row-label';
  bgLabel.textContent = 'BG (共有)';
  bgRow.appendChild(bgLabel);
  const bgCell = document.createElement('div');
  bgCell.className = 'pal-cell';
  bgCell.style.background = nesRgbCss(state.bgColor);
  if (state.paletteIdx === -1) bgCell.classList.add('selected');
  const bgHex = document.createElement('div');
  bgHex.className = 'label';
  bgHex.textContent = '$' + state.bgColor.toString(16).toUpperCase().padStart(2, '0');
  bgCell.appendChild(bgHex);
  bgCell.addEventListener('click', () => {
    state.paletteIdx = -1;  // -1 means editing BG color
    renderPalettes();
    renderColorSlots();
  });
  bgRow.appendChild(bgCell);
  list.appendChild(bgRow);

  // 4 palettes × 3 user colors (bg is shared)
  for (let p = 0; p < 4; p++) {
    const row = document.createElement('div');
    row.className = 'palette-row';
    const label = document.createElement('div');
    label.className = 'palette-row-label';
    label.textContent = `Pal ${p}`;
    row.appendChild(label);
    // color 0 (shared BG) as a faded display
    const c0 = document.createElement('div');
    c0.className = 'pal-cell';
    c0.style.background = nesRgbCss(state.bgColor);
    c0.style.opacity = 0.35;
    c0.title = '共有 BG';
    row.appendChild(c0);
    for (let ci = 0; ci < 3; ci++) {
      const cell = document.createElement('div');
      cell.className = 'pal-cell';
      cell.style.background = nesRgbCss(state.palettes[p][ci]);
      if (state.paletteIdx === p && state.colorIdx === ci + 1) {
        cell.classList.add('selected');
      }
      const hex = document.createElement('div');
      hex.className = 'label';
      hex.textContent = '$' + state.palettes[p][ci].toString(16).toUpperCase().padStart(2, '0');
      cell.appendChild(hex);
      cell.addEventListener('click', () => {
        state.paletteIdx = p;
        state.colorIdx = ci + 1;
        renderPalettes();
        renderColorSlots();
        renderTileGrid();
        renderTileEditor();
      });
      row.appendChild(cell);
    }
    list.appendChild(row);
  }

  renderPalettePhp();
}

function renderColorSlots() {
  document.querySelectorAll('.color-slot').forEach((el) => {
    const idx = parseInt(el.dataset.idx, 10);
    el.style.background = nesRgbCss(resolveColor(idx));
    el.classList.toggle('active', idx === state.colorIdx);
  });
}

function renderNesPalette() {
  const cont = document.getElementById('nesPalette');
  cont.innerHTML = '';
  for (let i = 0; i < 64; i++) {
    const sw = document.createElement('div');
    sw.className = 'swatch';
    sw.style.background = nesRgbCss(i);
    const hex = document.createElement('div');
    hex.className = 'hex';
    hex.textContent = '$' + i.toString(16).toUpperCase().padStart(2, '0');
    sw.appendChild(hex);
    sw.addEventListener('click', () => {
      if (state.paletteIdx === -1) {
        state.bgColor = i;
      } else if (state.paletteIdx >= 0 && state.colorIdx >= 1) {
        state.palettes[state.paletteIdx][state.colorIdx - 1] = i;
      }
      renderPalettes();
      renderColorSlots();
      renderTileGrid();
      renderTileEditor();
    });
    cont.appendChild(sw);
  }
}

function renderPalettePhp() {
  const lines = [];
  lines.push(`nes_bg_color(0x${state.bgColor.toString(16).toUpperCase().padStart(2, '0')});`);
  for (let p = 0; p < 4; p++) {
    const [c1, c2, c3] = state.palettes[p];
    const h = (n) => '0x' + n.toString(16).toUpperCase().padStart(2, '0');
    lines.push(`nes_palette(${p}, ${h(c1)}, ${h(c2)}, ${h(c3)});`);
  }
  document.getElementById('palettePhp').textContent = lines.join('\n');
}

// --- Event wiring ---
document.getElementById('bankSel').addEventListener('change', (e) => {
  state.bank = parseInt(e.target.value, 10);
  renderTileGrid();
  renderTileEditor();
});
document.getElementById('tableSel').addEventListener('change', (e) => {
  state.table = parseInt(e.target.value, 10);
  renderTileGrid();
  renderTileEditor();
});

tileGrid.addEventListener('click', (e) => {
  const rect = tileGrid.getBoundingClientRect();
  const x = e.clientX - rect.left;
  const y = e.clientY - rect.top;
  const tileWH = 8 * GRID_SCALE;
  const tx = Math.floor(x / tileWH);
  const ty = Math.floor(y / tileWH);
  if (tx < 0 || tx > 15 || ty < 0 || ty > 15) return;
  const tileIdx = ty * 16 + tx;
  state.tile = tileIdx;
  if (strExport.active) {
    strExport.seq.push(tileIdx);
    renderStrExport();
  }
  renderTileGrid();
  renderTileEditor();
});

let painting = false;
let paintBtn = 0;
function paintAt(e) {
  const rect = tileEditor.getBoundingClientRect();
  const x = Math.floor((e.clientX - rect.left) / EDIT_SCALE);
  const y = Math.floor((e.clientY - rect.top) / EDIT_SCALE);
  if (x < 0 || x > 7 || y < 0 || y > 7) return;
  const c = paintBtn === 2 ? 0 : state.colorIdx;
  setPixel(state.bank, state.table, state.tile, x, y, c);
  renderTileEditor();
  renderTileGrid();
}
tileEditor.addEventListener('mousedown', (e) => {
  e.preventDefault();
  painting = true;
  paintBtn = e.button;
  paintAt(e);
});
tileEditor.addEventListener('mousemove', (e) => {
  if (painting) paintAt(e);
});
window.addEventListener('mouseup', () => { painting = false; });
tileEditor.addEventListener('contextmenu', (e) => e.preventDefault());

document.querySelectorAll('.color-slot').forEach((el) => {
  el.addEventListener('click', () => {
    state.colorIdx = parseInt(el.dataset.idx, 10);
    // switch palette focus back to regular editing
    if (state.paletteIdx === -1) state.paletteIdx = 0;
    renderColorSlots();
    renderPalettes();
  });
});

document.getElementById('gotoBtn').addEventListener('click', () => {
  const v = parseInt(document.getElementById('gotoInput').value, 16);
  if (!isNaN(v) && v >= 0 && v < 256) {
    state.tile = v;
    renderTileGrid();
    renderTileEditor();
  }
});

document.getElementById('clearBankBtn').addEventListener('click', () => {
  if (!confirm(`bank ${state.bank} を全消去しますか？`)) return;
  for (let i = 0; i < BANK_SIZE; i++) {
    state.chr[state.bank * BANK_SIZE + i] = 0;
  }
  renderTileGrid();
  renderTileEditor();
  setStatus(`bank ${state.bank} cleared`);
});

document.getElementById('copyFromBankBtn').addEventListener('click', () => {
  if (!confirm('bank 0 の内容を bank 1-3 にコピーしますか？')) return;
  for (let b = 1; b < 4; b++) {
    for (let i = 0; i < BANK_SIZE; i++) {
      state.chr[b * BANK_SIZE + i] = state.chr[0 * BANK_SIZE + i];
    }
  }
  renderTileGrid();
  setStatus('bank 0 -> bank 1..3 copied');
});

// --- Load / Save CHR file ---
document.getElementById('loadChrBtn').addEventListener('click', () => {
  document.getElementById('loadChrInput').click();
});
document.getElementById('loadChrInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const buf = new Uint8Array(reader.result);
    if (buf.length !== CHR_SIZE) {
      setStatus(`期待 ${CHR_SIZE}B、読み込んだのは ${buf.length}B`, true);
      return;
    }
    state.chr.set(buf);
    renderTileGrid();
    renderTileEditor();
    setStatus(`loaded ${file.name} (${buf.length} bytes)`);
  };
  reader.readAsArrayBuffer(file);
});

document.getElementById('downloadChrBtn').addEventListener('click', () => {
  const blob = new Blob([state.chr], { type: 'application/octet-stream' });
  triggerDownload(blob, 'font.chr');
  setStatus('downloaded font.chr');
});

// --- Export make_font.php ---
function toBase64(u8) {
  let s = '';
  const chunk = 0x8000;
  for (let i = 0; i < u8.length; i += chunk) {
    s += String.fromCharCode.apply(null, u8.subarray(i, i + chunk));
  }
  return btoa(s);
}

function generateMakeFontPhp() {
  const b64 = toBase64(state.chr);
  // Wrap to 76 chars per line (standard base64)
  const lines = [];
  for (let i = 0; i < b64.length; i += 76) {
    lines.push(b64.substring(i, i + 76));
  }
  const stamp = new Date().toISOString();
  return `<?php
/**
 * chr/font.chr 生成スクリプト (chr-edit で生成: ${stamp})
 *
 * 32KB CHR-ROM = 4 banks × 8KB。各 bank は pattern table 0/1 (計 512 タイル)。
 * タイルバイナリは base64 で埋め込み済み。編集は chr-edit/index.html で。
 */

declare(strict_types=1);

$chr = base64_decode(
${lines.map((l) => `    '${l}'`).join(" .\n")}
);

assert(strlen($chr) === 32768, 'font.chr must be exactly 32768 bytes');

$outPath = __DIR__ . '/font.chr';
file_put_contents($outPath, $chr);
fprintf(STDERR, "[make_font] wrote %s (%d bytes, from chr-edit)\\n", $outPath, strlen($chr));
`;
}

document.getElementById('copyPhpBtn').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(generateMakeFontPhp());
    setStatus('make_font.php をクリップボードにコピーしました');
  } catch (e) {
    setStatus('clipboard 書き込みに失敗: ' + e.message, true);
  }
});

document.getElementById('downloadPhpBtn').addEventListener('click', () => {
  const blob = new Blob([generateMakeFontPhp()], { type: 'text/x-php' });
  triggerDownload(blob, 'make_font.php');
  setStatus('downloaded make_font.php');
});

document.getElementById('copyPaletteBtn').addEventListener('click', async () => {
  try {
    const text = document.getElementById('palettePhp').textContent;
    await navigator.clipboard.writeText(text);
    setStatus('palette PHP をコピーしました');
  } catch (e) {
    setStatus('clipboard 書き込みに失敗: ' + e.message, true);
  }
});

// --- Utilities ---
function triggerDownload(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function setStatus(msg, isErr) {
  const el = document.getElementById('status');
  el.textContent = msg;
  el.classList.toggle('err', !!isErr);
}

// --- 8x8 BDF loading + text writing ---
// Works with any BDF whose glyph width ≤ 8 (e.g., Misaki gothic/mincho).
// BDF glyph bitmap rows are MSB-aligned within each byte, same as NES CHR bp0.
// For glyphs wider than 8 we take only the leftmost byte; for shorter heights
// we top-align within the 8×8 tile and zero-pad the rest.
function parseBdf(text) {
  const map = new Map();
  const lines = text.split(/\r?\n/);
  let i = 0;
  let fbbHeight = 8;
  let fbbYoff = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('FONTBOUNDINGBOX')) {
      const p = line.split(/\s+/);
      // FONTBOUNDINGBOX w h xoff yoff
      if (p.length >= 5) {
        fbbHeight = parseInt(p[2], 10) || 8;
        fbbYoff = parseInt(p[4], 10) || 0;
      }
    } else if (line.startsWith('STARTCHAR')) {
      let encoding = -1;
      let bbxH = fbbHeight;
      let bbxYoff = fbbYoff;
      let bits = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('ENDCHAR')) {
        const ln = lines[i];
        if (ln.startsWith('ENCODING ')) {
          encoding = parseInt(ln.substring(9).trim(), 10);
        } else if (ln.startsWith('BBX ')) {
          const p = ln.substring(4).trim().split(/\s+/).map(Number);
          // BBX w h xoff yoff
          bbxH = p[1] || fbbHeight;
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
      if (encoding >= 0 && bits.length > 0) {
        // Vertical alignment: baseline-aware. Example: Misaki 8×8 has
        // FONTBOUNDINGBOX 8 8 0 -1 (ascent=7, descent=1) so baseline is at
        // tile row 6.
        // Glyph bottom row is placed at (baselineRow - bbxYoff); glyph top row
        // is then (bottom - h + 1). This matches the font designer's intent
        // and makes short glyphs (exclamation, hiragana etc.) sit on the
        // baseline rather than floating at the top of the tile.
        const glyph = new Uint8Array(8);
        const h = Math.min(bits.length, 8);
        const ascent = Math.max(1, Math.min(8, fbbHeight + fbbYoff));
        const baselineRow = ascent - 1;
        const topRow = baselineRow - bbxYoff - h + 1;
        for (let y = 0; y < h; y++) {
          const ty = topRow + y;
          if (ty >= 0 && ty < 8) glyph[ty] = bits[y] & 0xFF;
        }
        map.set(encoding, glyph);
      }
    }
    i++;
  }
  return map;
}

function writeGlyphToTile(bank, table, tile, glyph8) {
  const base = tileOffset(bank, table, tile);
  for (let y = 0; y < 8; y++) {
    state.chr[base + y] = glyph8[y];
    state.chr[base + 8 + y] = 0;  // bp1 = 0 (1-bit glyph)
  }
}

// BDF テキストを parse して state に反映。isAutoRestore が true の場合は
// localStorage からの復元と判定して status メッセージを変える。成功で true、
// parse 失敗で false を返す。
function hydrateBdf(text, filename, isAutoRestore) {
  try {
    const map = parseBdf(text);
    state.bdfMap = map;
    document.getElementById('writeTextBtn').disabled = false;
    document.getElementById('installAsciiBtn').disabled = false;
    document.getElementById('bdfStatus').textContent = `BDF: ${map.size} glyphs`;
    const forgetBtn = document.getElementById('forgetBdfBtn');
    if (forgetBtn) forgetBtn.style.display = '';
    if (isAutoRestore) {
      setStatus(`BDF 自動復元: ${filename} (${map.size} glyphs)`);
    } else {
      setStatus(`BDF 読込: ${filename} (${map.size} glyphs)`);
    }
    return true;
  } catch (err) {
    setStatus('BDF parse error: ' + err.message, true);
    return false;
  }
}

document.getElementById('loadBdfBtn').addEventListener('click', () => {
  document.getElementById('loadBdfInput').click();
});
document.getElementById('loadBdfInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    if (hydrateBdf(reader.result, file.name, false)) {
      try {
        localStorage.setItem(BDF_STORAGE_KEY_TEXT, reader.result);
        localStorage.setItem(BDF_STORAGE_KEY_NAME, file.name);
      } catch (err) {
        // QuotaExceeded / SecurityError (Safari private mode 等) は無視して続行
        console.warn('localStorage save failed:', err.message);
      }
    }
  };
  reader.readAsText(file);
});

function forgetBdf() {
  try {
    localStorage.removeItem(BDF_STORAGE_KEY_TEXT);
    localStorage.removeItem(BDF_STORAGE_KEY_NAME);
  } catch (e) { /* ignore */ }
  state.bdfMap = null;
  document.getElementById('writeTextBtn').disabled = true;
  document.getElementById('installAsciiBtn').disabled = true;
  document.getElementById('bdfStatus').textContent = '';
  const forgetBtn = document.getElementById('forgetBdfBtn');
  if (forgetBtn) forgetBtn.style.display = 'none';
  setStatus('保存済 BDF を削除しました');
}

const forgetBdfBtn = document.getElementById('forgetBdfBtn');
if (forgetBdfBtn) forgetBdfBtn.addEventListener('click', forgetBdf);

// ASCII 0x20-0x7E の glyph を対応するタイル index (= codepoint) に一括コピー。
// 現在の bank / pattern table に書く。writeGlyphToTile は bp1=0 なので 1-bit で
// 書き込まれるため、color 1 で表示される。
document.getElementById('installAsciiBtn').addEventListener('click', () => {
  if (!state.bdfMap) return;
  if (!confirm('ASCII 0x20-0x7E (95 タイル) を BDF グリフで上書きします。よろしいですか？')) return;
  let written = 0, missing = 0;
  for (let cp = 0x20; cp <= 0x7E; cp++) {
    const glyph = state.bdfMap.get(cp);
    if (glyph) {
      writeGlyphToTile(state.bank, state.table, cp, glyph);
      written++;
    } else {
      missing++;
    }
  }
  renderTileGrid();
  renderTileEditor();
  setStatus(`ASCII 一括配置 (bank ${state.bank}, table ${state.table}): ${written} 文字書込` +
            (missing ? `、${missing} 文字は BDF に無し` : ''));
});

function openWriteModal() {
  if (!state.bdfMap) return;
  const modal = document.getElementById('textWriteModal');
  modal.style.display = 'flex';
  document.getElementById('writeStartLabel').textContent =
    '$' + state.tile.toString(16).toUpperCase().padStart(2, '0');
  document.getElementById('writeBankLabel').textContent = state.bank;
  document.getElementById('writeTableLabel').textContent = state.table;
  const ta = document.getElementById('writeTextInput');
  ta.focus();
  ta.select();
}
function closeWriteModal() {
  document.getElementById('textWriteModal').style.display = 'none';
}

function applyWriteText() {
  const ta = document.getElementById('writeTextInput');
  const text = ta.value;
  if (!text) { closeWriteModal(); return; }
  if (!state.bdfMap) return;

  const startCol = state.tile & 0x0F;
  let col = startCol;
  let row = state.tile >> 4;
  let written = 0;
  let missing = 0;

  for (const ch of text) {
    if (row > 15) break;
    const cp = ch.codePointAt(0);
    if (ch === '\n') {
      row++;
      col = startCol;
      continue;
    }
    if (cp === 0x0D) continue;  // ignore CR
    const tile = row * 16 + col;
    if (tile > 0xFF) break;
    const glyph = state.bdfMap.get(cp);
    if (glyph) {
      writeGlyphToTile(state.bank, state.table, tile, glyph);
      written++;
    } else {
      // fill with blank tile (zeros) so advancing is visible
      writeGlyphToTile(state.bank, state.table, tile, new Uint8Array(8));
      missing++;
    }
    col++;
    if (col > 15) { col = 0; row++; }
  }

  // Move cursor to next position after written text (clamped within grid)
  if (row > 15) row = 15;
  state.tile = (row * 16 + col) & 0xFF;

  renderTileGrid();
  renderTileEditor();
  const msg = `${written} 文字を書込、${missing} 文字は未登録 (空白で埋め)`;
  setStatus(msg);
  closeWriteModal();
}

document.getElementById('writeTextBtn').addEventListener('click', openWriteModal);
document.getElementById('writeCloseBtn').addEventListener('click', closeWriteModal);
document.getElementById('writeApplyBtn').addEventListener('click', applyWriteText);
document.getElementById('writeTextInput').addEventListener('keydown', (e) => {
  // IME 確定中 (日本語の Enter) は apply を発火させず、変換確定だけを通す。
  // macOS Safari / Chrome / Firefox 共通: isComposing もしくは keyCode 229 が
  // IME compose 中の keydown を示す。
  if (e.isComposing || e.keyCode === 229) return;
  // Enter (no shift) = apply; Shift+Enter = newline
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    applyWriteText();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    closeWriteModal();
  }
});
window.addEventListener('keydown', (e) => {
  // 'T' opens write modal when not typing in another field
  if ((e.key === 't' || e.key === 'T') &&
      document.activeElement.tagName !== 'TEXTAREA' &&
      document.activeElement.tagName !== 'INPUT') {
    if (!document.getElementById('writeTextBtn').disabled) {
      e.preventDefault();
      openWriteModal();
    }
  } else if (e.key === 'Escape') {
    const modal = document.getElementById('textWriteModal');
    if (modal.style.display === 'flex') closeWriteModal();
  }
});

// --- String export (tile index sequence → PHP nes_puts) ---
const strExport = {
  active: false,
  seq: [],   // tile indices in click order; "newline" is represented as -1
};

function strExportStart() {
  strExport.active = true;
  strExport.seq = [];
  const startBtn = document.getElementById('strExportStartBtn');
  startBtn.disabled = true;
  startBtn.classList.add('primary');
  document.getElementById('strExportFinishBtn').disabled = false;
  document.getElementById('strExportCancelBtn').disabled = false;
  renderStrExport();
  setStatus('エクスポートモード: Tile Grid をクリックして文字を並べる (スペースキーで改行)');
}

function strExportReset() {
  strExport.active = false;
  strExport.seq = [];
  const startBtn = document.getElementById('strExportStartBtn');
  startBtn.disabled = false;
  startBtn.classList.remove('primary');
  document.getElementById('strExportFinishBtn').disabled = true;
  document.getElementById('strExportCancelBtn').disabled = true;
  renderStrExport();
}

function strExportCancel() {
  strExportReset();
  setStatus('文字列エクスポートをキャンセル');
}

async function strExportFinish() {
  if (strExport.seq.length === 0) {
    setStatus('タイルが 1 つも選択されていません', true);
    return;
  }
  const php = buildStrExportPhp();
  const count = strExport.seq.length;
  try {
    await navigator.clipboard.writeText(php);
    setStatus(`PHP コード (${count} tile 分) をクリップボードにコピー — 続けて選択可 / Cancel で終了`);
  } catch (e) {
    setStatus('clipboard 書き込みに失敗: ' + e.message, true);
  }
}

function buildStrExportPhp() {
  const x = parseInt(document.getElementById('strExportX').value, 10) || 0;
  const y = parseInt(document.getElementById('strExportY').value, 10) || 0;
  // Split seq on -1 (newline) into groups; each group → one nes_puts call on
  // an incrementing y.
  const groups = [[]];
  for (const t of strExport.seq) {
    if (t === -1) groups.push([]);
    else groups[groups.length - 1].push(t);
  }
  const lines = [];
  let yy = y;
  for (const g of groups) {
    if (g.length === 0) { yy++; continue; }
    const escaped = g.map((t) => '\\x' + t.toString(16).toUpperCase().padStart(2, '0')).join('');
    lines.push(`nes_puts(${x}, ${yy}, "${escaped}");`);
    yy++;
  }
  return lines.join('\n');
}

function renderStrExport() {
  const prev = document.getElementById('strExportPreview');
  const hexEl = document.getElementById('strExportHex');
  const php = document.getElementById('strExportPhp');
  const ctx = prev.getContext('2d');
  const PREV_SCALE = 2;          // 1 tile = 16×16 px in preview
  const TILE_PX = 8 * PREV_SCALE; // 16
  const ROW_TILES = 32;          // NES nametable row width (matches canvas 512px / 16)

  // Compute number of rows needed
  let rows = 1;
  let col = 0;
  for (const t of strExport.seq) {
    if (t === -1) { rows++; col = 0; continue; }
    col++;
    if (col >= ROW_TILES) { col = 0; rows++; }
  }
  prev.height = Math.max(TILE_PX, rows * TILE_PX);

  // Clear (width assignment is a reset; but we only need to clear if canvas
  // height was just changed — set size then fill)
  ctx.fillStyle = nesRgbCss(state.bgColor);
  ctx.fillRect(0, 0, prev.width, prev.height);

  // Draw tiles
  let r = 0, c = 0;
  for (const t of strExport.seq) {
    if (t === -1) { r++; c = 0; continue; }
    const px0 = c * TILE_PX;
    const py0 = r * TILE_PX;
    for (let y = 0; y < 8; y++) {
      for (let x = 0; x < 8; x++) {
        const ci = getPixel(state.bank, state.table, t, x, y);
        ctx.fillStyle = nesRgbCss(resolveColor(ci));
        ctx.fillRect(px0 + x * PREV_SCALE, py0 + y * PREV_SCALE, PREV_SCALE, PREV_SCALE);
      }
    }
    c++;
    if (c >= ROW_TILES) { c = 0; r++; }
  }

  // Hex labels (one line per row, compact)
  if (strExport.seq.length === 0) {
    hexEl.textContent = strExport.active ? '(Tile Grid をクリックで追加)' : '';
  } else {
    const parts = [];
    let buf = [];
    for (const t of strExport.seq) {
      if (t === -1) { parts.push(buf.join(' ')); buf = []; continue; }
      buf.push('$' + t.toString(16).toUpperCase().padStart(2, '0'));
    }
    parts.push(buf.join(' '));
    hexEl.textContent = parts.join(' / ');
  }

  php.textContent = strExport.seq.length ? buildStrExportPhp() : '';
}

document.getElementById('strExportStartBtn').addEventListener('click', strExportStart);
document.getElementById('strExportFinishBtn').addEventListener('click', strExportFinish);
document.getElementById('strExportCancelBtn').addEventListener('click', strExportCancel);

// Space key: insert newline marker while in export mode
window.addEventListener('keydown', (e) => {
  if (!strExport.active) return;
  if (document.activeElement.tagName === 'INPUT' ||
      document.activeElement.tagName === 'TEXTAREA') return;
  if (e.key === ' ') {
    e.preventDefault();
    strExport.seq.push(-1);
    renderStrExport();
  } else if (e.key === 'Backspace') {
    e.preventDefault();
    strExport.seq.pop();
    renderStrExport();
  } else if (e.key === 'Enter') {
    e.preventDefault();
    strExportFinish();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    strExportCancel();
  }
});

// --- Init ---
renderNesPalette();
renderPalettes();
renderColorSlots();
renderTileGrid();
renderTileEditor();
setStatus('空の CHR で開始。既存を編集するなら [Load font.chr...] でロード');

// Auto-restore BDF from localStorage (if any). Degrades silently when storage
// is unavailable (Safari private mode) or when saved data fails to parse.
(function restoreBdfFromStorage() {
  let savedText = null;
  let savedName = '(unknown)';
  try {
    savedText = localStorage.getItem(BDF_STORAGE_KEY_TEXT);
    savedName = localStorage.getItem(BDF_STORAGE_KEY_NAME) || savedName;
  } catch (e) {
    return;   // storage unavailable, skip restore
  }
  if (!savedText) return;
  if (!hydrateBdf(savedText, savedName, true)) {
    // corrupt cache, clean up
    try {
      localStorage.removeItem(BDF_STORAGE_KEY_TEXT);
      localStorage.removeItem(BDF_STORAGE_KEY_NAME);
    } catch (e) { /* ignore */ }
  }
})();
