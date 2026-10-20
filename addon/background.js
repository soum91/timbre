const api = globalThis.browser || globalThis.chrome;
const tabs = new Map(); // tabId -> { frames: {key: status}, nowplaying }

const PRIORITY = { silent: 7, active: 6, drm: 5, cors: 4, error: 3, off: 2, idle: 1 };

function summary(t) {
  if (!t) return { state: 'idle', streams: 0, detail: '' };
  let best = { state: 'idle', streams: 0, detail: '' }, streams = 0;
  for (const s of Object.values(t.frames)) {
    if (s.state === 'active') streams += s.streams || 1;
    if ((PRIORITY[s.state] || 0) > (PRIORITY[best.state] || 0)) best = s;
  }
  return { ...best, streams: best.state === 'active' ? Math.max(1, streams) : best.streams };
}

function badge(tabId) {
  const s = summary(tabs.get(tabId));
  const text = s.state === 'active' ? 'EQ' : (['drm', 'silent', 'cors', 'error'].includes(s.state) ? '!' : '');
  try {
    api.action.setBadgeText({ tabId, text });
    api.action.setBadgeBackgroundColor({ tabId, color: s.state === 'active' ? '#FFB340' : '#E5484D' });
  } catch (e) {}
}

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.kind === 'getStatus') {
    const t = tabs.get(msg.tabId);
    sendResponse({ status: summary(t), nowplaying: t ? t.nowplaying : null });
    return;
  }
  const tabId = sender.tab && sender.tab.id;
  if (tabId == null) return;
  let t = tabs.get(tabId);
  if (!t) { t = { frames: {}, nowplaying: null }; tabs.set(tabId, t); }
  if (msg.kind === 'status') {
    t.frames[(msg.top ? 'top:' : 'sub:') + msg.host + ':' + (sender.frameId || 0)] = { state: msg.state, streams: msg.streams, detail: msg.detail };
    badge(tabId);
  } else if (msg.kind === 'nowplaying') {
    t.nowplaying = { title: msg.title, artist: msg.artist, playing: msg.playing };
  }
});

api.tabs.onUpdated.addListener((tabId, info) => {
  if (info.status === 'loading' && info.url) { tabs.delete(tabId); badge(tabId); }
});
api.tabs.onRemoved.addListener((tabId) => tabs.delete(tabId));
