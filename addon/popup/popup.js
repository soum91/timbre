'use strict';
const ext = globalThis.browser || globalThis.chrome;
const $ = (s) => document.querySelector(s);
const COLORS = ['#ffb340', '#5cc7ff', '#8ce673', '#ff738c', '#bf8cff', '#4debd1', '#ffd959', '#ff8c4d'];
const FS = 48000;
const FREQS = logFreqs(220);

let cfg = defaultConfig();
let presets = [];
let presetName = null;
let disabledHosts = [];
let selected = null;
let tab = null;
let spectrum = [];
let aeqIndex = null;

// ---------- storage ----------
let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => ext.storage.local.set({ config: cfg }), 25);
}
function savePresets() { ext.storage.local.set({ presets, presetName }); }
function setPresetName(n) { presetName = n; $('#presetName').textContent = n || 'Custom'; ext.storage.local.set({ presetName }); }
function toast(t) {
  const el = $('#toast'); el.textContent = t; el.classList.remove('hidden');
  clearTimeout(toast.t); toast.t = setTimeout(() => el.classList.add('hidden'), 2600);
}

function mergeDefaults(c) {
  const d = defaultConfig();
  for (const k of Object.keys(d)) {
    if (c[k] === undefined) c[k] = d[k];
    else if (d[k] && typeof d[k] === 'object' && !Array.isArray(d[k])) c[k] = Object.assign({}, d[k], c[k]);
  }
  return c;
}

// ---------- formatting ----------
const fmt = {
  hz: f => f >= 1000 ? (f / 1000).toFixed(f >= 10000 ? 1 : 2) + ' kHz' : Math.round(f) + ' Hz',
  db: g => (g > 0.05 ? '+' : '') + g.toFixed(1) + ' dB',
  q: q => q.toFixed(2),
  ms: v => (v < 10 ? v.toFixed(1) : Math.round(v)) + ' ms',
  pct: v => Math.round(v * 100) + '%',
  deg: v => Math.round(v) + '°',
  ratio: v => v.toFixed(1) + ':1',
  s: v => v.toFixed(2) + ' s',
  m: v => v.toFixed(1) + ' m'
};

// ---------- generic controls ----------
function param(parent, label, get, set, min, max, o = {}) {
  const wrap = document.createElement('div'); wrap.className = 'param' + (o.disabled ? ' off' : '');
  const lbl = document.createElement('div'); lbl.className = 'lbl';
  const name = document.createElement('span'); name.textContent = label;
  const val = document.createElement('span'); val.className = 'val';
  lbl.append(name, val);
  const r = document.createElement('input'); r.type = 'range'; r.min = 0; r.max = 1000; r.step = 1;
  const toT = v => o.log ? (Math.log(v) - Math.log(min)) / (Math.log(max) - Math.log(min)) : (v - min) / (max - min);
  const fromT = t => {
    let v = o.log ? Math.exp(Math.log(min) + t * (Math.log(max) - Math.log(min))) : min + t * (max - min);
    if (o.step) v = Math.round(v / o.step) * o.step;
    return v;
  };
  const show = () => { const v = get(); val.textContent = (o.fmt || (x => x.toFixed(1)))(v); r.value = Math.round(Math.min(1, Math.max(0, toT(v))) * 1000); };
  r.addEventListener('input', () => { set(fromT(r.value / 1000)); val.textContent = (o.fmt || (x => x.toFixed(1)))(get()); onChange(o.structural); });
  val.addEventListener('click', () => {
    const v = prompt(label, String(+get().toFixed(3)));
    if (v === null) return;
    const n = parseFloat(v.replace(',', '.'));
    if (isFinite(n)) { set(Math.min(max, Math.max(min, n))); show(); onChange(o.structural); }
  });
  show();
  wrap.append(lbl, r);
  parent.append(wrap);
  return wrap;
}

function toggle(checked, onToggle) {
  const l = document.createElement('label'); l.className = 'switch';
  const i = document.createElement('input'); i.type = 'checkbox'; i.checked = checked;
  i.addEventListener('change', () => onToggle(i.checked));
  l.append(i, document.createElement('span'));
  return l;
}

function chips(parent, items, onPick) {
  const c = document.createElement('div'); c.className = 'chips';
  for (const it of items) { const b = document.createElement('button'); b.textContent = it[0]; b.onclick = () => onPick(it); c.append(b); }
  parent.append(c);
}

// ---------- change handling ----------
function onChange(structural) {
  save();
  drawGraph();
  if (structural) renderAll();
  else { renderBandList(); renderPreampInfo(); }
}

// ---------- graph ----------
const cv = $('#graph'), g2 = cv.getContext('2d');
let plot = { x: 30, y: 8, w: 0, h: 0 }, range = 12;

function sizeCanvas() {
  const r = cv.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
  cv.width = Math.round(r.width * dpr); cv.height = Math.round(r.height * dpr);
  g2.setTransform(dpr, 0, 0, dpr, 0, 0);
  plot = { x: 30, y: 8, w: r.width - 38, h: r.height - 26 };
}
const fx = f => plot.x + (Math.log(Math.max(f, 20)) - Math.log(20)) / (Math.log(20000) - Math.log(20)) * plot.w;
const xf = x => Math.min(20000, Math.max(20, Math.exp(Math.log(20) + (x - plot.x) / plot.w * (Math.log(20000) - Math.log(20)))));
const gy = g => plot.y + plot.h / 2 - g / range * plot.h / 2;
const yg = y => Math.max(-range, Math.min(range, (plot.y + plot.h / 2 - y) / (plot.h / 2) * range));

function nodePos(b) {
  const g = usesGain(b.type) ? b.gain : bandResponse(b, [b.freq], FS)[0];
  return { x: fx(b.freq), y: gy(Math.max(-range, Math.min(range, g))) };
}

function drawGraph() {
  document.body.classList.toggle('disabled', !cfg.enabled);
  const curve = response(cfg.bands, FREQS, FS);
  const m = Math.max(0, ...curve.map(Math.abs), ...cfg.bands.map(b => Math.abs(b.gain || 0)));
  range = Math.min(30, Math.max(12, Math.ceil((m + 2) / 6) * 6));
  const W = cv.clientWidth, H = cv.clientHeight;
  g2.clearRect(0, 0, W, H);
  g2.font = '9px -apple-system, system-ui, sans-serif'; g2.textAlign = 'center'; g2.textBaseline = 'middle';
  g2.strokeStyle = 'rgba(255,255,255,.07)'; g2.lineWidth = 1; g2.fillStyle = '#8c8d96';
  g2.beginPath();
  for (const f of [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) {
    const x = fx(f); g2.moveTo(x, plot.y); g2.lineTo(x, plot.y + plot.h);
    g2.fillText(f >= 1000 ? (f / 1000) + 'k' : f, x, plot.y + plot.h + 10);
  }
  const step = range > 18 ? 12 : 6;
  for (let g = -range; g <= range + 0.01; g += step) {
    const y = gy(g); g2.moveTo(plot.x, y); g2.lineTo(plot.x + plot.w, y);
    g2.fillText(g > 0 ? '+' + g : g, plot.x - 14, y);
  }
  g2.stroke();
  g2.strokeStyle = 'rgba(255,255,255,.18)'; g2.beginPath(); g2.moveTo(plot.x, gy(0)); g2.lineTo(plot.x + plot.w, gy(0)); g2.stroke();

  if (spectrum.length > 1) {
    g2.beginPath(); g2.moveTo(plot.x, plot.y + plot.h);
    spectrum.forEach((v, i) => {
      const n = Math.max(0, Math.min(1, (v + 100) / 90));
      g2.lineTo(plot.x + i / (spectrum.length - 1) * plot.w, plot.y + plot.h - n * plot.h * 0.85);
    });
    g2.lineTo(plot.x + plot.w, plot.y + plot.h); g2.closePath();
    const gr = g2.createLinearGradient(0, plot.y, 0, plot.y + plot.h);
    gr.addColorStop(0, 'rgba(255,255,255,.16)'); gr.addColorStop(1, 'rgba(255,255,255,.02)');
    g2.fillStyle = gr; g2.fill();
  }

  const si = cfg.bands.findIndex(b => b.id === selected);
  if (si >= 0) {
    const r = bandResponse(cfg.bands[si], FREQS, FS);
    g2.beginPath(); r.forEach((v, i) => { const x = fx(FREQS[i]), y = gy(Math.max(-range * 1.2, Math.min(range * 1.2, v))); i ? g2.lineTo(x, y) : g2.moveTo(x, y); });
    g2.lineTo(plot.x + plot.w, gy(0)); g2.lineTo(plot.x, gy(0)); g2.closePath();
    g2.fillStyle = COLORS[si % COLORS.length] + '38'; g2.fill();
  }

  g2.beginPath(); curve.forEach((v, i) => { const x = fx(FREQS[i]), y = gy(Math.max(-range * 1.2, Math.min(range * 1.2, v + 0))); i ? g2.lineTo(x, y) : g2.moveTo(x, y); });
  g2.shadowColor = 'rgba(255,179,64,.6)'; g2.shadowBlur = 8;
  g2.strokeStyle = '#ffb340'; g2.lineWidth = 2.2; g2.lineJoin = 'round'; g2.stroke();
  g2.shadowBlur = 0;

  cfg.bands.forEach((b, i) => {
    const p = nodePos(b), sel = b.id === selected, r = sel ? 10 : 7.5;
    g2.globalAlpha = b.on === false ? 0.35 : 1;
    g2.fillStyle = COLORS[i % COLORS.length]; g2.beginPath(); g2.arc(p.x, p.y, r, 0, Math.PI * 2); g2.fill();
    g2.globalAlpha = 1;
    if (sel) { g2.strokeStyle = 'rgba(255,255,255,.9)'; g2.lineWidth = 1.5; g2.beginPath(); g2.arc(p.x, p.y, r + 3, 0, Math.PI * 2); g2.stroke(); }
    g2.fillStyle = '#111'; g2.font = `bold ${sel ? 10 : 9}px -apple-system, system-ui, sans-serif`; g2.fillText(i + 1, p.x, p.y + 0.5);
  });
}

function hit(x, y) {
  let best = null, bd = 30;
  for (const b of cfg.bands) { const p = nodePos(b), d = Math.hypot(p.x - x, p.y - y); if (d < bd) { bd = d; best = b; } }
  return best;
}

// pointer interaction: drag one node, pinch (two pointers) or wheel to change Q
const pointers = new Map();
let drag = null, pinch = null;
function local(e) { const r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
cv.addEventListener('pointerdown', e => {
  cv.setPointerCapture(e.pointerId);
  const p = local(e); pointers.set(e.pointerId, p);
  if (pointers.size === 2 && selected) {
    const [a, b] = [...pointers.values()];
    const sb = cfg.bands.find(x => x.id === selected);
    pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), q: sb.q }; drag = null; return;
  }
  const b = hit(p.x, p.y);
  if (b) {
    const np = nodePos(b);
    drag = { id: b.id, dx: np.x - p.x, dy: np.y - p.y };
    if (selected !== b.id) { selected = b.id; renderEditor(); renderBandList(); }
    drawGraph();
  }
});
cv.addEventListener('pointermove', e => {
  if (!pointers.has(e.pointerId)) return;
  const p = local(e); pointers.set(e.pointerId, p);
  if (pinch && pointers.size === 2) {
    const [a, b] = [...pointers.values()], sb = cfg.bands.find(x => x.id === selected);
    if (sb) { sb.q = Math.round(Math.min(20, Math.max(0.1, pinch.q * pinch.d / Math.max(10, Math.hypot(a.x - b.x, a.y - b.y)))) * 100) / 100; refreshDrag(); }
    return;
  }
  if (!drag) return;
  const b = cfg.bands.find(x => x.id === drag.id); if (!b) return;
  const f = xf(p.x + drag.dx);
  b.freq = f < 1000 ? Math.round(f) : Math.round(f / 10) * 10;
  if (usesGain(b.type)) b.gain = Math.round(yg(p.y + drag.dy) * 10) / 10;
  refreshDrag();
});
function endPointer(e) { pointers.delete(e.pointerId); if (pointers.size < 2) pinch = null; if (!pointers.size) drag = null; }
cv.addEventListener('pointerup', endPointer); cv.addEventListener('pointercancel', endPointer);
cv.addEventListener('wheel', e => {
  const sb = cfg.bands.find(x => x.id === selected); if (!sb) return;
  e.preventDefault();
  sb.q = Math.round(Math.min(20, Math.max(0.1, sb.q * Math.exp(-e.deltaY * 0.002))) * 100) / 100;
  refreshDrag();
}, { passive: false });
cv.addEventListener('dblclick', e => {
  const p = local(e); if (hit(p.x, p.y)) return;
  addBand('peaking', Math.round(xf(p.x)), Math.round(yg(p.y) * 10) / 10);
});
function refreshDrag() { setPresetName(null); save(); drawGraph(); renderEditor(); renderBandList(); renderPreampInfo(); }

// ---------- bands ----------
function addBand(type, freq, gain) {
  const defaults = { peaking: 1000, lowshelf: 105, highshelf: 8000, highpass: 30, lowpass: 16000 };
  const b = band(type, freq || defaults[type] || 1000, gain || 0);
  cfg.bands.push(b); selected = b.id; setPresetName(null); onChange(true);
}
document.querySelectorAll('[data-add]').forEach(btn => btn.onclick = () => addBand(btn.dataset.add));

function renderBandList() {
  const box = $('#bands'); box.textContent = '';
  $('#bandCount').textContent = cfg.bands.length + (cfg.bands.length === 1 ? ' band' : ' bands');
  cfg.bands.forEach((b, i) => {
    const row = document.createElement('div');
    row.className = 'band' + (b.id === selected ? ' sel' : '') + (b.on === false ? ' offband' : '');
    const dot = document.createElement('div'); dot.className = 'dot'; dot.style.background = COLORS[i % COLORS.length]; dot.textContent = i + 1;
    const meta = document.createElement('div'); meta.className = 'meta';
    const t = document.createElement('div'); t.textContent = TYPE_LABEL[b.type];
    const s = document.createElement('small'); s.textContent = [fmt.hz(b.freq), usesGain(b.type) ? fmt.db(b.gain) : null, 'Q ' + fmt.q(b.q)].filter(Boolean).join('  ·  ');
    meta.append(t, s);
    const pw = document.createElement('button'); pw.textContent = b.on === false ? '○' : '⏻'; pw.title = 'On/off';
    pw.style.color = b.on === false ? '#8c8d96' : '#ffb340';
    pw.onclick = (e) => { e.stopPropagation(); b.on = b.on === false; setPresetName(null); onChange(true); };
    const del = document.createElement('button'); del.textContent = '✕'; del.title = 'Delete'; del.style.color = '#8c8d96';
    del.onclick = (e) => { e.stopPropagation(); removeBand(b.id); };
    row.append(dot, meta, pw, del);
    row.onclick = () => { selected = b.id; renderAll(); };
    box.append(row);
  });
}
function removeBand(id) { cfg.bands = cfg.bands.filter(b => b.id !== id); if (selected === id) selected = null; setPresetName(null); onChange(true); }

function renderEditor() {
  const ed = $('#editor'), b = cfg.bands.find(x => x.id === selected);
  if (!b) { ed.classList.add('hidden'); return; }
  // don't rebuild while a slider inside is being dragged
  if (ed.contains(document.activeElement) && document.activeElement.type === 'range') {
    ed.querySelectorAll('.param').forEach(p => p._show && p._show()); return;
  }
  ed.classList.remove('hidden'); ed.textContent = '';
  const i = cfg.bands.indexOf(b);
  const head = document.createElement('div'); head.className = 'row head';
  const h = document.createElement('h3'); h.textContent = 'Band ' + (i + 1); h.style.color = COLORS[i % COLORS.length];
  const sel = document.createElement('select');
  for (const [v, l] of TYPES) { const o = document.createElement('option'); o.value = v; o.textContent = l; if (v === b.type) o.selected = true; sel.append(o); }
  sel.style.width = 'auto';
  sel.onchange = () => { b.type = sel.value; setPresetName(null); onChange(true); };
  const done = document.createElement('button'); done.className = 'small'; done.textContent = 'Done';
  done.onclick = () => { selected = null; renderAll(); };
  head.append(h, sel, done); ed.append(head);
  const mk = (...a) => { const w = param(ed, ...a); return w; };
  mk('Frequency', () => b.freq, v => { b.freq = v; setPresetName(null); }, 20, 20000, { log: true, fmt: fmt.hz });
  mk('Gain', () => b.gain, v => { b.gain = v; setPresetName(null); }, -24, 24, { step: 0.1, fmt: fmt.db, disabled: !usesGain(b.type) });
  mk('Q', () => b.q, v => { b.q = v; setPresetName(null); }, 0.1, 20, { log: true, fmt: fmt.q });
}

// ---------- preamp ----------
function curvePeak() { return Math.max(...response(cfg.bands, logFreqs(400), FS)); }
function renderPreamp() {
  const c = $('#preampCard'); c.textContent = '';
  param(c, 'Preamp', () => cfg.preamp, v => { cfg.preamp = v; setPresetName(null); }, -30, 12, { step: 0.1, fmt: fmt.db });
  const row = document.createElement('div'); row.className = 'row head';
  const info = document.createElement('small'); info.id = 'headroom';
  const auto = document.createElement('button'); auto.className = 'small'; auto.textContent = 'Auto';
  auto.onclick = () => { cfg.preamp = -Math.ceil(Math.max(0, curvePeak()) * 10) / 10; onChange(true); };
  row.append(info, auto); c.append(row);
  renderPreampInfo();
}
function renderPreampInfo() {
  const el = $('#headroom'); if (!el) return;
  const h = curvePeak() + cfg.preamp;
  el.textContent = h > 0.05 ? `Clips by ${h.toFixed(1)} dB (limiter catches it)` : 'No clipping';
  el.style.color = h > 0.05 ? '#ffb340' : '#8c8d96';
  const pre = $('#preampCard .param');
  if (pre) { pre.querySelector('.val').textContent = fmt.db(cfg.preamp); pre.querySelector('input').value = Math.round((cfg.preamp + 30) / 42 * 1000); }
}

// ---------- effects ----------
function fxBlock(parent, title, key, note, build) {
  const s = cfg[key];
  const box = document.createElement('div'); box.className = 'fx';
  const top = document.createElement('div'); top.className = 'top';
  const t = document.createElement('span'); t.textContent = title;
  top.append(t, toggle(!!s.on, v => { s.on = v; onChange(true); }));
  box.append(top);
  if (note) { const n = document.createElement('div'); n.className = 'note'; n.textContent = note; box.append(n); }
  if (s.on) build(box, s);
  parent.append(box);
}

function renderEffects() {
  const e = $('#effects'); e.textContent = '';
  fxBlock(e, 'Spatial', 'spatial', 'Left and right become virtual speakers in front of you (HRTF). Headphones.', (b, s) => {
    chips(b, SPATIAL_PRESETS, p => { s.angle = p[1]; s.distance = p[2]; s.amount = p[3]; onChange(true); });
    param(b, 'Speaker angle', () => s.angle, v => s.angle = v, 5, 90, { step: 1, fmt: fmt.deg });
    param(b, 'Distance', () => s.distance, v => s.distance = v, 0.3, 5, { step: 0.1, fmt: fmt.m });
    param(b, 'Elevation', () => s.elevation, v => s.elevation = v, -45, 45, { step: 1, fmt: fmt.deg });
    param(b, 'Amount', () => s.amount, v => s.amount = v, 0, 1, { step: 0.01, fmt: fmt.pct });
  });
  fxBlock(e, 'Reverb', 'reverb', null, (b, s) => {
    chips(b, REVERB_PRESETS, p => { Object.assign(s, { decay: p[1], predelay: p[2], damping: p[3], mix: p[4] }); onChange(true); });
    param(b, 'Mix', () => s.mix, v => s.mix = v, 0, 1, { step: 0.01, fmt: fmt.pct });
    param(b, 'Decay', () => s.decay, v => s.decay = v, 0.2, 8, { log: true, fmt: fmt.s });
    param(b, 'Pre-delay', () => s.predelay, v => s.predelay = v, 0, 200, { step: 1, fmt: fmt.ms });
    param(b, 'Damping', () => s.damping, v => s.damping = v, 1000, 16000, { log: true, fmt: fmt.hz });
    param(b, 'Stereo width', () => s.width, v => s.width = v, 0, 1, { step: 0.01, fmt: fmt.pct });
  });
  fxBlock(e, 'Crossfeed', 'crossfeed', 'Bleeds a little of each channel into the other, like speakers.', (b, s) => {
    chips(b, CROSSFEED_PRESETS, p => { s.level = p[1]; s.cutoff = p[2]; onChange(true); });
    param(b, 'Level', () => s.level, v => s.level = v, -20, -1, { step: 0.5, fmt: fmt.db });
    param(b, 'Cutoff', () => s.cutoff, v => s.cutoff = v, 300, 1500, { step: 10, fmt: fmt.hz });
    param(b, 'Delay', () => s.delay, v => s.delay = v, 0, 0.8, { step: 0.01, fmt: v => v.toFixed(2) + ' ms' });
  });
  fxBlock(e, 'Stereo', 'width', null, (b, s) => {
    param(b, 'Width', () => s.width, v => s.width = v, 0, 2.5, { step: 0.01, fmt: fmt.pct, disabled: s.mono });
    param(b, 'Balance', () => s.balance, v => s.balance = v, -1, 1, { step: 0.01, fmt: v => Math.abs(v) < 0.01 ? 'Center' : (v < 0 ? 'L ' : 'R ') + Math.round(Math.abs(v) * 100) + '%' });
    for (const [k, l] of [['mono', 'Mono'], ['swap', 'Swap L / R']]) {
      const r = document.createElement('div'); r.className = 'row head'; const t = document.createElement('span'); t.textContent = l;
      r.append(t, toggle(!!s[k], v => { s[k] = v; onChange(true); })); b.append(r);
    }
  });
  fxBlock(e, 'Compressor', 'comp', null, (b, s) => {
    param(b, 'Threshold', () => s.threshold, v => s.threshold = v, -60, 0, { step: 0.5, fmt: fmt.db });
    param(b, 'Ratio', () => s.ratio, v => s.ratio = v, 1, 20, { log: true, fmt: fmt.ratio });
    param(b, 'Knee', () => s.knee, v => s.knee = v, 0, 40, { step: 0.5, fmt: fmt.db });
    param(b, 'Attack', () => s.attack, v => s.attack = v, 0.1, 200, { log: true, fmt: fmt.ms });
    param(b, 'Release', () => s.release, v => s.release = v, 10, 1000, { log: true, fmt: fmt.ms });
    param(b, 'Makeup', () => s.makeup, v => s.makeup = v, -12, 24, { step: 0.1, fmt: fmt.db });
  });
  fxBlock(e, 'Limiter', 'limiter', null, (b, s) => {
    param(b, 'Ceiling', () => s.ceiling, v => s.ceiling = v, -12, 0, { step: 0.1, fmt: fmt.db });
  });
  const out = document.createElement('div'); out.className = 'fx';
  param(out, 'Output gain', () => cfg.output, v => cfg.output = v, -24, 12, { step: 0.1, fmt: fmt.db });
  e.append(out);
}

// ---------- presets ----------
function spark(bands) {
  const c = document.createElement('canvas'); c.width = 128; c.height = 40;
  const x = c.getContext('2d'), fr = logFreqs(40), r = response(bands, fr, FS), m = Math.max(6, ...r.map(Math.abs));
  x.beginPath(); r.forEach((v, i) => { const px = i / (r.length - 1) * 128, py = 20 - v / m * 18; i ? x.lineTo(px, py) : x.moveTo(px, py); });
  x.strokeStyle = 'rgba(255,179,64,.85)'; x.lineWidth = 3; x.stroke();
  return c;
}
function applyPreset(p) {
  cfg.preamp = p.preamp;
  cfg.bands = p.bands.map(b => Object.assign({}, b, { id: uid() }));
  if (p.effects) Object.assign(cfg, JSON.parse(JSON.stringify(p.effects)));
  selected = null; setPresetName(p.name); onChange(true); toast(p.name);
}
function renderPresets() {
  const box = $('#presets'); box.textContent = '';
  const add = (p, removable) => {
    const row = document.createElement('div'); row.className = 'preset';
    const n = document.createElement('div'); n.className = 'name'; n.textContent = p.name;
    const s = document.createElement('small'); s.textContent = p.bands.length + (p.effects ? ' + fx' : '');
    row.append(n, s, spark(p.bands));
    if (removable) {
      const x = document.createElement('button'); x.className = 'x'; x.textContent = '✕';
      x.onclick = (e) => { e.stopPropagation(); presets = presets.filter(q => q.id !== p.id); savePresets(); renderPresets(); };
      row.append(x);
    }
    row.onclick = () => applyPreset(p);
    box.append(row);
  };
  presets.forEach(p => add(p, true));
  if (presets.length) { const h = document.createElement('h4'); h.textContent = 'Built-in'; box.append(h); }
  BUILTIN.forEach(p => add(p, false));
}
$('#save').onclick = () => {
  const name = $('#saveName').value.trim(); if (!name) return toast('Name it first');
  const p = { id: uid(), name, preamp: cfg.preamp, bands: JSON.parse(JSON.stringify(cfg.bands)) };
  if ($('#saveFx').checked) {
    p.effects = {};
    for (const k of ['output', 'comp', 'crossfeed', 'width', 'spatial', 'reverb', 'limiter']) p.effects[k] = JSON.parse(JSON.stringify(cfg[k]));
  }
  presets = [p, ...presets.filter(q => q.name !== name)];
  presetName = name; savePresets(); setPresetName(name); renderPresets(); toast('Saved ' + name);
};

// ---------- AutoEq ----------
const AEQ = 'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/';
async function loadIndex() {
  if (aeqIndex) return aeqIndex;
  const c = await ext.storage.local.get(['aeqIndex', 'aeqTime']);
  if (c.aeqIndex && Date.now() - (c.aeqTime || 0) < 7 * 864e5) return (aeqIndex = c.aeqIndex);
  const text = await (await fetch(AEQ + 'INDEX.md')).text();
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.startsWith('- [')) continue;
    const close = line.indexOf('](./'); if (close < 0) continue;
    const name = line.slice(3, close), rest = line.slice(close + 4), by = rest.lastIndexOf(') by ');
    if (by < 0) continue;
    out.push([name, rest.slice(by + 5), rest.slice(0, by)]);
  }
  ext.storage.local.set({ aeqIndex: out, aeqTime: Date.now() });
  return (aeqIndex = out);
}
let aeqTimer = null;
$('#aeq').addEventListener('focus', () => loadIndex().catch(e => toast('AutoEq: ' + e.message)), { once: true });
$('#aeq').addEventListener('input', () => {
  clearTimeout(aeqTimer);
  aeqTimer = setTimeout(async () => {
    const box = $('#aeqResults'); box.textContent = '';
    const terms = $('#aeq').value.toLowerCase().split(/\s+/).filter(Boolean); if (!terms.length) return;
    let idx; try { idx = await loadIndex(); } catch (e) { return toast('AutoEq: ' + e.message); }
    const hits = idx.filter(e => { const h = (e[0] + ' ' + e[1]).toLowerCase(); return terms.every(t => h.includes(t)); }).slice(0, 80);
    if (!hits.length) { box.textContent = 'Nothing matches.'; return; }
    for (const [name, source, path] of hits) {
      const row = document.createElement('div'); row.className = 'preset';
      const n = document.createElement('div'); n.className = 'name'; n.textContent = name;
      const s = document.createElement('small'); s.textContent = source; n.append(s);
      row.append(n);
      row.onclick = async () => {
        try {
          const last = path.split('/').pop();
          const r = await fetch(AEQ + path + '/' + last + '%20ParametricEQ.txt');
          if (!r.ok) throw new Error('no parametric profile (HTTP ' + r.status + ')');
          const res = parseAPO(await r.text());
          const p = { id: uid(), name, preamp: res.preamp, bands: res.bands };
          presets = [p, ...presets.filter(q => q.name !== name)]; savePresets(); applyPreset(p); renderPresets();
        } catch (e) { toast(e.message); }
      };
      box.append(row);
    }
  }, 200);
});

// ---------- import / export ----------
$('#importFile').onchange = async (e) => {
  const f = e.target.files[0]; if (!f) return;
  try {
    if (/\.eqf$/i.test(f.name)) {
      const ps = parseWinamp(await f.arrayBuffer());
      presets = [...ps, ...presets]; savePresets(); applyPreset(ps[0]); renderPresets();
      toast(ps.length > 1 ? `Imported ${ps.length} Winamp presets` : 'Imported ' + ps[0].name);
    } else {
      const r = parseAPO(await f.text()), name = f.name.replace(/\.[^.]+$/, '');
      const p = { id: uid(), name, preamp: r.preamp, bands: r.bands };
      presets = [p, ...presets.filter(q => q.name !== name)]; savePresets(); applyPreset(p); renderPresets();
    }
  } catch (err) { toast(err.message); }
  e.target.value = '';
};
$('#pasteBtn').onclick = () => {
  const a = $('#pasteArea');
  if (a.classList.contains('hidden')) { a.classList.remove('hidden'); a.focus(); return; }
  try { const r = parseAPO(a.value); applyPreset({ name: 'Pasted', preamp: r.preamp, bands: r.bands }); a.classList.add('hidden'); a.value = ''; }
  catch (err) { toast(err.message); }
};
$('#exportBtn').onclick = async () => {
  const text = exportAPO(cfg.preamp, cfg.bands);
  try { await navigator.clipboard.writeText(text); toast('Copied EqualizerAPO text'); }
  catch (e) {
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
    a.download = (presetName || 'Timbre') + ' ParametricEQ.txt'; a.click();
  }
};
$('#flatBtn').onclick = () => { cfg.bands = []; cfg.preamp = 0; selected = null; setPresetName('Flat'); onChange(true); };

// ---------- status, site toggle, spectrum ----------
const LABELS = {
  idle: 'Waiting for audio', active: 'EQ live', drm: "DRM audio, can't EQ", cors: "Cross-origin audio, can't EQ",
  silent: "Stream went silent once routed", error: 'Engine error', off: 'Off for this site'
};
function siteHost() { try { return new URL(tab.url).hostname.replace(/^www\./, ''); } catch (e) { return null; } }
function siteOff() { const h = siteHost(); return !!h && disabledHosts.some(d => h === d || h.endsWith('.' + d)); }
function renderSite() {
  const b = $('#siteToggle'), h = siteHost();
  b.classList.toggle('hidden', !h);
  b.classList.toggle('on', siteOff());
  b.textContent = siteOff() ? 'Off here' : 'On here';
  b.title = h ? (siteOff() ? 'Turn Timbre back on for ' : 'Turn Timbre off for ') + h : '';
}
$('#siteToggle').onclick = () => {
  const h = siteHost(); if (!h) return;
  disabledHosts = siteOff() ? disabledHosts.filter(d => !(h === d || h.endsWith('.' + d))) : [...disabledHosts, h];
  ext.storage.local.set({ disabledHosts }); renderSite();
};
async function pollStatus() {
  if (!tab) return;
  try {
    const r = await ext.runtime.sendMessage({ kind: 'getStatus', tabId: tab.id });
    const s = r.status, el = $('#status');
    let t = LABELS[s.state] || s.state;
    if (s.state === 'active' && s.streams > 1) t += ` · ${s.streams} streams`;
    if (r.nowplaying && r.nowplaying.title) t += ' · ' + r.nowplaying.title;
    if (siteOff()) t = LABELS.off;
    el.textContent = t;
    el.className = 'status' + (s.state === 'active' ? ' active' : ['drm', 'cors', 'silent', 'error'].includes(s.state) ? ' bad' : '');
  } catch (e) {}
  try { await ext.tabs.sendMessage(tab.id, { kind: 'wantSpectrum' }); } catch (e) {}
}
ext.runtime.onMessage.addListener((m) => { if (m && m.kind === 'spectrum') { spectrum = m.bins; if (!pointers.size) drawGraph(); } });

// ---------- boot ----------
function renderAll() { renderEditor(); renderPreamp(); renderBandList(); renderEffects(); drawGraph(); }

$('#enabled').addEventListener('change', e => { cfg.enabled = e.target.checked; onChange(false); });

(async () => {
  const r = await ext.storage.local.get(['config', 'presets', 'presetName', 'disabledHosts']);
  cfg = mergeDefaults(r.config || defaultConfig());
  presets = r.presets || []; disabledHosts = r.disabledHosts || [];
  setPresetName(r.presetName || null);
  $('#enabled').checked = cfg.enabled;
  try { [tab] = await ext.tabs.query({ active: true, currentWindow: true }); } catch (e) {}
  sizeCanvas(); renderAll(); renderPresets(); renderSite();
  if (tab) { try { await ext.tabs.sendMessage(tab.id, { kind: 'report' }); } catch (e) {} }
  pollStatus(); setInterval(pollStatus, 1000);
  window.addEventListener('resize', () => { sizeCanvas(); drawGraph(); });
})();
