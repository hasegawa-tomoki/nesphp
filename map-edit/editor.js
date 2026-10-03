// nesphp map editor
// モデル (JSON): { w, h, hero:{x,y}, map:[[type...]...], npcs:[{x,y,type,msg}], chests:[{x,y,msg}] }
// 出力は export.js の exportMapPhp() (examples/town.php が require する town_map.php)。

const STORAGE_KEY = 'mapEdit.model';
const CHR_KEY = 'mapEdit.chr';
const BDF_KEY = 'mapEdit.bdf';
const BG_BASE_TILE = 0x88;
const SPR_BASE_TILE = 0x90;
const BG_PALETTES = [[0x30, 0x10, 0x00], [0x27, 0x26, 0x06], [0x27, 0x1A, 0x0A], [0x30, 0x21, 0x13]];
const SPR_PALETTES = [[0x30, 0x21, 0x0F], [0x36, 0x28, 0x0F], [0x36, 0x11, 0x0F], [0x36, 0x25, 0x0F]];
const TILE_PAL_LOCAL = [0, 1, 2, 2, 0, 0, 1, 1, 1, 3, 1, 3, 3, 2];
const TILE_FALLBACK = ['#a0a0a0', '#c06030', '#3c9a3c', '#1f6a1f', '#606060', '#d0d0d0', '#d08030', '#a06020', '#b07040', '#4090e0', '#c09050', '#7090ff', '#7a7bb4', '#f08020'];
const TILE_JA = ['石壁', 'レンガ床', '草', '木', '階段', '鉄格子', '宝箱', '扉', 'カウンター', '水', '橋', 'ベッド', 'PHP ロゴ', 'みかんの象'];
const NPC_JA = ['兵士', '町人', 'ジェンヌ', '若者 (上向き)', '女性', '少年 (下向き)'];

const NES_RGB = [
  [0x52,0x52,0x52],[0x01,0x1A,0x51],[0x0F,0x0F,0x65],[0x23,0x06,0x63],[0x36,0x03,0x4B],[0x40,0x04,0x26],[0x3F,0x09,0x04],[0x32,0x13,0x00],
  [0x1F,0x20,0x00],[0x0B,0x2A,0x00],[0x00,0x2F,0x00],[0x00,0x2E,0x0A],[0x00,0x26,0x2D],[0x00,0x00,0x00],[0x00,0x00,0x00],[0x00,0x00,0x00],
  [0xA0,0xA0,0xA0],[0x1E,0x4A,0x9D],[0x38,0x37,0xBC],[0x58,0x28,0xB8],[0x75,0x21,0x94],[0x84,0x23,0x5C],[0x82,0x2E,0x24],[0x6F,0x3F,0x00],
  [0x51,0x52,0x00],[0x31,0x63,0x00],[0x1A,0x6B,0x05],[0x0E,0x69,0x2E],[0x10,0x5C,0x68],[0x00,0x00,0x00],[0x00,0x00,0x00],[0x00,0x00,0x00],
  [0xFE,0xFF,0xFF],[0x69,0x9E,0xFC],[0x89,0x87,0xFF],[0xAE,0x76,0xFF],[0xCE,0x6D,0xF1],[0xE0,0x70,0xB2],[0xDE,0x7C,0x70],[0xC8,0x8D,0x32],
  [0xA9,0xA0,0x00],[0x87,0xB4,0x00],[0x6C,0xBE,0x2A],[0x5D,0xBB,0x63],[0x5F,0xB1,0xA0],[0x5A,0x5A,0x5A],[0x00,0x00,0x00],[0x00,0x00,0x00],
  [0xFE,0xFF,0xFF],[0xBD,0xD8,0xFE],[0xCC,0xCE,0xFF],[0xDC,0xC5,0xFF],[0xEA,0xC1,0xF8],[0xF2,0xC2,0xDE],[0xF2,0xC8,0xC2],[0xEA,0xD0,0xAC],
  [0xDC,0xDA,0x9E],[0xCA,0xE4,0x9F],[0xBA,0xEA,0xAD],[0xB0,0xE9,0xC4],[0xB1,0xE4,0xDD],[0xB5,0xB5,0xB5],[0x00,0x00,0x00],[0x00,0x00,0x00],
];

// --- state ---
const state = {
  model: null,
  tool: { kind: 'tile', type: 1 },   // kind: tile | npc | chest | hero | select
  chr: null,                          // Uint8Array(32768) or null
  tileImgs: [],                       // per metatile type: 16x16 canvas
  sprImgs: [],                        // per NPC type: 16x16 canvas
  zoom: 2,
  selected: null,                     // { kind: 'npc'|'chest', index }
  painting: false,
  dragging: null,                     // 移動中: { kind: 'npc'|'chest'|'hero', index, fromX, fromY }
  dragCell: null,                     // 移動先の候補マス (canvas 外なら null)
  bdf: null,                          // Map<codepoint, Uint8Array(8)> (misaki など)
  bdfName: '',
  exportBin: null,                    // 直近の出力 (Uint8Array)
};

function newModel(w, h) {
  const map = [];
  for (let y = 0; y < h; y++) {
    const row = [];
    for (let x = 0; x < w; x++) row.push((x === 0 || y === 0 || x === w - 1 || y === h - 1) ? 3 : 2);
    map.push(row);
  }
  return { w, h, hero: { x: Math.floor(w / 2), y: Math.floor(h / 2) }, map, npcs: [], chests: [] };
}

// --- CHR rendering (chr-edit と同じ 2bpp 形式) ---
function chrPixel(chr, set, tile, x, y) {
  const base = set * 4096 + tile * 16;
  const bit = 7 - x;
  const bp0 = (chr[base + y] >> bit) & 1;
  const bp1 = (chr[base + 8 + y] >> bit) & 1;
  return (bp1 << 1) | bp0;
}
function renderMetatile(chr, set, baseTile, pal, transparent, palBottom) {
  const c = document.createElement('canvas');
  c.width = 16; c.height = 16;
  const ctx = c.getContext('2d');
  const img = ctx.createImageData(16, 16);
  const palTop = pal;
  for (let ty = 0; ty < 2; ty++) for (let tx = 0; tx < 2; tx++) {
    const tile = baseTile + ty * 2 + tx;
    const pal = (ty === 1 && palBottom) ? palBottom : palTop;
    for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
      const p = chrPixel(chr, set, tile, x, y);
      const i = ((ty * 8 + y) * 16 + tx * 8 + x) * 4;
      if (p === 0) {
        if (transparent) { img.data[i + 3] = 0; continue; }
        img.data[i] = 0; img.data[i + 1] = 0; img.data[i + 2] = 0; img.data[i + 3] = 255;
      } else {
        const rgb = NES_RGB[pal[p - 1] & 0x3F];
        img.data[i] = rgb[0]; img.data[i + 1] = rgb[1]; img.data[i + 2] = rgb[2]; img.data[i + 3] = 255;
      }
    }
  }
  ctx.putImageData(img, 0, 0);
  return c;
}
function rebuildImages() {
  state.tileImgs = [];
  state.sprImgs = [];
  if (!state.chr) return;
  for (let t = 0; t < TILE_NAMES.length; t++) {
    state.tileImgs.push(renderMetatile(state.chr, 0, BG_BASE_TILE + t * 4, BG_PALETTES[TILE_PAL_LOCAL[t]], false));
  }
  for (let t = 0; t < NPC_NAMES.length; t++) {
    state.sprImgs.push(renderMetatile(state.chr, 1, SPR_BASE_TILE + t * 4, SPR_PALETTES[NPC_PAL[t] & 3], true, SPR_PALETTES[(NPC_PAL[t] >> 2) & 3]));
  }
  state.heroImg = renderMetatile(state.chr, 1, 0x80, SPR_PALETTES[0], true);
}

// --- drawing ---
const canvas = document.getElementById('map');
const ctx = canvas.getContext('2d');

function drawTile(t, px, py, size) {
  if (state.tileImgs[t]) {
    ctx.drawImage(state.tileImgs[t], px, py, size, size);
  } else {
    ctx.fillStyle = TILE_FALLBACK[t] || '#f0f';
    ctx.fillRect(px, py, size, size);
    ctx.fillStyle = '#000';
    ctx.font = `${Math.max(8, size / 2)}px monospace`;
    ctx.fillText(String.fromCharCode(65 + t), px + 2, py + size - 3);
  }
}
function drawMarker(px, py, size, color, label) {
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(px + size / 2, py + size / 2, size * 0.38, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = '#000';
  ctx.font = `bold ${Math.max(8, size / 2)}px sans-serif`;
  ctx.fillText(label, px + size * 0.3, py + size * 0.68);
}
// 小さな印 (右上の角): 下のタイルを隠さずに「メッセージ付きレコードがある」ことを示す
function drawBadge(px, py, size, color) {
  const r = Math.max(3, size / 6);
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(px + size - r - 1, py + r + 1, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = '#000';
  ctx.lineWidth = 1;
  ctx.stroke();
}
function render() {
  const m = state.model;
  const s = 16 * state.zoom;
  canvas.width = m.w * s;
  canvas.height = m.h * s;
  ctx.imageSmoothingEnabled = false;
  for (let y = 0; y < m.h; y++) for (let x = 0; x < m.w; x++) drawTile(m.map[y][x], x * s, y * s, s);
  m.chests.forEach((c, i) => {
    drawBadge(c.x * s, c.y * s, s, c.msg ? '#ffdc00' : '#ff4040');   // 黄 = メッセージあり、赤 = 未設定
    if (state.selected && state.selected.kind === 'chest' && state.selected.index === i) highlight(c.x, c.y, s);
  });
  m.npcs.forEach((n, i) => {
    if (state.sprImgs[n.type]) ctx.drawImage(state.sprImgs[n.type], n.x * s, n.y * s, s, s);
    else drawMarker(n.x * s, n.y * s, s, 'rgba(255,255,255,0.85)', 'N' + n.type);
    if (state.selected && state.selected.kind === 'npc' && state.selected.index === i) highlight(n.x, n.y, s);
  });
  if (state.heroImg) ctx.drawImage(state.heroImg, m.hero.x * s, m.hero.y * s, s, s);
  else drawMarker(m.hero.x * s, m.hero.y * s, s, 'rgba(80,160,255,0.9)', 'H');
  // ドラッグ中: 移動先に半透明で描き、置けるなら緑、置けないなら赤の枠
  const d = state.dragging;
  if (d && state.dragCell) {
    const c = state.dragCell;
    const ok = canPlace(d, c.x, c.y);
    ctx.globalAlpha = 0.6;
    if (d.kind === 'npc') {
      const n = m.npcs[d.index];
      if (state.sprImgs[n.type]) ctx.drawImage(state.sprImgs[n.type], c.x * s, c.y * s, s, s);
      else drawMarker(c.x * s, c.y * s, s, 'rgba(255,255,255,0.85)', 'N' + n.type);
    } else if (d.kind === 'hero') {
      if (state.heroImg) ctx.drawImage(state.heroImg, c.x * s, c.y * s, s, s);
      else drawMarker(c.x * s, c.y * s, s, 'rgba(80,160,255,0.9)', 'H');
    } else {
      drawBadge(c.x * s, c.y * s, s, m.chests[d.index].msg ? '#ffdc00' : '#ff4040');
    }
    ctx.globalAlpha = 1;
    ctx.strokeStyle = ok ? '#40ff40' : '#ff4040';
    ctx.lineWidth = 2;
    ctx.strokeRect(c.x * s + 1, c.y * s + 1, s - 2, s - 2);
  }
  // grid
  ctx.strokeStyle = 'rgba(255,255,255,0.12)';
  ctx.lineWidth = 1;
  for (let x = 0; x <= m.w; x++) { ctx.beginPath(); ctx.moveTo(x * s + 0.5, 0); ctx.lineTo(x * s + 0.5, m.h * s); ctx.stroke(); }
  for (let y = 0; y <= m.h; y++) { ctx.beginPath(); ctx.moveTo(0, y * s + 0.5); ctx.lineTo(m.w * s, y * s + 0.5); ctx.stroke(); }
}
function highlight(x, y, s) {
  ctx.strokeStyle = '#ff0';
  ctx.lineWidth = 2;
  ctx.strokeRect(x * s + 1, y * s + 1, s - 2, s - 2);
}

// --- tools ---
function buildTools() {
  const el = document.getElementById('tools');
  el.innerHTML = '';
  const add = (kind, type, label) => {
    const b = document.createElement('button');
    b.textContent = label;
    b.dataset.kind = kind;
    b.dataset.type = type;
    b.addEventListener('click', () => { state.tool = { kind, type }; refreshTools(); });
    el.appendChild(b);
  };
  add('select', 0, '選択 / 編集');
  add('hero', 0, '勇者 (開始位置)');
  TILE_NAMES.forEach((n, i) => add('tile', i, `${String.fromCharCode(65 + i)}: ${TILE_JA[i]} (${n})`));
  NPC_NAMES.forEach((n, i) => add('npc', i, `NPC: ${NPC_JA[i]} (${n})`));
  add('chest', 6, '宝箱 (タイル + メッセージ)');
  add('msg', 0, 'セリフ (任意のマス)');
  refreshTools();
}
function refreshTools() {
  document.querySelectorAll('#tools button').forEach((b) => {
    b.classList.toggle('active', b.dataset.kind === state.tool.kind && Number(b.dataset.type) === state.tool.type);
  });
}

function cellFromEvent(e) {
  const r = canvas.getBoundingClientRect();
  const s = 16 * state.zoom;
  const x = Math.floor((e.clientX - r.left) / s);
  const y = Math.floor((e.clientY - r.top) / s);
  if (x < 0 || y < 0 || x >= state.model.w || y >= state.model.h) return null;
  return { x, y };
}
function findObject(x, y) {
  const m = state.model;
  const ni = m.npcs.findIndex((n) => n.x === x && n.y === y);
  if (ni >= 0) return { kind: 'npc', index: ni };
  const ci = m.chests.findIndex((c) => c.x === x && c.y === y);
  if (ci >= 0) return { kind: 'chest', index: ci };
  return null;
}
// 移動先に置けるか: 盤面内で、ほかのオブジェクトがいないこと (勇者はどこでも)
function canPlace(d, x, y) {
  const m = state.model;
  if (x < 0 || y < 0 || x >= m.w || y >= m.h) return false;
  if (d.kind === 'hero') return true;
  const ex = findObject(x, y);
  return !ex || (ex.kind === d.kind && ex.index === d.index);
}
// オブジェクト (NPC / セリフ / 勇者) を (nx, ny) へ動かす。
// 宝箱タイルの上のセリフを動かすときは宝箱タイルも一緒に動かし、元のマスはレンガ床にする
function moveObject(d, nx, ny) {
  const m = state.model;
  if (!canPlace(d, nx, ny)) return false;
  if (d.kind === 'hero') {
    if (m.hero.x === nx && m.hero.y === ny) return false;
    m.hero = { x: nx, y: ny };
    return true;
  }
  const o = d.kind === 'npc' ? m.npcs[d.index] : m.chests[d.index];
  if (!o || (o.x === nx && o.y === ny)) return false;
  if (d.kind === 'chest' && m.map[o.y][o.x] === 6 && m.map[ny][nx] !== 6) {
    m.map[ny][nx] = 6;
    m.map[o.y][o.x] = 1;
  }
  o.x = nx;
  o.y = ny;
  return true;
}
function applyTool(cell) {
  const m = state.model;
  const t = state.tool;
  if (t.kind === 'tile') {
    if (m.map[cell.y][cell.x] === t.type) return;
    m.map[cell.y][cell.x] = t.type;
  } else if (t.kind === 'hero') {
    m.hero = { x: cell.x, y: cell.y };
  } else if (t.kind === 'npc') {
    const ex = findObject(cell.x, cell.y);
    if (ex) { state.selected = ex; showObject(); return; }
    m.npcs.push({ x: cell.x, y: cell.y, type: t.type, msg: '' });
    state.selected = { kind: 'npc', index: m.npcs.length - 1 };
    showObject();
  } else if (t.kind === 'chest' || t.kind === 'msg') {
    // sprite を持たないメッセージ付きレコード (type 0xFF)。宝箱ツールは宝箱タイルも置く。
    // 目の前で A を押すとメッセージが出る。通行は妨げない (タイルが通行不可なら入れないだけ)
    const ex = findObject(cell.x, cell.y);
    if (ex) { state.selected = ex; showObject(); return; }
    if (t.kind === 'chest' && m.map[cell.y][cell.x] !== t.type) m.map[cell.y][cell.x] = t.type;
    m.chests.push({ x: cell.x, y: cell.y, msg: '' });
    state.selected = { kind: 'chest', index: m.chests.length - 1 };
    showObject();
  } else if (t.kind === 'select') {
    state.selected = findObject(cell.x, cell.y);
    showObject();
  }
  render();
  autosave();
}

canvas.addEventListener('mousedown', (e) => {
  const cell = cellFromEvent(e);
  if (!cell) return;
  if (e.button === 2) {   // スポイト
    state.tool = { kind: 'tile', type: state.model.map[cell.y][cell.x] };
    refreshTools();
    return;
  }
  // タイル以外のツールで既存のオブジェクトを押したらドラッグ移動 (選択ツールでは勇者も)
  if (state.tool.kind !== 'tile') {
    const m = state.model;
    const ex = findObject(cell.x, cell.y);
    if (ex) {
      state.selected = ex;
      showObject();
      state.dragging = { ...ex, fromX: cell.x, fromY: cell.y };
      state.dragCell = cell;
      render();
      return;
    }
    if (state.tool.kind === 'select' && m.hero.x === cell.x && m.hero.y === cell.y) {
      state.dragging = { kind: 'hero', index: 0, fromX: cell.x, fromY: cell.y };
      state.dragCell = cell;
      render();
      return;
    }
  }
  state.painting = (state.tool.kind === 'tile');   // セリフ/NPC/宝箱はクリック 1 回 1 個
  applyTool(cell);
});
canvas.addEventListener('mousemove', (e) => {
  if (state.dragging) {
    const cell = cellFromEvent(e);
    const prev = state.dragCell;
    if ((cell && prev && cell.x === prev.x && cell.y === prev.y) || (!cell && !prev)) return;
    state.dragCell = cell;
    render();
    return;
  }
  if (!state.painting) return;
  const cell = cellFromEvent(e);
  if (cell) applyTool(cell);
});
canvas.addEventListener('mouseleave', () => {
  if (state.dragging && state.dragCell) { state.dragCell = null; render(); }
});
window.addEventListener('mouseup', () => {
  state.painting = false;
  const d = state.dragging;
  if (!d) return;
  state.dragging = null;
  const c = state.dragCell;
  state.dragCell = null;
  if (c && (c.x !== d.fromX || c.y !== d.fromY)) {
    if (moveObject(d, c.x, c.y)) {
      setStatus(`(${d.fromX}, ${d.fromY}) → (${c.x}, ${c.y}) へ移動`);
      autosave();
    } else {
      setStatus('そのマスにはすでにオブジェクトがあります', true);
    }
  }
  showObject();
  render();
});
canvas.addEventListener('contextmenu', (e) => e.preventDefault());

// Esc で「選択 / 編集」ツールに戻る (テキスト入力中は入力欄のフォーカスを外すだけ)。
// 矢印キーで選択中のオブジェクトを 1 マス動かす
const ARROWS = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] };
window.addEventListener('keydown', (e) => {
  const tag = document.activeElement && document.activeElement.tagName;
  const typing = tag === 'TEXTAREA' || tag === 'INPUT' || tag === 'SELECT';
  if (e.key === 'Escape') {
    if (typing) { document.activeElement.blur(); return; }
    state.tool = { kind: 'select', type: 0 };
    refreshTools();
    setStatus('選択 / 編集');
    return;
  }
  if (!ARROWS[e.key] || typing || !state.selected) return;
  const o = currentObject();
  if (!o) return;
  e.preventDefault();
  const [dx, dy] = ARROWS[e.key];
  if (moveObject(state.selected, o.x + dx, o.y + dy)) {
    showObject();
    render();
    autosave();
  } else {
    setStatus('そこには動かせません (盤面の外か、ほかのオブジェクトがいます)', true);
  }
});

// --- object panel ---
function showObject() {
  const panel = document.getElementById('objPanel');
  const edit = document.getElementById('objEdit');
  const sel = state.selected;
  if (!sel) { panel.style.display = ''; edit.style.display = 'none'; return; }
  const m = state.model;
  const obj = sel.kind === 'npc' ? m.npcs[sel.index] : m.chests[sel.index];
  if (!obj) { state.selected = null; showObject(); return; }
  panel.style.display = 'none';
  edit.style.display = '';
  document.getElementById('objKind').textContent = sel.kind === 'npc' ? 'NPC' : `セリフ (${TILE_JA[state.model.map[obj.y][obj.x]]} のマス)`;
  document.getElementById('objPos').textContent = `${obj.x}, ${obj.y}`;
  document.getElementById('npcTypeRow').style.display = sel.kind === 'npc' ? '' : 'none';
  if (sel.kind === 'npc') document.getElementById('npcType').value = obj.type;
  document.getElementById('objMsg').value = obj.msg || '';
  checkMessage(obj.msg || '');
}
function currentObject() {
  const sel = state.selected;
  if (!sel) return null;
  return sel.kind === 'npc' ? state.model.npcs[sel.index] : state.model.chests[sel.index];
}
// メッセージ欄の直下に、行数 / 文字数の超過を表示する
function checkMessage(text) {
  const lines = (text || '').replace(/\r/g, '').split('\n');
  const problems = [];
  lines.forEach((line, i) => {
    const n = Array.from(line).length;
    if (n > MSG_COLS) problems.push(`${i + 1} 行目が ${MSG_COLS} 文字を超えています (${n} 文字)`);
  });
  if (lines.length > MSG_LINES) problems.push(`${MSG_LINES} 行を超えています (${lines.length} 行)`);
  const el = document.getElementById('msgWarn');
  el.textContent = problems.join(' / ');
  document.getElementById('objMsg').classList.toggle('over', problems.length > 0);
  return problems;
}
document.getElementById('objMsg').addEventListener('input', (e) => {
  const o = currentObject();
  if (!o) return;
  o.msg = e.target.value;
  checkMessage(o.msg);
  const r = encodeMessage(o.msg, state.bdf, 'msg');
  const info = `グリフ ${r.glyphs.length} 字`;
  const warns = r.warnings.filter((w) => !w.includes('切り詰め') && !w.includes('無視'));   // 超過は欄の直下に出す
  setStatus(warns.length ? warns.join('\n') : info, warns.length > 0);
  autosave();
});
document.getElementById('npcType').addEventListener('change', (e) => {
  const o = currentObject();
  if (!o) return;
  o.type = Number(e.target.value);
  render();
  autosave();
});
document.getElementById('objDeleteBtn').addEventListener('click', () => {
  const sel = state.selected;
  if (!sel) return;
  if (sel.kind === 'npc') state.model.npcs.splice(sel.index, 1);
  else state.model.chests.splice(sel.index, 1);
  state.selected = null;
  showObject();
  render();
  autosave();
});

// --- size / zoom ---
document.getElementById('resizeBtn').addEventListener('click', () => {
  const w = Math.max(16, Math.min(255, Number(document.getElementById('mapW').value) || 16));
  const h = Math.max(15, Math.min(255, Number(document.getElementById('mapH').value) || 15));
  const m = state.model;
  const nm = newModel(w, h);
  for (let y = 0; y < Math.min(h, m.h); y++) for (let x = 0; x < Math.min(w, m.w); x++) nm.map[y][x] = m.map[y][x];
  nm.hero = { x: Math.min(m.hero.x, w - 1), y: Math.min(m.hero.y, h - 1) };
  nm.npcs = m.npcs.filter((n) => n.x < w && n.y < h);
  nm.chests = m.chests.filter((c) => c.x < w && c.y < h);
  state.model = nm;
  state.selected = null;
  showObject();
  render();
  autosave();
});
document.getElementById('zoom').addEventListener('change', (e) => { state.zoom = Number(e.target.value); render(); });

// --- CHR / JSON I/O ---
document.getElementById('loadChrBtn').addEventListener('click', () => document.getElementById('loadChrInput').click());
document.getElementById('loadChrInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const buf = new Uint8Array(reader.result);
    if (buf.length !== 32768) { setStatus('font.chr は 32768 byte のはず', true); return; }
    state.chr = buf;
    try { localStorage.setItem(CHR_KEY, btoa(String.fromCharCode.apply(null, buf.subarray(0, 8192)))); } catch (err) { /* ignore */ }
    rebuildImages();
    buildTools();
    render();
    setStatus('font.chr を読み込みました (実タイルで表示)');
  };
  reader.readAsArrayBuffer(file);
  e.target.value = '';
});
document.getElementById('loadJsonBtn').addEventListener('click', () => document.getElementById('loadJsonInput').click());
document.getElementById('loadJsonInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    try {
      setModel(JSON.parse(reader.result));
      setStatus(`${file.name} を読み込みました`);
    } catch (err) {
      setStatus('JSON の読み込みに失敗: ' + err.message, true);
    }
  };
  reader.readAsText(file);
  e.target.value = '';
});
document.getElementById('saveJsonBtn').addEventListener('click', () => {
  triggerDownload(new Blob([JSON.stringify(state.model, null, 1)], { type: 'application/json' }), 'town.json');
});

// --- BDF ---
function applyBdfText(text, name) {
  state.bdf = parseBdf(text);
  state.bdfName = name;
  document.getElementById('bdfStatus').textContent = `${name}: ${state.bdf.size} 字`;
}
document.getElementById('loadBdfBtn').addEventListener('click', () => document.getElementById('loadBdfInput').click());
document.getElementById('loadBdfInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    applyBdfText(reader.result, file.name);
    try { localStorage.setItem(BDF_KEY, JSON.stringify({ name: file.name, text: reader.result })); } catch (err) { /* 容量超過なら次回また読む */ }
    setStatus(`${file.name} を読み込みました (${state.bdf.size} 字)`);
  };
  reader.readAsText(file);
  e.target.value = '';
});

// --- export ---
document.getElementById('exportBtn').addEventListener('click', () => {
  try {
    const r = exportMapPhp(state.model, state.bdf);
    document.getElementById('exportOut').value = r.php;
    state.exportBin = r.bin;
    const msg = `town_map.php と town.data.bin (${r.bin.length} byte) を生成しました。両方 examples/ に保存して make build/town.nes`;
    setStatus(r.warnings.length ? r.warnings.join('\n') + '\n' + msg : msg, r.warnings.length > 0);
  } catch (err) {
    document.getElementById('exportOut').value = '';
    state.exportBin = null;
    setStatus('出力エラー: ' + err.message, true);
  }
});
document.getElementById('downloadBinBtn').addEventListener('click', () => {
  if (!state.exportBin) { setStatus('先に「出力」を押してください', true); return; }
  triggerDownload(new Blob([state.exportBin], { type: 'application/octet-stream' }), 'town.data.bin');
});
document.getElementById('copyExportBtn').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(document.getElementById('exportOut').value);
    setStatus('クリップボードにコピーしました');
  } catch (err) { setStatus('コピーに失敗: ' + err.message, true); }
});
document.getElementById('downloadExportBtn').addEventListener('click', () => {
  const text = document.getElementById('exportOut').value;
  if (!text) { setStatus('先に「town_map.php を出力」を押してください', true); return; }
  triggerDownload(new Blob([text], { type: 'text/x-php' }), 'town_map.php');
});

// --- utilities ---
function triggerDownload(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function setStatus(msg, isErr) {
  const el = document.getElementById('status');
  el.textContent = msg;
  el.classList.toggle('err', !!isErr);
}
function autosave() {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state.model)); } catch (err) { /* ignore */ }
}
function setModel(m) {
  if (!m || !Array.isArray(m.map) || !m.w || !m.h) throw new Error('形式が違います');
  m.npcs = m.npcs || [];
  m.chests = m.chests || [];
  m.hero = m.hero || { x: 1, y: 1 };
  state.model = m;
  state.selected = null;
  document.getElementById('mapW').value = m.w;
  document.getElementById('mapH').value = m.h;
  showObject();
  render();
  autosave();
}

// --- init ---
(function init() {
  const sel = document.getElementById('npcType');
  NPC_NAMES.forEach((n, i) => {
    const o = document.createElement('option');
    o.value = i; o.textContent = `${NPC_JA[i]} (${n})`;
    sel.appendChild(o);
  });
  try {
    const savedChr = localStorage.getItem(CHR_KEY);
    if (savedChr) {
      const bin = atob(savedChr);
      const buf = new Uint8Array(32768);
      for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
      state.chr = buf;
      rebuildImages();
    }
  } catch (err) { state.chr = null; }
  try {
    const savedBdf = localStorage.getItem(BDF_KEY);
    if (savedBdf) { const o = JSON.parse(savedBdf); applyBdfText(o.text, o.name + ' (復元)'); }
  } catch (err) { state.bdf = null; }
  buildTools();
  let model = null;
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) model = JSON.parse(saved);
  } catch (err) { model = null; }
  state.model = model || newModel(32, 28);
  document.getElementById('mapW').value = state.model.w;
  document.getElementById('mapH').value = state.model.h;
  render();
  setStatus(model ? '前回の内容を復元しました (localStorage)' : '新規マップ。「JSON を読む」で map-edit/town.json を開けます');
})();
