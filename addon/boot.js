// Runs in the page world right before engine.js. Config arrives a moment later from bridge.js
// (storage is async), which is fine: nothing is playing yet at document start.
window.__TIMBRE_BOOT = {
  bridge: true,
  background: false,
  disabledHosts: [],
  compatHosts: [],
  config: { enabled: true, preamp: 0, output: 0, spectrum: false, bands: [], limiter: { on: true, ceiling: -1 } }
};
