// Isolated content script: feeds config from extension storage into the page-world engine and
// reports engine status / spectrum back to the extension.
(() => {
  const api = globalThis.browser || globalThis.chrome;
  let cfg = null;
  let wantSpectrum = 0;
  const host = location.hostname;

  const disabledHere = (list) => (list || []).some(h => h && (host === h || host.endsWith('.' + h)));

  function push() {
    if (!cfg) return;
    const c = JSON.parse(JSON.stringify(cfg.config));
    if (disabledHere(cfg.disabledHosts)) c.enabled = false;
    c.spectrum = Date.now() < wantSpectrum;
    window.postMessage({ __timbreCfg: c }, '*');
  }

  function load() {
    api.storage.local.get(['config', 'disabledHosts']).then(r => {
      cfg = { config: r.config || { enabled: true, bands: [] }, disabledHosts: r.disabledHosts || [] };
      push();
    }).catch(() => {});
  }

  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !cfg) return;
    if (changes.config) cfg.config = changes.config.newValue;
    if (changes.disabledHosts) cfg.disabledHosts = changes.disabledHosts.newValue || [];
    if (changes.config || changes.disabledHosts) push();
  });

  window.addEventListener('message', (e) => {
    if (!e.data || !e.data.__timbreOut) return;
    const m = e.data.__timbreOut;
    const type = m.type;
    if (type === 'status') {
      if (!cfg) load();
      api.runtime.sendMessage({ kind: 'status', state: m.state, streams: m.streams, detail: m.detail, top: window === window.top, host }).catch(() => {});
    } else if (type === 'spectrum') {
      if (Date.now() < wantSpectrum) api.runtime.sendMessage({ kind: 'spectrum', bins: Array.from(m.bins) }).catch(() => {});
    } else if (type === 'nowplaying') {
      api.runtime.sendMessage({ kind: 'nowplaying', title: m.title, artist: m.artist, playing: m.playing }).catch(() => {});
    }
  });

  api.runtime.onMessage.addListener((msg) => {
    if (!msg) return;
    if (msg.kind === 'wantSpectrum') {
      const was = Date.now() < wantSpectrum;
      wantSpectrum = Date.now() + 2500;
      if (!was) push();
    } else if (msg.kind === 'report') {
      window.postMessage({ __timbreReport: 1 }, '*');
    } else if (msg.kind === 'command') {
      window.postMessage({ __timbreCmd: msg.cmd }, '*');
    }
  });

  // turn spectrum back off after the popup closes
  setInterval(() => { if (wantSpectrum && Date.now() > wantSpectrum) { wantSpectrum = 0; push(); } }, 3000);

  load();
  document.addEventListener('DOMContentLoaded', push, { once: true });
})();
