// Nook's browser extension, service worker. It keeps one native messaging port open to Nook on this Mac (the host
// script Nook installs, see docs/BROWSER-EXTENSION.md), runs the commands Nook sends on the user's tabs, and carries the
// side panel's questions to Nook. Nook decides what may happen: every action already passed Nook's approval card before
// it reaches this file. The user keeps two brakes here: pausing Nook in this browser, and switching it off per site.
import {
  GROUP_TITLE, HOST_NAME, PROTOCOL_VERSION, activityLine, browserName, cleanLook, commandError, consoleText,
  describeTabs, isAnswering, isBlocked, isRestricted, normalizeURL, panelMessageAllowed, questionImages, reconnectDelay,
  serial, siteOf
} from './lib/core.js';

const REQUEST_TIMEOUT = 20_000;
const LOAD_TIMEOUT = 20_000;
const ACTIVITY_LIMIT = 40;
/** As much page text as goes along with a question from the side panel (BrowserExtensionPanel.textLimit in Nook). */
const PAGE_TEXT_LIMIT = 16_000;
const PAGE_READ_TIMEOUT = 1_500;

let port = null;
let attempt = 0;
let reconnectTimer = null;
let nextRequest = 0;
const waiting = new Map();
// Read-modify-writes of session storage run one at a time, so concurrent commands never drop each other's change.
const inOrder = serial();

// MARK: - Settings and status (what the side panel shows)

// Read once and kept up to date by storage.onChanged, so a command does not wait for storage each time.
let cachedSettings = null;

async function settings() {
  if (cachedSettings) return cachedSettings;
  const stored = await chrome.storage.local.get({ paused: false, blocked: [] });
  cachedSettings = { paused: !!stored.paused, blocked: Array.isArray(stored.blocked) ? stored.blocked : [] };
  return cachedSettings;
}

/** Never throws: callers fire it and move on, and a failed write must not become an unhandled rejection. */
async function setStatus(status) {
  try {
    await chrome.storage.session.set({ status: { ...status, at: Date.now() } });
  } catch {
    // Storage is gone (the browser is shutting down); the panel reads the next status.
  }
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

/** Never throws: the activity list is for the user's eyes, and a failure there must not keep a result from Nook. */
function remember(line) {
  return inOrder(async () => {
    const stored = await chrome.storage.session.get('activity');
    const activity = Array.isArray(stored.activity) ? stored.activity : [];
    activity.unshift({ ...line, at: Date.now() });
    await chrome.storage.session.set({ activity: activity.slice(0, ACTIVITY_LIMIT) });
  }).catch(() => {});
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
  // The port this hello goes over. When it closes before Nook answers, its onDisconnect already said why ("missing"
  // when Nook never installed its host here); that must not be overwritten with a plain "offline".
  const sent = port;
  try {
    const brands = navigator.userAgentData?.brands || [];
    const reply = await request({
      kind: 'hello', protocol: PROTOCOL_VERSION, version: chrome.runtime.getManifest().version,
      browser: browserName(brands, navigator.userAgent), extension: chrome.runtime.id
    });
    if (port !== sent) return;
    if (reply?.ok) {
      attempt = 0;
      await setStatus({ nook: 'connected', name: reply.name || 'Nook', version: reply.version || '' });
      refreshLook();
    } else {
      await setStatus({ nook: 'offline', detail: reply?.error || '' });
    }
  } catch (error) {
    if (port === sent && port) await setStatus({ nook: 'offline', detail: String(error?.message || error) });
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
    try {
      port.postMessage({ ...message, rid });
    } catch (error) {
      // The port closed and its onDisconnect has not run yet.
      waiting.delete(rid);
      clearTimeout(timer);
      reject(new Error('Nook is not connected.'));
    }
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
      run(message).catch(() => {});
      break;
    case 'chat':
      // A conversation the side panel follows changed: Nook pushes it, so the answer streams in without asking.
      chrome.runtime.sendMessage({ type: 'chatUpdate', conversation: message.conversation, messages: message.messages, revision: message.revision })
        .catch(() => {});
      // Nook finished its answer: the user's hands are free again on the page it worked in, right away.
      if (Array.isArray(message.messages) && message.messages.length && !isAnswering(message.messages)) releaseCurrent();
      break;
    default:
      break;
  }
}

// MARK: - Commands from Nook

/** The tab a command works in: the one it names, else the one Nook worked in last, else the one in front. */
async function targetTab(params) {
  // Double Tap works in the tab the user looks at, never in the one Nook used last.
  if (params.front) return frontTab();
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
  return frontTab();
}

/** The active tab of the window in front. */
async function frontTab() {
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
    outcome = error ? { ok: false, error } : await perform(command.method, params, tab, command);
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

async function perform(method, params, tab, command) {
  switch (method) {
    case 'tabs': return listTabs();
    case 'open': return open(params, tab, command);
    case 'close': return close(tab);
    case 'screenshot': return screenshot(tab);
    case 'wait': return waitFor(tab, params);
    case 'console': return consoleMessages(tab, params);
    case 'find': case 'read':
      await use(tab);
      return agent(tab.id, method, params);
    case 'scroll': {
      await use(tab);
      await presence(tab.id, 'busy');
      const result = await agent(tab.id, method, { ...params, _from: cursors.get(tab.id) });
      keepCursor(tab.id, result);
      return result;
    }
    // Double Tap: read the form in front and fill it, without making it the tab Nook works in.
    case 'form':
      return agent(tab.id, method, params);
    case 'fill': {
      const result = await agent(tab.id, method, params);
      if (result.ok) await settle(tab.id);
      return result;
    }
    case 'click': case 'type': case 'key': {
      await use(tab);
      await presence(tab.id, 'busy');
      // Listening for a tab the action opens starts before the action: a link can open one before the page answers.
      const opened = openedFrom(tab.id);
      let result;
      let after;
      try {
        result = await agent(tab.id, method, { ...params, _from: cursors.get(tab.id) });
        keepCursor(tab.id, result);
        // Typing a password or a sign-in code is the user's: Nook waits for them to sign in, then goes on.
        if (!result.ok && result.signIn) return waitForSignIn(tab.id, command, '');
        if (!result.ok) return result;
        // What the action did, and what can be used now: Nook takes its next step from this without looking again.
        after = await settle(tab.id, opened);
      } finally {
        opened.stop();
      }
      let text = result.text;
      if (after.opened) text += ` It opened a new tab (tab ${after.tabId}); Nook works there now.`;
      const login = await signInWait(after.tabId, command, text);
      if (login) return login;
      const look = await glance(after.tabId);
      if (look) text += '\n\n' + look;
      return { ...result, text };
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

async function open(params, tab, command) {
  const where = String(params.url || '').trim().toLowerCase();
  if (tab && where === 'back') await chrome.tabs.goBack(tab.id);
  else if (tab && where === 'forward') await chrome.tabs.goForward(tab.id);
  else if (tab && where === 'reload') await chrome.tabs.reload(tab.id);
  else {
    const url = normalizeURL(params.url);
    if (tab) {
      await chrome.tabs.update(tab.id, { url });
    } else {
      // While the user works in another tab than Nook's, the new page opens beside it without taking their view.
      tab = await chrome.tabs.create({ url, active: !(await userElsewhere()) });
      await groupWithNook(tab);
    }
  }
  await use(tab);
  const loaded = await waitForLoad(tab.id);
  await presence(tab.id, 'busy');
  const login = await signInWait(tab.id, command, `Opened ${loaded.url} in tab ${tab.id}.`);
  if (login) return login;
  // What can be used on it goes along, so the next step needs no chrome_find first.
  const look = await glance(tab.id);
  return {
    ok: true, url: loaded.url,
    text: `Opened ${loaded.title || '(no title)'} | ${loaded.url} in tab ${tab.id}${loaded.status === 'complete' ? '' : ' (still loading)'}. `
      + 'Use chrome_read for its text.' + (look ? '\n\n' + look : ' Use chrome_find for what you can click and type in.')
  };
}

/** Puts a tab Nook opened in the "Nook" tab group of its window, made once per window. */
function groupWithNook(tab) {
  if (!chrome.tabGroups) return Promise.resolve();
  // One at a time: two tabs opened at once would otherwise each make a group, and the first one's id would be lost,
  // so Nook could no longer close the tabs it opened there.
  return inOrder(() => addToNookGroup(tab));
}

async function addToNookGroup(tab) {
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
    }, 150);
  });
}

/**
 * After a click, a key or typing: waits for what it did, so the next look sees it. A new page loading: until it is
 * there. A link that opened a tab of its own: Nook goes on in that tab. Otherwise until the page stops changing (a
 * menu opening, results coming in), never a fixed wait.
 */
/** Notes a tab opened from `tabId` (a link with target=_blank) from now on, until `stop()`. */
function openedFrom(tabId) {
  const watch = { tab: null, stop: () => chrome.tabs.onCreated?.removeListener(onCreated) };
  function onCreated(created) {
    if (created.openerTabId === tabId && !watch.tab) watch.tab = created;
  }
  chrome.tabs.onCreated?.addListener(onCreated);
  return watch;
}

async function settle(tabId, watch = { tab: null }) {
  for (const pause of [90, 160]) {
    if (watch.tab) break;
    await new Promise((resolve) => setTimeout(resolve, pause));
    if (watch.tab) break;
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (tab?.status === 'loading') {
      await waitForLoad(tabId, 10_000);
      return { tabId, navigated: true };
    }
  }
  const opened = watch.tab;
  if (opened) {
    await waitForLoad(opened.id, 10_000);
    await use(opened);
    return { tabId: opened.id, opened: true };
  }
  if (await mayRead(tabId)) await withTimeout(agent(tabId, 'quiet', {}), 2_000);
  return { tabId };
}

/**
 * Whether Nook may still look at the page in this tab now: not paused, and its site not switched off or one of the
 * browser's own pages. Checked again before every look Nook takes by itself, because an action can take the tab to
 * another site than the one the command was checked for.
 */
async function mayRead(tabId) {
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab) return false;
  const url = tab.url || tab.pendingUrl || '';
  const { paused, blocked } = await settings();
  return !paused && !isRestricted(url) && !isBlocked(url, blocked);
}

/** What the user sees on the page now, in short (page/agent.js `glance`); '' when the page does not answer in time. */
async function glance(tabId) {
  if (!(await mayRead(tabId))) {
    return 'The page is now on a site the user switched Nook off for (or one of the browser\'s own pages); Nook did not look at it.';
  }
  const look = await withTimeout(agent(tabId, 'glance', {}), 1_500);
  return look?.ok ? look.text : '';
}

function withTimeout(promise, ms) {
  return Promise.race([promise.catch(() => null), new Promise((resolve) => setTimeout(() => resolve(null), ms))]);
}

// Where Nook's cursor was on each tab, so it glides on from there on the next page instead of starting over.
const cursors = new Map();

function keepCursor(tabId, result) {
  if (result?.cursor && Number.isFinite(result.cursor.x)) cursors.set(tabId, result.cursor);
}

chrome.tabs.onRemoved?.addListener((tabId) => cursors.delete(tabId));

/**
 * Runs one method of the page agent (page/agent.js) in the tab's main frame. The agent stays in the page until it
 * reloads, so it is injected only when it is not there yet: one trip to the page instead of two for most commands.
 */
async function agent(tabId, method, params) {
  const call = async () => {
    const [frame] = await chrome.scripting.executeScript({
      target: { tabId },
      func: (name, input) => (globalThis.__nookAgent ? globalThis.__nookAgent.run(name, input) : { missing: true }),
      args: [method, params]
    });
    return frame?.result;
  };
  let result = await call();
  if (result?.missing) {
    await chrome.scripting.executeScript({ target: { tabId }, files: ['page/agent.js'] });
    result = await call();
  }
  return result && typeof result === 'object' && !result.missing ? result : { ok: false, error: 'The page did not answer.' };
}

/**
 * The page in front as the side panel's question takes it along: its title and address, and, when Nook may use this
 * site, its text and the user's selection, so Nook answers about it right away instead of first reading it with a
 * tool. A page that does not answer quickly goes without its text.
 */
async function pageForQuestion(tab) {
  if (!tab || isRestricted(tab.url)) return null;
  const page = { title: tab.title || '', url: tab.url || '', tab: tab.id };
  const { paused, blocked } = await settings();
  if (paused || isBlocked(tab.url, blocked)) return page;
  const reading = agent(tab.id, 'read', { limit: PAGE_TEXT_LIMIT, plain: true }).catch(() => null);
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), PAGE_READ_TIMEOUT));
  const result = await Promise.race([reading, timeout]);
  if (result?.ok) {
    page.text = result.text || '';
    page.selection = result.selection || '';
  }
  return page;
}

/**
 * The strip on the page (page/presence.js): `busy` while Nook acts there (with a Stop button, and the user's own clicks
 * and keys on that page held back for a while), `signIn` while the user signs in, `release` when Nook is done.
 */
async function presence(tabId, mode = 'busy') {
  // A page on a site the user switched off (or that the tab was sent on to since) is never touched: no strip there,
  // and the user's input there is never held.
  if (mode !== 'release' && !(await mayRead(tabId))) return;
  try {
    // Releasing needs nothing new on a page that never had the strip.
    if (mode !== 'release') await chrome.scripting.executeScript({ target: { tabId }, files: ['page/presence.js'] });
    await chrome.scripting.executeScript({
      target: { tabId },
      func: (name, hold) => globalThis.__nookPresence?.[name]?.(hold),
      args: [mode, BUSY_HOLD]
    });
  } catch {
    // A page the browser keeps to itself, or one that is loading: nothing to show there.
  }
}

async function releaseCurrent() {
  const { current } = await chrome.storage.session.get('current');
  if (Number.isInteger(current)) await presence(current, 'release');
}

/** How long the user's own clicks wait after Nook's last action on a page (its next step usually comes sooner). */
const BUSY_HOLD = 12_000;
/** How long Nook waits for the user to sign in on a page. */
const SIGN_IN_WAIT = 5 * 60_000;

/** True while the user looks at another tab than the one Nook works in: Nook then works beside them, not in their view. */
async function userElsewhere() {
  const { current } = await chrome.storage.session.get('current');
  if (!Number.isInteger(current)) return false;
  const front = await activeTab(null).catch(() => null);
  return !!front && front.id !== current;
}

/** When the page now asks to sign in, waits for the user to do so (`waitForSignIn`); null when it does not. */
async function signInWait(tabId, command, before) {
  if (!(await mayRead(tabId))) return null;
  const state = await withTimeout(agent(tabId, 'signin', {}), 2_000);
  if (!state?.needed) return null;
  return waitForSignIn(tabId, command, before, state.site);
}

/**
 * The page asks to sign in: Nook steps aside. The tab comes to the front, the strip asks the user to sign in, their
 * clicks and keys work as always, and Nook goes on by itself once the sign-in fields are gone and the page settled (or
 * the user presses Continue). Nook never sees what they type. Nook's own deadline for the command moves on meanwhile.
 */
async function waitForSignIn(tabId, command, before = '', site = '') {
  request({ kind: 'extend', id: command.id, seconds: SIGN_IN_WAIT / 1000 + 30 }).catch(() => {});
  await presence(tabId, 'signIn');
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (tab && !tab.active) {
    await chrome.tabs.update(tabId, { active: true }).catch(() => {});
    await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  }
  await remember({ icon: 'key', text: 'Waiting for you to sign in', site: site || siteOf(tab?.url || ''), ok: true });
  const until = Date.now() + SIGN_IN_WAIT;
  let clear = 0;
  while (Date.now() < until) {
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    if ((await settings()).paused) {
      await presence(tabId, 'release');
      return { ok: false, error: 'The user paused Nook in this browser while signing in. Do not try again; tell the user what you wanted to do.' };
    }
    const now = await chrome.tabs.get(tabId).catch(() => null);
    if (!now) return { ok: false, error: 'The tab was closed while the user signed in.' };
    // The user pressed Continue on the strip: read in the page's isolated world, so no page can send it as a message.
    const [pressed] = await chrome.scripting.executeScript({
      target: { tabId }, func: () => globalThis.__nookPresence?.continued === true
    }).catch(() => []);
    if (pressed?.result) break;
    if (now.status !== 'complete') {
      clear = 0;
      continue;
    }
    // Signing in took the tab to a site the user switched Nook off for: Nook stops looking there.
    if (!(await mayRead(tabId))) {
      await presence(tabId, 'release');
      return { ok: true, text: `${before ? before + ' ' : ''}The user signed in; the page is now on a site they switched Nook off for, so Nook does not look at it. Tell the user what you wanted to do there.` };
    }
    const state = await withTimeout(agent(tabId, 'signin', {}), 2_000);
    clear = state && !state.needed ? clear + 1 : 0;
    // Gone twice in a row: not a field that blinks while the page moves on to the next step (a code, a second page).
    if (clear >= 2) break;
  }
  if (clear < 2 && Date.now() >= until) {
    await presence(tabId, 'release');
    return { ok: false, error: `The page asked to sign in and the user did not within ${SIGN_IN_WAIT / 60_000} minutes. Ask them to sign in, then try again.` };
  }
  await presence(tabId, 'busy');
  const look = await glance(tabId);
  return {
    ok: true,
    text: `${before ? before + ' ' : ''}The page asked to sign in; the user signed in themselves (Nook did not see what they typed). Go on with the task.`
      + (look ? '\n\n' + look : '')
  };
}

async function screenshot(tab) {
  // A screenshot needs the tab in view. While the user works in another tab, Nook does not take their view away.
  if (!tab.active && await userElsewhere()) {
    return { ok: false, error: `Tab ${tab.id} is in the background while the user works in another tab; a screenshot would take their view away. Use chrome_read or chrome_find instead: they work in the background.` };
  }
  if (!tab.active) {
    await chrome.tabs.update(tab.id, { active: true });
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  await use(tab);
  // captureVisibleTab takes whatever the window shows now. If the user switched tabs meanwhile, that may be a site they
  // switched Nook off for, or the browser's own pages: check what is in front right before taking it.
  const [front] = await chrome.tabs.query({ active: true, windowId: tab.windowId });
  if (!front || front.id !== tab.id) {
    return { ok: false, error: `Tab ${tab.id} is no longer the one in front (the user switched tabs). Try again, or ask the user.` };
  }
  const refused = commandError({ method: 'screenshot', params: {} }, { ...(await settings()), url: front.url || front.pendingUrl || '' });
  if (refused) return { ok: false, error: refused };
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
  // This ran in the page's own world, so the page may have put anything in the list: read it with care.
  const result = frame?.result && typeof frame.result === 'object' ? frame.result : {};
  if (result.started === true) {
    return { ok: true, text: 'Nook now listens to this page\'s console. Call chrome_console again after the page did something (or after chrome_open url "reload").' };
  }
  return { ok: true, text: consoleText(result.entries) || 'No console errors or warnings since Nook started listening.' };
}

// MARK: - The side panel and the page's Stop button

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!panelMessageAllowed(message, sender, chrome.runtime.id)) {
    reply({ ok: false, error: 'Not allowed.' });
    return false;
  }
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
      const page = await pageForQuestion(tab);
      // Pictures from the composer (pasted, dropped or picked) go along; the Mac scales them for the model.
      const images = questionImages(message.images);
      const question = { kind: 'ask', text: String(message.text || ''), conversation: message.conversation || null, page };
      return request(images.length ? { ...question, images } : question);
    }
    case 'look':
      return { ok: true, look: await refreshLook() };
    case 'chat':
      return request({ kind: 'chat', conversation: message.conversation, watch: !!message.watch });
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
  try {
    const { paused } = await settings();
    await chrome.action.setBadgeBackgroundColor({ color: '#e0a23a' });
    await chrome.action.setBadgeText({ text: paused ? '❚❚' : '' });
  } catch {
    // The badge is a hint; the side panel still says Nook is paused.
  }
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && (changes.paused || changes.blocked)) cachedSettings = null;
  if (area === 'local' && changes.paused) updateBadge();
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
// The side panel does not have to be open: the browser wakes this worker for these events, so it is connected again by
// the time the user switches to the browser or a tab and taps for Double Tap there.
chrome.windows?.onFocusChanged?.addListener(() => { if (!port) connect(); });
chrome.tabs?.onActivated?.addListener(() => { if (!port) connect(); });
chrome.tabs?.onUpdated?.addListener((_id, change) => { if (!port && change.status === 'loading') connect(); });
// A half-minute alarm (the shortest a browser allows) keeps trying while Nook is not there yet, also after the browser
// put this worker to sleep.
chrome.alarms?.create('reconnect', { periodInMinutes: 0.5 });
chrome.alarms?.onAlarm.addListener((alarm) => {
  if (alarm.name === 'reconnect' && !port) connect();
  else if (alarm.name === 'reconnect') refreshLook();
});
updateBadge();
connect();

