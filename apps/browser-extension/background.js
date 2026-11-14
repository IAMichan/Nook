// Nook's browser extension, service worker. It keeps one native messaging port open to Nook on this Mac (the host
// script Nook installs, see docs/BROWSER-EXTENSION.md), runs the commands Nook sends on the user's tabs, and carries the
// side panel's questions to Nook. Nook decides what may happen: every action already passed Nook's approval card before
// it reaches this file. The user keeps two brakes here: pausing Nook in this browser, and switching it off per site.
import {
  GROUP_TITLE, HOST_NAME, PROTOCOL_VERSION, activityLine, browserName, cleanLook, commandError, describeTabs,
  isRestricted, normalizeURL, reconnectDelay, siteOf
} from './lib/core.js';

const REQUEST_TIMEOUT = 20_000;
const LOAD_TIMEOUT = 20_000;
const ACTIVITY_LIMIT = 40;

let port = null;
let attempt = 0;
let reconnectTimer = null;
let nextRequest = 0;
const waiting = new Map();

// MARK: - Settings and status (what the side panel shows)

async function settings() {
  const stored = await chrome.storage.local.get({ paused: false, blocked: [] });
  return { paused: !!stored.paused, blocked: Array.isArray(stored.blocked) ? stored.blocked : [] };
}

async function setStatus(status) {
  await chrome.storage.session.set({ status: { ...status, at: Date.now() } });
}

/**
 * Asks Nook how it looks now (its theme, accent and density) and keeps it, so the side panel and the strip on a page
 * draw Nook's own colors, also while Nook is not running. A Nook that does not know "look" yet leaves the last one.
 */
async function refreshLook() {
  try {
    const look = cleanLook(await request({ kind: 'look' }));
    if (!look) return null;
    const { look: stored } = await chrome.storage.local.get('look');
    if (JSON.stringify(stored) !== JSON.stringify(look)) await chrome.storage.local.set({ look });
    return look;
  } catch {
    return null;
  }
}

async function remember(line) {
  const { activity = [] } = await chrome.storage.session.get('activity');
  activity.unshift({ ...line, at: Date.now() });
  await chrome.storage.session.set({ activity: activity.slice(0, ACTIVITY_LIMIT) });
}

// MARK: - The port to Nook

function connect() {
  if (port) return;
  clearTimeout(reconnectTimer);
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (error) {
    port = null;
    setStatus({ nook: 'missing', detail: String(error?.message || error) });
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    const detail = chrome.runtime.lastError?.message || '';
    port = null;
    for (const [, pending] of waiting) pending.reject(new Error('Nook is not connected.'));
    waiting.clear();
    // Chrome says "not found" when Nook never installed its host here, "forbidden" when this extension is not the one it
    // was installed for.
    const missing = /not found|forbidden|not allowed/i.test(detail);
    setStatus({ nook: missing ? 'missing' : 'offline', detail });
    scheduleReconnect();
  });
  setStatus({ nook: 'connecting' });
  hello();
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connect, reconnectDelay(attempt++));
}

async function hello() {
  try {
    const brands = navigator.userAgentData?.brands || [];
    const reply = await request({
      kind: 'hello', protocol: PROTOCOL_VERSION, version: chrome.runtime.getManifest().version,
      browser: browserName(brands, navigator.userAgent), extension: chrome.runtime.id
    });
    if (reply?.ok) {
      attempt = 0;
      await setStatus({ nook: 'connected', name: reply.name || 'Nook', version: reply.version || '' });
      refreshLook();
    } else {
      await setStatus({ nook: 'offline', detail: reply?.error || '' });
    }
  } catch (error) {
    await setStatus({ nook: 'offline', detail: String(error?.message || error) });
  }
}

/** A message to Nook that Nook answers (hello, a question from the side panel, a command's result). */
function request(message) {
  return new Promise((resolve, reject) => {
    if (!port) {
      reject(new Error('Nook is not connected.'));
      return;
    }
    const rid = ++nextRequest;
    const timer = setTimeout(() => {
      waiting.delete(rid);
      reject(new Error('Nook did not answer in time.'));
    }, REQUEST_TIMEOUT);
    waiting.set(rid, {
      resolve: (value) => { clearTimeout(timer); resolve(value); },
      reject: (error) => { clearTimeout(timer); reject(error); }
    });
    port.postMessage({ ...message, rid });
  });
}

function onHostMessage(message) {
  if (!message || typeof message !== 'object') return;
  switch (message.kind) {
    case 'reply': {
      const pending = waiting.get(message.rid);
      if (pending) {
        waiting.delete(message.rid);
        pending.resolve(message.reply || {});
      }
      break;
    }
    case 'nook':
      // The host lost or found Nook (Nook quit, or started again).
      if (message.running) hello();
      else setStatus({ nook: 'offline' });
      break;
    case 'command':
      run(message);
      break;
    default:
      break;
  }
}

// MARK: - Commands from Nook

/** The tab a command works in: the one it names, else the one Nook worked in last, else the one in front. */
async function targetTab(params) {
  if (Number.isInteger(params.tab)) {
    try {
      return await chrome.tabs.get(params.tab);
    } catch {
      throw new Error(`There is no tab ${params.tab}. Call chrome_tabs for the open tabs.`);
    }
  }
  const { current } = await chrome.storage.session.get('current');
  if (Number.isInteger(current)) {
    try {
      return await chrome.tabs.get(current);
    } catch {
      // Closed since: fall back to the tab in front.
    }
  }
  const window = await chrome.windows.getLastFocused({ windowTypes: ['normal'] });
  const [active] = await chrome.tabs.query({ active: true, windowId: window.id });
  if (!active) throw new Error('No tab is open in the browser.');
  return active;
}

async function run(command) {
  const params = command.params || {};
  const opensNew = command.method === 'open' && params.new_tab !== false && !Number.isInteger(params.tab)
    && !['back', 'forward', 'reload'].includes(String(params.url || '').trim().toLowerCase());
  let tab = null;
  let outcome;
  try {
    if (command.method !== 'tabs' && !opensNew) tab = await targetTab(params);
    const error = commandError(command, { ...(await settings()), url: tab ? tab.url || tab.pendingUrl || '' : undefined });
    outcome = error ? { ok: false, error } : await perform(command.method, params, tab);
  } catch (error) {
    outcome = { ok: false, error: String(error?.message || error) };
  }
  const site = siteOf(outcome.url || tab?.url || '');
  if (command.method !== 'tabs') {
    await remember(activityLine(command, { ok: !!outcome.ok, site, error: outcome.ok ? undefined : outcome.error, element: outcome.element }));
  }
  try {
    await request({ kind: 'result', id: command.id, ok: !!outcome.ok, text: outcome.text || '', error: outcome.error || '', image: outcome.image || '' });
  } catch {
    // Nook went away while this ran; it already told the asker.
  }
}

async function perform(method, params, tab) {
  switch (method) {
    case 'tabs': return listTabs();
    case 'open': return open(params, tab);
    case 'close': return close(tab);
    case 'screenshot': return screenshot(tab);
    case 'wait': return waitFor(tab, params);
    case 'console': return consoleMessages(tab, params);
    case 'find': case 'read': case 'scroll':
      await use(tab);
      return agent(tab.id, method, params);
    case 'click': case 'type': case 'key': {
      await use(tab);
      await presence(tab.id);
      const result = await agent(tab.id, method, params);
      if (result.ok) await settle(tab.id);
      return result;
    }
    default:
      return { ok: false, error: `Nook's extension does not know "${method}".` };
  }
}

/** From now on Nook works in this tab, until it opens or names another. */
async function use(tab) {
  await chrome.storage.session.set({ current: tab.id });
}

async function listTabs() {
  const tabs = await chrome.tabs.query({});
  const focused = await chrome.windows.getLastFocused({ windowTypes: ['normal'] }).catch(() => null);
  const { group, current } = await chrome.storage.session.get(['group', 'current']);
  return { ok: true, text: describeTabs(tabs, { focusedWindow: focused?.id, nookGroup: group, current }) };
}

async function open(params, tab) {
  const where = String(params.url || '').trim().toLowerCase();
  if (tab && where === 'back') await chrome.tabs.goBack(tab.id);
  else if (tab && where === 'forward') await chrome.tabs.goForward(tab.id);
  else if (tab && where === 'reload') await chrome.tabs.reload(tab.id);
  else {
    const url = normalizeURL(params.url);
    if (tab) {
      await chrome.tabs.update(tab.id, { url });
    } else {
      tab = await chrome.tabs.create({ url, active: true });
      await groupWithNook(tab);
    }
  }
  await use(tab);
  const loaded = await waitForLoad(tab.id);
  return {
    ok: true, url: loaded.url,
    text: `Opened ${loaded.title || '(no title)'} | ${loaded.url} in tab ${tab.id}${loaded.status === 'complete' ? '' : ' (still loading)'}. `
      + 'Use chrome_read for its text or chrome_find for what you can click and type in.'
  };
}

/** Puts a tab Nook opened in the "Nook" tab group of its window, made once per window. */
async function groupWithNook(tab) {
  if (!chrome.tabGroups) return;
  try {
    const { groups = {} } = await chrome.storage.session.get('groups');
    let groupId = groups[tab.windowId];
    if (groupId !== undefined) {
      try {
        await chrome.tabGroups.get(groupId);
      } catch {
        groupId = undefined;
      }
    }
    groupId = await chrome.tabs.group(groupId === undefined ? { tabIds: [tab.id], createProperties: { windowId: tab.windowId } } : { tabIds: [tab.id], groupId });
    await chrome.tabGroups.update(groupId, { title: GROUP_TITLE, color: 'purple' });
    groups[tab.windowId] = groupId;
    await chrome.storage.session.set({ groups, group: groupId });
  } catch {
    // A browser without tab groups (or a pinned tab): the tab simply stays where it is.
  }
}

/** Nook only closes tabs it opened itself (those in its group), never one of the user's. */
async function close(tab) {
  const { groups = {} } = await chrome.storage.session.get('groups');
  if (!Object.values(groups).includes(tab.groupId)) {
    return { ok: false, error: `Tab ${tab.id} is one of the user's own tabs; Nook only closes tabs it opened (the Nook group).` };
  }
  await chrome.tabs.remove(tab.id);
  await chrome.storage.session.remove('current');
  return { ok: true, text: `Closed tab ${tab.id}.` };
}

function waitForLoad(tabId, timeout = LOAD_TIMEOUT) {
  return new Promise((resolve) => {
    let done = false;
    const finish = async () => {
      if (done) return;
      done = true;
      chrome.tabs.onUpdated.removeListener(listener);
      clearTimeout(timer);
      resolve(await chrome.tabs.get(tabId).catch(() => ({ url: '', title: '', status: 'gone' })));
    };
    const listener = (id, change) => {
      if (id === tabId && change.status === 'complete') finish();
    };
    const timer = setTimeout(finish, timeout);
    chrome.tabs.onUpdated.addListener(listener);
    // It may have loaded before the listener was there.
    setTimeout(async () => {
      const tab = await chrome.tabs.get(tabId).catch(() => null);
      if (!tab || (tab.status === 'complete' && tab.url && tab.url !== 'about:blank')) finish();
    }, 300);
  });
}

/** After a click or a key: if the page starts loading, wait for it, so the next look sees the new page. */
async function settle(tabId) {
  await new Promise((resolve) => setTimeout(resolve, 350));
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (tab?.status === 'loading') await waitForLoad(tabId, 10_000);
}

/** Runs one method of the page agent (page/agent.js) in the tab's main frame. */
async function agent(tabId, method, params) {
  await chrome.scripting.executeScript({ target: { tabId }, files: ['page/agent.js'] });
  const [frame] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (name, input) => globalThis.__nookAgent.run(name, input),
    args: [method, params]
  });
  const result = frame?.result;
  return result && typeof result === 'object' ? result : { ok: false, error: 'The page did not answer.' };
}

/** A strip on the page while Nook acts there, with a Stop button that pauses Nook in this browser. */
async function presence(tabId) {
  await chrome.scripting.executeScript({ target: { tabId }, files: ['page/presence.js'] }).catch(() => {});
}

async function screenshot(tab) {
  if (!tab.active) {
    await chrome.tabs.update(tab.id, { active: true });
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  await use(tab);
  const image = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'jpeg', quality: 70 });
  return { ok: true, image, url: tab.url, text: `Screenshot of ${tab.title || tab.url} (tab ${tab.id}).` };
}

async function waitFor(tab, params) {
  await use(tab);
  const seconds = Math.max(1, Math.min(Number(params.timeout) || 10, 30));
  const what = params.text ? `"${params.text}"` : params.selector;
  const until = Date.now() + seconds * 1000;
  while (Date.now() < until) {
    const current = await chrome.tabs.get(tab.id).catch(() => null);
    if (!current) return { ok: false, error: 'The tab was closed.' };
    if (current.status === 'complete') {
      const result = await agent(tab.id, 'condition', params).catch(() => null);
      if (result && !result.ok) return result;
      if (result?.met) return { ok: true, text: `${params.gone ? 'Gone' : 'Found'}: ${what} on ${current.url}.` };
    }
    if ((await settings()).paused) return { ok: false, error: 'The user paused Nook in this browser.' };
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
  return { ok: false, error: `Waited ${seconds} s; ${what} ${params.gone ? 'is still there' : 'did not appear'}. Look with chrome_find or chrome_screenshot.` };
}

/**
 * The page's console errors and warnings. The first call starts listening in the page itself (its main world), so it
 * sees only what comes after; reload the page with chrome_open url "reload" for messages during loading.
 */
async function consoleMessages(tab, params) {
  await use(tab);
  const [frame] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    world: 'MAIN',
    func: (clear) => {
      const key = '__nookConsole';
      if (!window[key]) {
        const kept = [];
        window[key] = kept;
        for (const level of ['error', 'warn']) {
          const original = console[level];
          console[level] = function (...args) {
            try {
              kept.push({ level, text: args.map((a) => (a instanceof Error ? a.stack || a.message : typeof a === 'object' ? JSON.stringify(a) : String(a))).join(' ').slice(0, 2000), at: Date.now() });
              if (kept.length > 200) kept.splice(0, kept.length - 200);
            } catch {
              // A value that cannot be turned into text.
            }
            return original.apply(this, args);
          };
        }
        window.addEventListener('error', (event) => kept.push({ level: 'error', text: String(event.message || event.error), at: Date.now() }));
        window.addEventListener('unhandledrejection', (event) => kept.push({ level: 'error', text: 'Unhandled rejection: ' + String(event.reason?.stack || event.reason), at: Date.now() }));
        return { started: true, entries: [] };
      }
      const entries = window[key].slice();
      if (clear) window[key].length = 0;
      return { started: false, entries };
    },
    args: [!!params.clear]
  });
  const result = frame?.result || { entries: [] };
  if (result.started) {
    return { ok: true, text: 'Nook now listens to this page\'s console. Call chrome_console again after the page did something (or after chrome_open url "reload").' };
  }
  if (!result.entries.length) return { ok: true, text: 'No console errors or warnings since Nook started listening.' };
  return { ok: true, text: result.entries.map((e) => `${e.level}: ${e.text}`).join('\n') };
}

// MARK: - The side panel and the page's Stop button

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  handlePanel(message, sender).then(reply, (error) => reply({ ok: false, error: String(error?.message || error) }));
  return true;
});

async function handlePanel(message) {
  switch (message?.type) {
    case 'connect':
      if (!port) {
        attempt = 0;
        connect();
      }
      return { ok: true };
    case 'pause': {
      await chrome.storage.local.set({ paused: !!message.paused });
      await remember({ icon: message.paused ? 'pause' : 'resume', text: message.paused ? 'Paused Nook in this browser' : 'Nook may use this browser again', ok: true });
      return { ok: true };
    }
    case 'site': {
      const site = siteOf(message.url);
      if (!site) return { ok: false };
      const { blocked } = await settings();
      const next = message.allowed ? blocked.filter((entry) => entry !== site) : [...new Set([...blocked, site])];
      await chrome.storage.local.set({ blocked: next });
      return { ok: true };
    }
    case 'ask': {
      const tab = await activeTab(message.windowId);
      const page = tab && !isRestricted(tab.url) ? { title: tab.title || '', url: tab.url || '', tab: tab.id } : null;
      return request({ kind: 'ask', text: String(message.text || ''), conversation: message.conversation || null, page });
    }
    case 'look':
      return { ok: true, look: await refreshLook() };
    case 'chat':
      return request({ kind: 'chat', conversation: message.conversation });
    case 'stopChat':
      return request({ kind: 'stopChat', conversation: message.conversation });
    default:
      return { ok: false, error: 'Unknown message.' };
  }
}

async function activeTab(windowId) {
  const query = windowId ? { active: true, windowId } : { active: true, lastFocusedWindow: true };
  const [tab] = await chrome.tabs.query(query);
  return tab || null;
}

// MARK: - Start

chrome.sidePanel?.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});

// The badge says when Nook is paused here, so it is never paused without the user seeing it.
async function updateBadge() {
  const { paused } = await settings();
  await chrome.action.setBadgeBackgroundColor({ color: '#e0a23a' });
  await chrome.action.setBadgeText({ text: paused ? '❚❚' : '' });
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.paused) updateBadge();
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
// A minute's alarm keeps trying while Nook is not there yet, also after the browser put this worker to sleep.
chrome.alarms?.create('reconnect', { periodInMinutes: 1 });
chrome.alarms?.onAlarm.addListener((alarm) => {
  if (alarm.name === 'reconnect' && !port) connect();
  else if (alarm.name === 'reconnect') refreshLook();
});
updateBadge();
connect();

