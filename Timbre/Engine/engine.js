// Timbre audio engine. Injected into every frame (page world) at document start.
// Routes page media through a Web Audio chain:
//   source -> preamp -> parametric bands -> compressor -> crossfeed -> width/balance
//          -> spatial (HRTF) -> reverb -> output gain -> limiter -> analyser -> out
// The native app pushes config with window.__timbre.apply(cfg). Frames relay it to child frames.
(function () {
  'use strict';
  if (window.__timbre) return;

  var boot = window.__TIMBRE_BOOT || {};
  var cfg = boot.config || { enabled: true, bands: [] };
  var host = '';
  try { host = location.hostname; } catch (e) {}
  var disabledHere = (boot.disabledHosts || []).some(function (h) {
    return h && (host === h || host.endsWith('.' + h));
  });

  function hostIn(list) {
    return (list || []).some(function (h) { return h && (host === h || host.endsWith('.' + h)); });
  }

  // Compatibility mode: iOS WebKit doesn't pass MediaSource (blob:) streams into Web Audio, so routing
  // them gives silence. Hiding MSE before the page's scripts run makes players like YouTube fall back
  // to HLS / progressive files, which WebKit can tap.
  var compat = !disabledHere && hostIn(boot.compatHosts);
  if (compat) {
    ['MediaSource', 'ManagedMediaSource', 'WebKitMediaSource'].forEach(function (k) {
      try { Object.defineProperty(window, k, { value: undefined, configurable: true, writable: true }); } catch (e) {}
      try { delete window[k]; } catch (e) {}
    });
  }

  var native = null;
  try { native = window.webkit.messageHandlers.timbre; } catch (e) {}
  function post(msg) {
    if (!native) return;
    try { msg.frame = host; msg.top = (window === window.top); native.postMessage(msg); } catch (e) {}
  }

  // ---------- keep playing in background (page visibility spoof) ----------
  if (boot.background) {
    try {
      var vis = { get: function () { return 'visible'; }, configurable: true };
      var hid = { get: function () { return false; }, configurable: true };
      Object.defineProperty(Document.prototype, 'visibilityState', vis);
      Object.defineProperty(Document.prototype, 'hidden', hid);
      Object.defineProperty(Document.prototype, 'webkitVisibilityState', vis);
      Object.defineProperty(Document.prototype, 'webkitHidden', hid);
      var block = function (e) { e.stopImmediatePropagation(); };
      window.addEventListener('visibilitychange', block, true);
      document.addEventListener('visibilitychange', block, true);
      document.addEventListener('webkitvisibilitychange', block, true);
      window.addEventListener('pagehide', block, true);
      window.addEventListener('blur', block, true);
    } catch (e) {}
  }

  // ---------- helpers ----------
  function dbToLin(db) { return Math.pow(10, db / 20); }
  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
  function num(v, d) { return (typeof v === 'number' && isFinite(v)) ? v : d; }
  var TC = 0.015; // param smoothing time constant (s)
  function setP(param, v) {
    if (!param) return;
    try { param.setTargetAtTime(v, ctx.currentTime, TC); } catch (e) { try { param.value = v; } catch (e2) {} }
  }

  var ctx = null;
  var G = null;            // graph
  var attached = new Map(); // element -> MediaElementSourceNode
  var seen = new Set();     // media elements we've noticed
  var drmEls = new WeakSet();
  var state = disabledHere ? 'off' : 'idle';
  var lastStatus = '';

  function status(s, extra) {
    state = s;
    var key = s + ':' + attached.size + ':' + (extra || '');
    if (key === lastStatus) return;
    lastStatus = key;
    post({ type: 'status', state: s, streams: attached.size, detail: extra || '', sampleRate: ctx ? ctx.sampleRate : 0 });
  }

  // ---------- crossfading slot (for nodes whose coefficients/buffers can't change live) ----------
  function Slot() {
    this.input = ctx.createGain();
    this.output = ctx.createGain();
    this.cur = null; // {node, gain}
    this.key = null;
  }
  Slot.prototype.swap = function (node, key) {
    if (key !== undefined && key === this.key) return;
    this.key = key;
    var g = ctx.createGain();
    var t = ctx.currentTime;
    g.gain.setValueAtTime(this.cur ? 0 : 1, t);
    this.input.connect(node); node.connect(g); g.connect(this.output);
    if (this.cur) {
      g.gain.linearRampToValueAtTime(1, t + 0.04);
      var old = this.cur;
      old.gain.gain.cancelScheduledValues(t);
      old.gain.gain.setValueAtTime(old.gain.gain.value, t);
      old.gain.gain.linearRampToValueAtTime(0, t + 0.04);
      setTimeout(function () { try { old.node.disconnect(); old.gain.disconnect(); } catch (e) {} }, 120);
    }
    this.cur = { node: node, gain: g };
  };

  // ---------- bypassable stage ----------
  function Stage() {
    this.input = ctx.createGain();
    this.output = ctx.createGain();
    this.dry = ctx.createGain();
    this.wet = ctx.createGain();
    this.input.connect(this.dry); this.dry.connect(this.output);
    this.wet.connect(this.output);
    this.dry.gain.value = 1; this.wet.gain.value = 0;
    this.on = false;
  }
  Stage.prototype.mix = function (dry, wet) { setP(this.dry.gain, dry); setP(this.wet.gain, wet); };

  // ---------- filter math (RBJ cookbook) ----------
  function shelfCoeffs(type, f, gain, q, fs) {
    var A = Math.pow(10, gain / 40);
    var w0 = 2 * Math.PI * clamp(f, 1, fs * 0.49) / fs;
    var cs = Math.cos(w0), sn = Math.sin(w0);
    var alpha = sn / (2 * Math.max(q, 0.01));
    var sA = 2 * Math.sqrt(A) * alpha;
    if (type === 'lowshelf') {
      return {
        b: [A * ((A + 1) - (A - 1) * cs + sA), 2 * A * ((A - 1) - (A + 1) * cs), A * ((A + 1) - (A - 1) * cs - sA)],
        a: [(A + 1) + (A - 1) * cs + sA, -2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - sA]
      };
    }
    return {
      b: [A * ((A + 1) + (A - 1) * cs + sA), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - sA)],
      a: [(A + 1) - (A - 1) * cs + sA, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - sA]
    };
  }

  // A band: BiquadFilterNode for most types; shelves use IIR (WebKit's biquad shelves ignore Q).
  function Band() { this.node = null; this.slot = null; this.kind = null; }
  Band.prototype.build = function (b) {
    var shelf = (b.type === 'lowshelf' || b.type === 'highshelf');
    this.kind = shelf ? 'iir' : 'biquad';
    if (shelf) {
      this.slot = new Slot();
      this.input = this.slot.input; this.output = this.slot.output;
    } else {
      this.node = ctx.createBiquadFilter();
      this.node.type = b.type;
      this.input = this.output = this.node;
    }
    this.update(b, true);
  };
  Band.prototype.update = function (b, first) {
    var fs = ctx.sampleRate;
    var f = clamp(num(b.freq, 1000), 10, fs * 0.49);
    var q = clamp(num(b.q, 0.707), 0.05, 40);
    var g = clamp(num(b.gain, 0), -30, 30);
    if (this.kind === 'iir') {
      var c = shelfCoeffs(b.type, f, g, q, fs);
      var key = b.type + f.toFixed(2) + '|' + g.toFixed(2) + '|' + q.toFixed(3);
      var n;
      try { n = ctx.createIIRFilter(c.b, c.a); }
      catch (e) { n = ctx.createBiquadFilter(); n.type = b.type; n.frequency.value = f; n.gain.value = g; }
      this.slot.swap(n, key);
    } else {
      var n2 = this.node;
      // Web Audio interprets Q for lowpass/highpass in dB; everything else is linear.
      var qv = (b.type === 'lowpass' || b.type === 'highpass') ? 20 * Math.log10(q) : q;
      if (first) { n2.frequency.value = f; n2.Q.value = qv; n2.gain.value = g; }
      else { setP(n2.frequency, f); setP(n2.Q, qv); setP(n2.gain, g); }
    }
  };
  Band.prototype.disconnect = function () {
    try { this.output.disconnect(); } catch (e) {}
  };

  // ---------- graph ----------
  function buildGraph() {
    G = {};
    G.input = ctx.createGain(); // all sources connect here
    G.input.channelCount = 2; G.input.channelCountMode = 'explicit'; G.input.channelInterpretation = 'speakers';
    G.preamp = ctx.createGain();
    G.input.connect(G.preamp);
    G.bandsOut = ctx.createGain();
    G.bands = {}; G.bandOrder = []; G.bandSig = null;

    // compressor
    G.comp = new Stage();
    G.compNode = ctx.createDynamicsCompressor();
    G.compMakeup = ctx.createGain();
    G.comp.input.connect(G.compNode); G.compNode.connect(G.compMakeup); G.compMakeup.connect(G.comp.wet);
    G.bandsOut.connect(G.comp.input);

    // crossfeed (Bauer-style: low-passed, slightly delayed opposite channel)
    G.xf = new Stage();
    var xs = ctx.createChannelSplitter(2), xm = ctx.createChannelMerger(2);
    G.xfDL = ctx.createGain(); G.xfDR = ctx.createGain();
    G.xfLpL = ctx.createBiquadFilter(); G.xfLpR = ctx.createBiquadFilter();
    G.xfLpL.type = G.xfLpR.type = 'lowpass';
    G.xfLpL.Q.value = G.xfLpR.Q.value = -3.01;
    G.xfDlyL = ctx.createDelay(0.01); G.xfDlyR = ctx.createDelay(0.01);
    G.xfCL = ctx.createGain(); G.xfCR = ctx.createGain();
    G.xf.input.connect(xs);
    xs.connect(G.xfDL, 0); G.xfDL.connect(xm, 0, 0);
    xs.connect(G.xfDR, 1); G.xfDR.connect(xm, 0, 1);
    xs.connect(G.xfLpR, 1); G.xfLpR.connect(G.xfDlyR); G.xfDlyR.connect(G.xfCR); G.xfCR.connect(xm, 0, 0);
    xs.connect(G.xfLpL, 0); G.xfLpL.connect(G.xfDlyL); G.xfDlyL.connect(G.xfCL); G.xfCL.connect(xm, 0, 1);
    xm.connect(G.xf.wet);
    G.comp.output.connect(G.xf.input);

    // width + balance (M/S matrix)
    G.wd = new Stage();
    var ws = ctx.createChannelSplitter(2), wm = ctx.createChannelMerger(2);
    G.wLL = ctx.createGain(); G.wRL = ctx.createGain(); G.wRR = ctx.createGain(); G.wLR = ctx.createGain();
    G.wd.input.connect(ws);
    ws.connect(G.wLL, 0); G.wLL.connect(wm, 0, 0);
    ws.connect(G.wRL, 1); G.wRL.connect(wm, 0, 0);
    ws.connect(G.wRR, 1); G.wRR.connect(wm, 0, 1);
    ws.connect(G.wLR, 0); G.wLR.connect(wm, 0, 1);
    wm.connect(G.wd.wet);
    G.xf.output.connect(G.wd.input);

    // spatial: two virtual speakers rendered through HRTF panners
    G.sp = new Stage();
    var ss = ctx.createChannelSplitter(2);
    G.spL = ctx.createPanner(); G.spR = ctx.createPanner();
    [G.spL, G.spR].forEach(function (p) {
      p.panningModel = 'HRTF'; p.distanceModel = 'inverse';
      p.refDistance = 1; p.rolloffFactor = 0;
      p.channelCount = 1; p.channelCountMode = 'explicit';
    });
    G.spSum = ctx.createGain();
    G.sp.input.connect(ss);
    ss.connect(G.spL, 0); ss.connect(G.spR, 1);
    G.spL.connect(G.spSum); G.spR.connect(G.spSum);
    G.spSum.connect(G.sp.wet);
    G.wd.output.connect(G.sp.input);

    // reverb (convolver behind a crossfading slot so IR changes don't click)
    G.rv = new Stage();
    G.rvSlot = new Slot();
    G.rv.input.connect(G.rvSlot.input); G.rvSlot.output.connect(G.rv.wet);
    G.sp.output.connect(G.rv.input);
    G.rvKey = null;

    // output, limiter, analyser
    G.out = ctx.createGain();
    G.rv.output.connect(G.out);
    G.lim = new Stage();
    G.limNode = ctx.createDynamicsCompressor();
    G.limNode.knee.value = 0; G.limNode.ratio.value = 20;
    G.limNode.attack.value = 0.001; G.limNode.release.value = 0.08;
    G.lim.input.connect(G.limNode); G.limNode.connect(G.lim.wet);
    G.out.connect(G.lim.input);
    G.an = ctx.createAnalyser();
    G.an.fftSize = 4096; G.an.smoothingTimeConstant = 0.7;
    G.master = ctx.createGain(); // master bypass crossfade lives on the sources (see applyEnabled)
    G.lim.output.connect(G.an);
    G.lim.output.connect(ctx.destination);
  }

  function rebuildBands(list) {
    var active = list.filter(function (b) { return b && b.on !== false; });
    var sig = active.map(function (b) { return b.id + ':' + b.type; }).join(',');
    if (sig !== G.bandSig) {
      // tear down chain links
      try { G.preamp.disconnect(); } catch (e) {}
      G.bandOrder.forEach(function (id) { var bd = G.bands[id]; if (bd) bd.disconnect(); });
      var next = {};
      active.forEach(function (b) {
        var bd = G.bands[b.id];
        if (!bd || bd.type !== b.type) { bd = new Band(); bd.type = b.type; bd.build(b); }
        next[b.id] = bd;
      });
      G.bands = next;
      G.bandOrder = active.map(function (b) { return b.id; });
      var prev = G.preamp;
      G.bandOrder.forEach(function (id) { prev.connect(G.bands[id].input); prev = G.bands[id].output; });
      prev.connect(G.bandsOut);
      G.bandSig = sig;
    }
    active.forEach(function (b) { G.bands[b.id].update(b, false); });
  }

  // ---------- reverb impulse ----------
  var irCache = {}; // id -> AudioBuffer (custom IRs)
  var irWanted = null;
  function makeIR(decay, predelayMs, damping, width) {
    var fs = ctx.sampleRate;
    decay = clamp(decay, 0.1, 10);
    var pre = Math.floor(clamp(predelayMs, 0, 250) / 1000 * fs);
    var len = Math.min(pre + Math.floor(decay * 1.3 * fs), fs * 12);
    var buf = ctx.createBuffer(2, len, fs);
    var corr = 1 - clamp(width, 0, 1); // 0 = fully decorrelated, 1 = mono tail
    var shared = new Float32Array(len);
    for (var i = 0; i < len; i++) shared[i] = Math.random() * 2 - 1;
    for (var ch = 0; ch < 2; ch++) {
      var d = buf.getChannelData(ch);
      var y = 0, e = 0;
      for (var n = pre; n < len; n++) {
        var t = (n - pre) / fs;
        var x = corr * shared[n] + (1 - corr) * (Math.random() * 2 - 1);
        // high frequencies die faster: cutoff glides from ~18k to `damping`
        var fc = damping + (18000 - damping) * Math.exp(-3 * t / decay);
        var c = 1 - Math.exp(-2 * Math.PI * fc / fs);
        y += c * (x - y);
        var v = y * Math.exp(-6.9078 * t / decay);
        d[n] = v; e += v * v;
      }
      var s = e > 0 ? 1 / Math.sqrt(e) : 0;
      for (var k = pre; k < len; k++) d[k] *= s;
    }
    return buf;
  }
  function normalizeBuffer(b) {
    for (var ch = 0; ch < b.numberOfChannels; ch++) {
      var d = b.getChannelData(ch), e = 0;
      for (var i = 0; i < d.length; i++) e += d[i] * d[i];
      var s = e > 0 ? 1 / Math.sqrt(e) : 0;
      for (var j = 0; j < d.length; j++) d[j] *= s;
    }
    return b;
  }
  var rvTimer = null;
  function updateReverbIR(r) {
    var key = r.irID ? ('ir:' + r.irID) : ['gen', num(r.decay, 1.8).toFixed(2), num(r.predelay, 20).toFixed(0), num(r.damping, 6000).toFixed(0), num(r.width, 1).toFixed(2)].join('|');
    if (key === G.rvKey) return;
    if (r.irID) {
      var b = irCache[r.irID];
      if (!b) { if (irWanted !== r.irID) { irWanted = r.irID; post({ type: 'needIR', id: r.irID }); } return; }
      G.rvKey = key;
      var cv = ctx.createConvolver(); cv.normalize = false; cv.buffer = b;
      G.rvSlot.swap(cv);
      return;
    }
    clearTimeout(rvTimer);
    rvTimer = setTimeout(function () {
      G.rvKey = key;
      var cv2 = ctx.createConvolver(); cv2.normalize = false;
      cv2.buffer = makeIR(num(r.decay, 1.8), num(r.predelay, 20), num(r.damping, 6000), num(r.width, 1));
      G.rvSlot.swap(cv2);
    }, G.rvKey ? 120 : 0);
  }

  function b64ToArrayBuffer(b64) {
    var bin = atob(b64), len = bin.length, out = new Uint8Array(len);
    for (var i = 0; i < len; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  }

  // ---------- apply config ----------
  function applyGraph() {
    if (!G) return;
    var c = cfg;
    setP(G.preamp.gain, dbToLin(num(c.preamp, 0)));
    rebuildBands(c.bands || []);

    var cp = c.comp || {};
    if (cp.on) {
      setP(G.compNode.threshold, clamp(num(cp.threshold, -24), -100, 0));
      setP(G.compNode.knee, clamp(num(cp.knee, 6), 0, 40));
      setP(G.compNode.ratio, clamp(num(cp.ratio, 3), 1, 20));
      setP(G.compNode.attack, clamp(num(cp.attack, 10), 0, 1000) / 1000);
      setP(G.compNode.release, clamp(num(cp.release, 150), 0, 1000) / 1000);
      setP(G.compMakeup.gain, dbToLin(num(cp.makeup, 0)));
      G.comp.mix(0, 1);
    } else G.comp.mix(1, 0);

    var xf = c.crossfeed || {};
    if (xf.on) {
      var lvl = dbToLin(clamp(num(xf.level, -6), -30, 0));
      var fc = clamp(num(xf.cutoff, 700), 200, 2000);
      var dly = clamp(num(xf.delay, 0.3), 0, 1) / 1000;
      var norm = 1 / (1 + lvl);
      setP(G.xfDL.gain, norm); setP(G.xfDR.gain, norm);
      setP(G.xfCL.gain, lvl * norm); setP(G.xfCR.gain, lvl * norm);
      setP(G.xfLpL.frequency, fc); setP(G.xfLpR.frequency, fc);
      setP(G.xfDlyL.delayTime, dly); setP(G.xfDlyR.delayTime, dly);
      G.xf.mix(0, 1);
    } else G.xf.mix(1, 0);

    var wd = c.width || {};
    var w = clamp(num(wd.width, 1), 0, 2.5), bal = clamp(num(wd.balance, 0), -1, 1);
    if (wd.on && (Math.abs(w - 1) > 1e-3 || Math.abs(bal) > 1e-3 || wd.swap || wd.mono)) {
      if (wd.mono) w = 0;
      var a = (1 + w) / 2, bb = (1 - w) / 2;
      var gl = Math.min(1, 1 - bal), gr = Math.min(1, 1 + bal);
      if (wd.swap) { setP(G.wLL.gain, bb * gl); setP(G.wRL.gain, a * gl); setP(G.wRR.gain, bb * gr); setP(G.wLR.gain, a * gr); }
      else { setP(G.wLL.gain, a * gl); setP(G.wRL.gain, bb * gl); setP(G.wRR.gain, a * gr); setP(G.wLR.gain, bb * gr); }
      G.wd.mix(0, 1);
    } else G.wd.mix(1, 0);

    var sp = c.spatial || {};
    if (sp.on) {
      var ang = clamp(num(sp.angle, 30), 5, 90) * Math.PI / 180;
      var dist = clamp(num(sp.distance, 1), 0.3, 5);
      var elev = clamp(num(sp.elevation, 0), -45, 45) * Math.PI / 180;
      var pos = function (p, s) {
        var x = s * Math.sin(ang) * dist * Math.cos(elev), y = Math.sin(elev) * dist, z = -Math.cos(ang) * dist * Math.cos(elev);
        if (p.positionX) { setP(p.positionX, x); setP(p.positionY, y); setP(p.positionZ, z); }
        else p.setPosition(x, y, z);
      };
      pos(G.spL, -1); pos(G.spR, 1);
      var amt = clamp(num(sp.amount, 0.8), 0, 1);
      setP(G.spSum.gain, dbToLin(2));
      G.sp.mix(1 - amt, amt);
    } else G.sp.mix(1, 0);

    var rv = c.reverb || {};
    if (rv.on) {
      updateReverbIR(rv);
      var mix = clamp(num(rv.mix, 0.25), 0, 1);
      G.rv.mix(1 - 0.5 * mix, mix);
    } else G.rv.mix(1, 0);

    setP(G.out.gain, dbToLin(num(c.output, 0)));

    var lm = c.limiter || {};
    if (lm.on !== false) {
      setP(G.limNode.threshold, clamp(num(lm.ceiling, -1), -30, 0));
      G.lim.mix(0, 1);
    } else G.lim.mix(1, 0);
  }

  function ensureCtx() {
    if (ctx) return ctx;
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    try { ctx = new AC({ latencyHint: 'playback' }); } catch (e) { ctx = new AC(); }
    buildGraph();
    applyGraph();
    var resume = function () { if (ctx && ctx.state !== 'running') ctx.resume().catch(function () {}); };
    ['touchend', 'pointerup', 'keydown', 'click'].forEach(function (ev) { window.addEventListener(ev, resume, true); });
    ctx.onstatechange = function () { if (ctx.state !== 'running' && anyPlaying()) resume(); };
    startSpectrum();
    return ctx;
  }

  function anyPlaying() {
    var p = false;
    attached.forEach(function (_s, el) { if (!el.paused && !el.ended) p = true; });
    return p;
  }

  function isEncrypted(el) {
    try { if (el.mediaKeys || el.webkitKeys || drmEls.has(el)) return true; } catch (e) {}
    return false;
  }
  function corsBlocked(el) {
    if (el.srcObject) return false;
    var src = el.currentSrc || el.src || '';
    if (!src || /^(blob:|data:|mediastream:)/i.test(src)) return false;
    try {
      var u = new URL(src, location.href);
      if (u.origin === location.origin) return false;
    } catch (e) { return false; }
    return !el.crossOrigin;
  }

  function tryAttach(el) {
    if (disabledHere || !el || !(el instanceof HTMLMediaElement)) return;
    seen.add(el);
    if (attached.has(el)) { if (ctx && ctx.state !== 'running') ctx.resume().catch(function () {}); return; }
    if (!cfg.enabled) return;
    if (isEncrypted(el)) { status('drm'); return; }
    if (corsBlocked(el)) { corsRetry(el); return; }
    if (!ensureCtx()) { status('error', 'no AudioContext'); return; }
    try {
      var s = ctx.createMediaElementSource(el);
      s.connect(G.input);
      attached.set(el, s);
      if (ctx.state !== 'running') ctx.resume().catch(function () {});
      status('active');
      watchSilence(el);
    } catch (e) {
      status('error', String(e && e.message || e));
    }
  }

  // Cross-origin file without CORS mode: routing it would output silence. If the server actually allows
  // CORS, reload the element in CORS mode at the same position and attach once it plays again.
  var corsTried = new WeakSet();
  function corsRetry(el) {
    var src = el.currentSrc || el.src;
    var h = ''; try { h = new URL(src, location.href).hostname; } catch (e) {}
    if (corsTried.has(el) || !window.fetch) { status('cors', h); return; }
    corsTried.add(el);
    var ac = window.AbortController ? new AbortController() : null;
    fetch(src, { method: 'GET', mode: 'cors', credentials: 'omit', signal: ac ? ac.signal : undefined })
      .then(function (r) {
        if (ac) ac.abort();
        if (!r.ok) throw new Error('status ' + r.status);
        if ((el.currentSrc || el.src) !== src) return; // player moved on
        var t = el.currentTime, wasPlaying = !el.paused, rate = el.playbackRate;
        el.crossOrigin = 'anonymous';
        el.src = src;
        var seek = function () { try { el.currentTime = t; el.playbackRate = rate; } catch (e) {} };
        el.addEventListener('loadedmetadata', seek, { once: true });
        if (wasPlaying) { var p = el.play(); if (p && p.catch) p.catch(function () {}); }
      })
      .catch(function () { status('cors', h); });
  }

  function srcKind(el) {
    var src = el.currentSrc || el.src || '';
    if (/^blob:/i.test(src)) return compat ? 'mse-compat-failed' : 'mse';
    if (/\.m3u8|manifest|hls/i.test(src)) return 'hls';
    try { return new URL(src, location.href).hostname; } catch (e) { return 'unknown'; }
  }

  // If audio is flowing into the element but nothing comes out of the graph, it's probably DRM or tainted.
  function watchSilence(el) {
    var checks = 0, silent = 0, lastT = el.currentTime;
    var buf = new Float32Array(1024);
    var iv = setInterval(function () {
      if (!attached.has(el)) { clearInterval(iv); return; }
      checks++;
      var moving = !el.paused && !el.muted && el.volume > 0 && el.currentTime !== lastT;
      lastT = el.currentTime;
      if (moving && ctx.state === 'running') {
        G.an.getFloatTimeDomainData(buf);
        var peak = 0; for (var i = 0; i < buf.length; i++) { var v = Math.abs(buf[i]); if (v > peak) peak = v; }
        if (peak < 1e-6) silent++; else silent = 0;
        if (silent >= 6) { status('silent', srcKind(el)); clearInterval(iv); return; }
      }
      if (checks > 40) clearInterval(iv);
    }, 500);
  }

  // ---------- hooks ----------
  if (!disabledHere) {
    document.addEventListener('playing', function (e) { tryAttach(e.target); }, true);
    document.addEventListener('play', function (e) { if (e.target instanceof HTMLMediaElement) seen.add(e.target); }, true);
    document.addEventListener('encrypted', function (e) { drmEls.add(e.target); }, true);
    document.addEventListener('webkitneedkey', function (e) { drmEls.add(e.target); }, true);
    try {
      var P = HTMLMediaElement.prototype;
      var origPlay = P.play;
      P.play = function () {
        var el = this;
        seen.add(el);
        if (!el.isConnected) el.addEventListener('playing', function () { tryAttach(el); }, { once: true });
        return origPlay.apply(this, arguments);
      };
      if (P.setMediaKeys) {
        var origSMK = P.setMediaKeys;
        P.setMediaKeys = function (k) { if (k) { drmEls.add(this); if (attached.has(this)) status('drm'); } return origSMK.apply(this, arguments); };
      }
      if (P.webkitSetMediaKeys) {
        var origWSMK = P.webkitSetMediaKeys;
        P.webkitSetMediaKeys = function (k) { if (k) { drmEls.add(this); if (attached.has(this)) status('drm'); } return origWSMK.apply(this, arguments); };
      }
    } catch (e) {}
  }

  // ---------- spectrum ----------
  var specTimer = null;
  function startSpectrum() {
    if (specTimer) return;
    var N = 96, lo = Math.log(20), hi = Math.log(20000);
    var bins = null;
    specTimer = setInterval(function () {
      if (!cfg.spectrum || !G || !anyPlaying() || ctx.state !== 'running') return;
      if (!bins) bins = new Float32Array(G.an.frequencyBinCount);
      G.an.getFloatFrequencyData(bins);
      var hz = ctx.sampleRate / G.an.fftSize, out = new Array(N);
      for (var i = 0; i < N; i++) {
        var f0 = Math.exp(lo + (hi - lo) * i / N), f1 = Math.exp(lo + (hi - lo) * (i + 1) / N);
        var k0 = Math.max(1, Math.floor(f0 / hz)), k1 = Math.max(k0, Math.ceil(f1 / hz));
        var m = -160;
        for (var k = k0; k <= k1 && k < bins.length; k++) if (bins[k] > m) m = bins[k];
        out[i] = Math.round(Math.max(-160, m) * 10) / 10;
      }
      post({ type: 'spectrum', bins: out });
    }, 66);
  }

  // ---------- now playing + remote control (runs even when Timbre is off for the site) ----------
  var actionHandlers = {};
  try {
    var ms = navigator.mediaSession;
    if (ms && ms.setActionHandler) {
      var origSAH = ms.setActionHandler.bind(ms);
      ms.setActionHandler = function (action, handler) {
        actionHandlers[action] = handler;
        return origSAH(action, handler);
      };
    }
  } catch (e) {}

  function mediaEls() {
    var list = [];
    seen.forEach(function (el) { list.push(el); });
    try { document.querySelectorAll('audio,video').forEach(function (el) { if (list.indexOf(el) < 0) list.push(el); }); } catch (e) {}
    return list;
  }
  function activeEl() {
    var els = mediaEls(), best = null;
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (!el.paused && !el.ended) return el;
      if (!best && el.currentSrc && el.readyState > 0) best = el;
    }
    return best;
  }
  function absURL(u) { try { return new URL(u, location.href).href; } catch (e) { return ''; } }

  var lastNP = '';
  function pollNowPlaying() {
    var el = activeEl();
    var md = null;
    try { md = navigator.mediaSession && navigator.mediaSession.metadata; } catch (e) {}
    if (!el && !md) return;
    var art = '';
    if (md && md.artwork && md.artwork.length) {
      var pick = md.artwork[0];
      md.artwork.forEach(function (a) {
        var w = parseInt(String(a.sizes || '').split('x')[0], 10) || 0;
        var pw = parseInt(String(pick.sizes || '').split('x')[0], 10) || 0;
        if (w >= 128 && (pw < 128 || w < pw)) pick = a; // smallest >= 128px
      });
      art = absURL(pick.src);
    }
    var playing = el ? (!el.paused && !el.ended) : (navigator.mediaSession && navigator.mediaSession.playbackState === 'playing');
    var np = {
      type: 'nowplaying',
      title: (md && md.title) || document.title || '',
      artist: (md && md.artist) || '',
      album: (md && md.album) || '',
      artwork: art,
      playing: !!playing,
      duration: el && isFinite(el.duration) ? Math.round(el.duration) : 0,
      position: el ? Math.round(el.currentTime) : 0,
      canNext: !!actionHandlers.nexttrack,
      canPrev: !!actionHandlers.previoustrack
    };
    var key = [np.title, np.artist, np.album, np.artwork, np.playing, np.canNext, np.canPrev].join('|');
    if (key === lastNP) return;
    lastNP = key;
    post(np);
  }
  setInterval(pollNowPlaying, 1000);
  document.addEventListener('play', function () { setTimeout(pollNowPlaying, 50); }, true);
  document.addEventListener('pause', function () { setTimeout(pollNowPlaying, 50); }, true);

  function runAction(name, fallback) {
    var h = actionHandlers[name];
    if (h) { try { h({ action: name }); return true; } catch (e) {} }
    return fallback ? fallback() : false;
  }
  function act(cmd) {
    var el = activeEl();
    if (cmd === 'toggle') cmd = (el && !el.paused) ? 'pause' : 'play';
    switch (cmd) {
      case 'play': runAction('play', function () { if (el) { var p = el.play(); if (p && p.catch) p.catch(function () {}); } }); break;
      case 'pause': runAction('pause', function () { if (el) el.pause(); }); break;
      case 'next': runAction('nexttrack', function () { if (el && isFinite(el.duration)) el.currentTime = Math.min(el.duration, el.currentTime + 15); }); break;
      case 'prev': runAction('previoustrack', function () { if (el) el.currentTime = Math.max(0, el.currentTime - 15); }); break;
    }
    setTimeout(pollNowPlaying, 300);
  }
  // Only frames that actually have media act; toggle is resolved per frame.
  function command(cmd) {
    if (activeEl() || Object.keys(actionHandlers).length) act(cmd);
    relay({ __timbreCmd: cmd });
  }

  // ---------- public API ----------
  function relay(msg) {
    try { for (var i = 0; i < window.frames.length; i++) window.frames[i].postMessage(msg, '*'); } catch (e) {}
  }
  var api = {
    apply: function (newCfg) {
      cfg = newCfg || cfg;
      if (!disabledHere) {
        if (G) applyGraph();
        if (cfg.enabled) seen.forEach(function (el) { if (!el.paused) tryAttach(el); });
        if (G) bypass(!cfg.enabled);
      }
      relay({ __timbreCfg: cfg });
    },
    setIR: function (id, b64) {
      relay({ __timbreIR: { id: id, b64: b64 } });
      if (!ctx) { pendingIR[id] = b64; return; }
      loadIR(id, b64);
    },
    report: function () { lastStatus = ''; status(state); relay({ __timbreReport: 1 }); },
    sampleRate: function () { return ctx ? ctx.sampleRate : 0; },
    command: command
  };
  var pendingIR = {};
  function loadIR(id, b64) {
    try {
      var ab = b64ToArrayBuffer(b64);
      var done = function (buf) { irCache[id] = normalizeBuffer(buf); if (G) { G.rvKey = null; applyGraph(); } };
      var p = ctx.decodeAudioData(ab, done, function () { post({ type: 'irError', id: id }); });
      if (p && p.catch) p.catch(function () {});
    } catch (e) { post({ type: 'irError', id: id }); }
  }

  // Master bypass: once a source is routed into Web Audio it can't be un-routed, so "off" means
  // flattening every stage instead of disconnecting.
  function bypass(off) {
    if (!G) return;
    if (!off) return; // applyGraph already set everything
    setP(G.preamp.gain, 1);
    rebuildBands([]);
    G.comp.mix(1, 0); G.xf.mix(1, 0); G.wd.mix(1, 0); G.sp.mix(1, 0); G.rv.mix(1, 0); G.lim.mix(1, 0);
    setP(G.out.gain, 1);
  }

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || typeof d !== 'object') return;
    if (d.__timbreCfg) api.apply(d.__timbreCfg);
    else if (d.__timbreIR) api.setIR(d.__timbreIR.id, d.__timbreIR.b64);
    else if (d.__timbreReport) api.report();
    else if (d.__timbreCmd && window !== window.top) command(d.__timbreCmd);
  });

  var origEnsure = ensureCtx;
  ensureCtx = function () {
    var had = !!ctx, c = origEnsure();
    if (c && !had) {
      Object.keys(pendingIR).forEach(function (id) { loadIR(id, pendingIR[id]); });
      pendingIR = {};
      if (!cfg.enabled) bypass(true);
    }
    return c;
  };

  try { Object.defineProperty(window, '__timbre', { value: api, enumerable: false }); } catch (e) { window.__timbre = api; }
  if (window === window.top) status(state, compat ? 'compat' : '');
})();
