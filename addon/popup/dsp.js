// Filter math, presets and EQ file formats. Mirrors the app's FilterMath / PresetIO.
'use strict';

const TYPES = [
  ['peaking', 'Peak', 'PK'], ['lowshelf', 'Low Shelf', 'LSC'], ['highshelf', 'High Shelf', 'HSC'],
  ['lowpass', 'Low Pass', 'LPQ'], ['highpass', 'High Pass', 'HPQ'], ['bandpass', 'Band Pass', 'BP'],
  ['notch', 'Notch', 'NO'], ['allpass', 'All Pass', 'AP']
];
const TYPE_LABEL = Object.fromEntries(TYPES.map(t => [t[0], t[1]]));
const TYPE_CODE = Object.fromEntries(TYPES.map(t => [t[0], t[2]]));
const usesGain = t => t === 'peaking' || t === 'lowshelf' || t === 'highshelf';

function uid() { return Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4); }
function band(type, freq, gain, q) { return { id: uid(), on: true, type, freq, gain: gain || 0, q: q || (type === 'peaking' ? 1 : 0.707) }; }

function rbj(b, fs) {
  const f = Math.min(Math.max(b.freq, 10), fs * 0.49), q = Math.min(Math.max(b.q, 0.05), 40);
  const A = Math.pow(10, (b.gain || 0) / 40), w0 = 2 * Math.PI * f / fs;
  const c = Math.cos(w0), s = Math.sin(w0), al = s / (2 * q), sA = 2 * Math.sqrt(A) * al;
  switch (b.type) {
    case 'peaking': return [1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A];
    case 'lowpass': return [(1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al];
    case 'highpass': return [(1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al];
    case 'bandpass': return [al, 0, -al, 1 + al, -2 * c, 1 - al];
    case 'notch': return [1, -2 * c, 1, 1 + al, -2 * c, 1 - al];
    case 'allpass': return [1 - al, -2 * c, 1 + al, 1 + al, -2 * c, 1 - al];
    case 'lowshelf': return [A * ((A + 1) - (A - 1) * c + sA), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sA),
      (A + 1) + (A - 1) * c + sA, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sA];
    default: return [A * ((A + 1) + (A - 1) * c + sA), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sA),
      (A + 1) - (A - 1) * c + sA, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sA];
  }
}

function mag(k, f, fs) {
  const w = 2 * Math.PI * f / fs, c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
  const nr = k[0] + k[1] * c1 + k[2] * c2, ni = -(k[1] * s1 + k[2] * s2);
  const dr = k[3] + k[4] * c1 + k[5] * c2, di = -(k[4] * s1 + k[5] * s2);
  const num = nr * nr + ni * ni, den = dr * dr + di * di;
  if (!(den > 0) || !(num > 0)) return -120;
  return Math.max(-120, 10 * Math.log10(num / den));
}

function logFreqs(n, lo = 20, hi = 20000) {
  const a = Math.log(lo), b = Math.log(hi);
  return Array.from({ length: n }, (_, i) => Math.exp(a + (b - a) * i / (n - 1)));
}

function response(bands, freqs, fs) {
  const ks = bands.filter(b => b.on !== false).map(b => rbj(b, fs));
  return freqs.map(f => ks.reduce((acc, k) => acc + mag(k, f, fs), 0));
}
function bandResponse(b, freqs, fs) { const k = rbj(b, fs); return freqs.map(f => mag(k, f, fs)); }
function qFromOctaves(n) { const p = Math.pow(2, n); return Math.sqrt(p) / (p - 1); }

// Equalizer APO / AutoEq ParametricEQ.txt
function parseAPO(text) {
  let preamp = 0; const bands = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const lower = line.toLowerCase();
    if (lower.startsWith('preamp:')) { const v = parseFloat(line.slice(7)); if (isFinite(v)) preamp = v; continue; }
    if (lower.startsWith('graphiceq:')) throw new Error("GraphicEQ files aren't supported, use the ParametricEQ version.");
    if (!lower.startsWith('filter') || line.indexOf(':') < 0) continue;
    const t = line.slice(line.indexOf(':') + 1).trim().split(/\s+/);
    let i = 0, on = true;
    if (/^on$/i.test(t[i])) i++; else if (/^off$/i.test(t[i])) { on = false; i++; }
    const code = (t[i++] || '').toUpperCase();
    const map = { PK: 'peaking', PEQ: 'peaking', MODAL: 'peaking', LS: 'lowshelf', LSC: 'lowshelf', LSQ: 'lowshelf',
      HS: 'highshelf', HSC: 'highshelf', HSQ: 'highshelf', LP: 'lowpass', LPQ: 'lowpass', HP: 'highpass', HPQ: 'highpass',
      BP: 'bandpass', NO: 'notch', AP: 'allpass' };
    const type = map[code]; if (!type) continue;
    let fc = null, gain = 0, q = null;
    while (i < t.length) {
      const k = t[i].toLowerCase();
      if (k === 'fc') { fc = parseFloat(t[i + 1]); i += 2; }
      else if (k === 'gain') { gain = parseFloat(t[i + 1]) || 0; i += 2; }
      else if (k === 'q') { q = parseFloat(t[i + 1]); i += 2; }
      else if (k === 'bw' && (t[i + 1] || '').toLowerCase() === 'oct') { q = qFromOctaves(parseFloat(t[i + 2])); i += 3; }
      else i++;
    }
    if (!(fc > 0)) continue;
    const b = band(type, fc, gain, q || (type === 'peaking' ? 1 : type === 'notch' ? 4 : 0.707));
    b.on = on; bands.push(b);
  }
  if (!bands.length) throw new Error('No filters found in that file.');
  return { preamp, bands };
}

function exportAPO(preamp, bands) {
  let out = `Preamp: ${preamp.toFixed(1)} dB\n`;
  bands.forEach((b, n) => {
    out += `Filter ${n + 1}: ${b.on !== false ? 'ON' : 'OFF'} ${TYPE_CODE[b.type]} Fc ${Math.round(b.freq)} Hz Gain ${(b.gain || 0).toFixed(1)} dB Q ${b.q.toFixed(2)}\n`;
  });
  return out;
}

// Winamp .EQF library: 31-byte header, entries of 257-byte name + 10 bands + preamp (0..63, 0 = +12 dB)
const WINAMP_FREQS = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];
function parseWinamp(buf) {
  const u = new Uint8Array(buf), head = 'Winamp EQ library file v1.1';
  if (u.length < 31 + 268 || String.fromCharCode(...u.slice(0, head.length)) !== head) throw new Error("That isn't a Winamp EQF file.");
  const db = v => Math.round((31.5 - Math.min(v, 63)) / 31.5 * 120) / 10;
  const out = [];
  for (let off = 31; off + 268 <= u.length; off += 268) {
    let name = ''; for (let i = 0; i < 257 && u[off + i]; i++) name += String.fromCharCode(u[off + i]);
    out.push({ id: uid(), name: name || 'Winamp', preamp: db(u[off + 267]),
      bands: WINAMP_FREQS.map((f, i) => band('peaking', f, db(u[off + 257 + i]), 1.41)) });
  }
  return out;
}

const BUILTIN = [
  { id: 'b.flat', name: 'Flat', preamp: 0, bands: [] },
  { id: 'b.bass', name: 'Bass Boost', preamp: -6, bands: [band('lowshelf', 105, 6, 0.7), band('peaking', 40, 1.5, 1)] },
  { id: 'b.v', name: 'V-Shape', preamp: -5, bands: [band('lowshelf', 120, 5, 0.7), band('peaking', 1500, -2.5, 0.8), band('highshelf', 8000, 4, 0.7)] },
  { id: 'b.vocal', name: 'Vocal Presence', preamp: -3, bands: [band('highpass', 60, 0, 0.707), band('peaking', 250, -2, 1), band('peaking', 2500, 3, 1.2), band('peaking', 5000, 1.5, 2)] },
  { id: 'b.treble', name: 'Treble Boost', preamp: -4, bands: [band('highshelf', 6000, 4, 0.7)] }
];

const REVERB_PRESETS = [
  ['Room', 0.6, 6, 7000, 0.2], ['Studio', 1.0, 12, 6000, 0.2], ['Plate', 1.6, 4, 10000, 0.25],
  ['Hall', 2.6, 28, 4500, 0.25], ['Cathedral', 5.5, 60, 3000, 0.3]
];
const SPATIAL_PRESETS = [['Front stage', 15, 1, 0.7], ['Near-field', 30, 1, 0.8], ['Wide room', 55, 2, 0.9], ['Surround-ish', 80, 1.5, 1]];
const CROSSFEED_PRESETS = [['Subtle', -9.5, 650], ['Natural', -6, 700], ['Speakers', -4.5, 750], ['Strong', -3, 850]];

function defaultConfig() {
  return {
    enabled: true, preamp: 0, output: 0, spectrum: false, bands: [],
    comp: { on: false, threshold: -24, knee: 6, ratio: 3, attack: 10, release: 150, makeup: 0 },
    crossfeed: { on: false, level: -6, cutoff: 700, delay: 0.3 },
    width: { on: false, width: 1, balance: 0, mono: false, swap: false },
    spatial: { on: false, angle: 30, amount: 0.8, distance: 1, elevation: 0 },
    reverb: { on: false, decay: 1.8, predelay: 20, damping: 6000, width: 1, mix: 0.25 },
    limiter: { on: true, ceiling: -1 }
  };
}

if (typeof module !== 'undefined') module.exports = { rbj, mag, response, parseAPO, exportAPO, parseWinamp, logFreqs, defaultConfig };
