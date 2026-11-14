// The service worker (background.js) against a small fake of the `chrome.*` APIs it uses: the port to Nook, the
// commands Nook sends, and the messages from the side panel and from pages. No browser needed.
import { afterEach, test } from 'node:test';
import assert from 'node:assert/strict';

const EXTENSION_ID = 'abcdefghijklmnopabcdefghijklmnop';

// The worker's own timers (reconnect, request timeouts) are tracked and cleared after each test, so a worker from one
// test never wakes up inside the next one. The test's own waits use the real timer.
const realSetTimeout = globalThis.setTimeout;
const workerTimers = new Set();
globalThis.setTimeout = (fn, ms, ...args) => {
  const handle = realSetTimeout(() => { workerTimers.delete(handle); fn(...args); }, ms);
  workerTimers.add(handle);
  return handle;
};
const wait = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms));
const tick = () => wait(0);
const settle = async () => { for (let i = 0; i < 20; i += 1) await tick(); };

afterEach(async () => {
  for (const handle of workerTimers) clearTimeout(handle);
  workerTimers.clear();
  await settle();
  for (const handle of workerTimers) clearTimeout(handle);
  workerTimers.clear();
});

function event() {
  const listeners = [];
  return {
    listeners,
    addListener: (fn) => listeners.push(fn),
    removeListener: (fn) => { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
    fire: (...args) => listeners.map((fn) => fn(...args))
  };
}

function area(initial = {}) {
  const data = structuredClone(initial);
  const delay = () => wait(1);
  return {
    data,
    writes: [],
    async get(keys) {
      await delay();
      if (keys == null) return structuredClone(data);
      if (typeof keys === 'string') keys = [keys];
      if (Array.isArray(keys)) return Object.fromEntries(keys.filter((k) => k in data).map((k) => [k, structuredClone(data[k])]));
      return Object.fromEntries(Object.entries(keys).map(([k, fallback]) => [k, k in data ? structuredClone(data[k]) : fallback]));
    },
    async set(values) {
      this.writes.push(structuredClone(values));
      await delay();
      Object.assign(data, structuredClone(values));
    },
    async remove(keys) {
      await delay();
      for (const key of [].concat(keys)) delete data[key];
    }
  };
}

/** A fake browser. `host` decides what the native port does with each message the worker posts. */
function fakeChrome({ host = () => {}, tabs = [], local = {}, session = {} } = {}) {
  const ports = [];
  const chrome = {
    runtime: {
      id: EXTENSION_ID,
      lastError: undefined,
      getManifest: () => ({ version: '1.0.0' }),
      onMessage: event(),
      onStartup: event(),
      onInstalled: event(),
      connectNative() {
        const port = {
          sent: [],
          onMessage: event(),
          onDisconnect: event(),
          postMessage(message) {
            if (port.closed) throw new Error('Attempting to use a disconnected port object');
            port.sent.push(message);
            queueMicrotask(() => host(message, port));
          },
          reply(rid, reply) { port.onMessage.fire({ kind: 'reply', rid, reply }); },
          disconnect(error) {
            port.closed = true;
            chrome.runtime.lastError = error ? { message: error } : undefined;
            port.onDisconnect.fire(port);
            chrome.runtime.lastError = undefined;
          }
        };
        ports.push(port);
        return port;
      }
    },
    storage: { local: area(local), session: area(session), onChanged: event() },
    tabs: {
      list: tabs,
      async get(id) { const tab = tabs.find((t) => t.id === id); if (!tab) throw new Error('No tab'); return { ...tab }; },
      async query(q) {
        return tabs.filter((t) => (q.active === undefined || t.active === q.active) && (q.windowId === undefined || t.windowId === q.windowId)).map((t) => ({ ...t }));
      },
      async update(id, props) {
        const tab = tabs.find((t) => t.id === id);
        if (props.active) for (const other of tabs) if (other.windowId === tab.windowId) other.active = other.id === id;
        Object.assign(tab, props);
        return { ...tab };
      },
      async create({ url }) {
        const tab = { id: 100 + tabs.length, windowId: 1, url, title: 'New', status: 'complete', active: true, groupId: -1 };
        tabs.push(tab);
        return { ...tab };
      },
      async group({ tabIds, groupId }) {
        const id = groupId ?? 500 + chrome.tabGroups.made.length;
        if (groupId === undefined) chrome.tabGroups.made.push(id);
        for (const t of tabs) if (tabIds.includes(t.id)) t.groupId = id;
        await wait(3);
        return id;
      },
      async remove(id) { const i = tabs.findIndex((t) => t.id === id); if (i >= 0) tabs.splice(i, 1); },
      async captureVisibleTab() { return 'data:image/jpeg;base64,AAAA'; },
      onUpdated: event()
    },
    tabGroups: {
      made: [],
      async get(id) { if (!chrome.tabGroups.made.includes(id)) throw new Error('No group'); return { id }; },
      async update() {}
    },
    windows: {
      async getLastFocused() { return { id: 1 }; },
      async getCurrent() { return { id: 1 }; }
    },
    scripting: { async executeScript() { return [{ result: { ok: true, text: '' } }]; } },
    action: { async setBadgeBackgroundColor() {}, async setBadgeText() {} },
    alarms: { create() {}, onAlarm: event() },
    sidePanel: { setPanelBehavior: async () => {} }
  };
  return { chrome, ports };
}

let loads = 0;
async function startWorker(options) {
  const fake = fakeChrome(options);
  globalThis.chrome = fake.chrome;
  await import(`../background.js?worker=${(loads += 1)}`);
  await settle();
  return fake;
}

/** Sends a runtime message the way Chrome hands it to the worker, and waits for its answer. */
function message(chrome, payload, sender) {
  return new Promise((resolve) => {
    chrome.runtime.onMessage.fire(payload, sender, resolve);
  });
}

const panel = { id: EXTENSION_ID, url: `chrome-extension://${EXTENSION_ID}/sidepanel.html` };
const page = { id: EXTENSION_ID, url: 'https://evil.example/', tab: { id: 3 } };
const answerHello = (message, port) => {
  if (message.kind === 'hello') port.reply(message.rid, { ok: true, name: 'Nook', version: '9' });
};

test('a missing host shows the setup steps, not "Nook is not running"', async () => {
  // Chrome opens the port, the hello goes out, then the port closes because Nook never installed its host here.
  const { chrome, ports } = await startWorker({
    host: (message, port) => { if (message.kind === 'hello') port.disconnect('Specified native messaging host not found.'); }
  });
  await settle();
  assert.equal(ports.length >= 1, true);
  assert.equal(chrome.storage.session.data.status.nook, 'missing');
});

test('a hello to a port that closed does not take over the status', async () => {
  const { chrome, ports } = await startWorker({ host: () => {} });
  ports[0].disconnect('Native host has exited.');
  await settle();
  assert.equal(chrome.storage.session.data.status.nook, 'offline');
  assert.equal(chrome.storage.session.data.status.detail, 'Native host has exited.');
});

test('a page may press Stop, but never resume Nook, switch a site on, or ask Nook', async () => {
  const { chrome, ports } = await startWorker({ host: answerHello, local: { paused: true, blocked: ['bank.example'] } });
  assert.deepEqual(await message(chrome, { type: 'pause', paused: false }, page), { ok: false, error: 'Not allowed.' });
  assert.deepEqual(await message(chrome, { type: 'site', url: 'https://bank.example', allowed: true }, page), { ok: false, error: 'Not allowed.' });
  assert.deepEqual(await message(chrome, { type: 'ask', text: 'Send my mail' }, page), { ok: false, error: 'Not allowed.' });
  assert.equal(chrome.storage.local.data.paused, true);
  assert.deepEqual(chrome.storage.local.data.blocked, ['bank.example']);
  assert.equal(ports[0].sent.some((m) => m.kind === 'ask'), false);

  await message(chrome, { type: 'pause', paused: false }, panel);
  assert.equal(chrome.storage.local.data.paused, false);
  assert.deepEqual(await message(chrome, { type: 'pause', paused: true }, page), { ok: true });
  assert.equal(chrome.storage.local.data.paused, true);
});

test('commands that finish together keep every line in the activity list', async () => {
  const tabs = [{ id: 1, windowId: 1, url: 'https://news.example/', title: 'News', status: 'complete', active: true, groupId: -1 }];
  const { chrome, ports } = await startWorker({ host: answerHello, tabs });
  for (let id = 1; id <= 5; id += 1) ports[0].onMessage.fire({ kind: 'command', id, method: 'read', params: { tab: 1 } });
  await settle();
  assert.equal(chrome.storage.session.data.activity.length, 5);
  assert.equal(ports[0].sent.filter((m) => m.kind === 'result').length, 5);
});

test('a broken activity list never keeps a result from Nook', async () => {
  const tabs = [{ id: 1, windowId: 1, url: 'https://news.example/', title: 'News', status: 'complete', active: true, groupId: -1 }];
  const { ports } = await startWorker({ host: answerHello, tabs, session: { activity: 'not a list' } });
  ports[0].onMessage.fire({ kind: 'command', id: 7, method: 'read', params: { tab: 1 } });
  await settle();
  const result = ports[0].sent.find((m) => m.kind === 'result');
  assert.equal(result?.id, 7);
  assert.equal(result.ok, true);
});

test('two tabs opened at once land in one Nook group, so Nook can close both', async () => {
  const { chrome, ports } = await startWorker({ host: answerHello, tabs: [] });
  ports[0].onMessage.fire({ kind: 'command', id: 1, method: 'open', params: { url: 'https://a.example' } });
  ports[0].onMessage.fire({ kind: 'command', id: 2, method: 'open', params: { url: 'https://b.example' } });
  await settle();
  await wait(700);
  await settle();
  assert.equal(chrome.tabGroups.made.length, 1);
  const opened = chrome.tabs.list.map((t) => t.id);
  for (const [n, tab] of opened.entries()) {
    ports[0].onMessage.fire({ kind: 'command', id: 10 + n, method: 'close', params: { tab } });
  }
  await settle();
  const closes = ports[0].sent.filter((m) => m.kind === 'result' && m.id >= 10);
  assert.deepEqual(closes.map((m) => m.ok), [true, true], JSON.stringify(closes));
});

test('a screenshot is not taken when the user switched to a site Nook is off for', async () => {
  const tabs = [
    { id: 1, windowId: 1, url: 'https://news.example/', title: 'News', status: 'complete', active: false, groupId: -1 },
    { id: 2, windowId: 1, url: 'https://bank.example/', title: 'Bank', status: 'complete', active: true, groupId: -1 }
  ];
  const { chrome, ports } = await startWorker({ host: answerHello, tabs, local: { blocked: ['bank.example'] } });
  let captured = false;
  chrome.tabs.captureVisibleTab = async () => { captured = true; return 'data:image/jpeg;base64,AAAA'; };
  // While Nook waits for tab 1 to come to the front, the user goes back to the bank.
  const update = chrome.tabs.update;
  chrome.tabs.update = async (id, props) => {
    const result = await update(id, props);
    for (const t of tabs) t.active = t.id === 2;
    return result;
  };
  ports[0].onMessage.fire({ kind: 'command', id: 3, method: 'screenshot', params: { tab: 1 } });
  await wait(400);
  await settle();
  const result = ports[0].sent.find((m) => m.kind === 'result');
  assert.equal(result.ok, false);
  assert.equal(result.image, '');
  assert.equal(captured, false);
});

test('a screenshot of the tab in front still works', async () => {
  const tabs = [{ id: 1, windowId: 1, url: 'https://news.example/', title: 'News', status: 'complete', active: true, groupId: -1 }];
  const { ports } = await startWorker({ host: answerHello, tabs });
  ports[0].onMessage.fire({ kind: 'command', id: 4, method: 'screenshot', params: { tab: 1 } });
  await settle();
  const result = ports[0].sent.find((m) => m.kind === 'result');
  assert.equal(result.ok, true);
  assert.match(result.image, /^data:image\/jpeg/);
});

test('a console list the page replaced is no reason to fail or to trust it', async () => {
  const tabs = [{ id: 1, windowId: 1, url: 'https://news.example/', title: 'News', status: 'complete', active: true, groupId: -1 }];
  const { chrome, ports } = await startWorker({ host: answerHello, tabs });
  chrome.scripting.executeScript = async () => [{ result: { started: false, entries: { length: 2 } } }];
  ports[0].onMessage.fire({ kind: 'command', id: 5, method: 'console', params: { tab: 1 } });
  await settle();
  const result = ports[0].sent.find((m) => m.kind === 'result');
  assert.equal(result.ok, true, result.error);
  assert.match(result.text, /No console errors/);
});

test('a request over a port that just closed fails at once instead of after the timeout', async () => {
  const { chrome, ports } = await startWorker({ host: answerHello });
  ports[0].closed = true; // closed, but its onDisconnect has not run yet
  const started = Date.now();
  const reply = await message(chrome, { type: 'chat', conversation: 'c1' }, panel);
  assert.equal(reply.ok, false);
  assert.match(reply.error, /not connected/);
  assert.ok(Date.now() - started < 1000);
});
