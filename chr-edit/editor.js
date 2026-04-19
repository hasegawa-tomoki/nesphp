// nesphp CHR editor
// 32KB CHR = 4 banks × 2 pattern tables × 256 tiles × 16 bytes
// 1 tile = 8 rows of bp0 (bytes 0-7) + 8 rows of bp1 (bytes 8-15)

const CHR_SIZE = 32768;
const BANK_SIZE = 8192;
const TABLE_SIZE = 4096;
const TILE_SIZE = 16;

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
  state.tile = ty * 16 + tx;
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

// --- Init ---
renderNesPalette();
renderPalettes();
renderColorSlots();
renderTileGrid();
renderTileEditor();
setStatus('空の CHR で開始。既存を編集するなら [Load font.chr...] でロード');
