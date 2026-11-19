// Nook's browser extension, service worker. It keeps one native messaging port open to Nook on this Mac (the host
// script Nook installs, see docs/BROWSER-EXTENSION.md), runs the commands Nook sends on the user's tabs, and carries the
// side panel's questions to Nook. Nook decides what may happen: every action already passed Nook's approval card before
// it reaches this file. The user keeps two brakes here: pausing Nook in this browser, and switching it off per site.
import {
  ACT_METHODS, GROUP_TITLE, HOST_NAME, PROTOCOL_VERSION, activityLine, approvalCard, approvalDecision, browserName,
  cleanLook, commandError, consoleText, mustAsk,
  describeTabs, elementsCopy, isAnswering, isBlocked, isRestricted, looksLikePdf, mayPick, normalizeURL, panelMessageAllowed,
  pdfCrop, pdfPointCopy, questionImages, reconnectDelay, serial, siteOf
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
  const stored = await chrome.storage.local.get({ paused: false, blocked: [], trusted: [] });
  cachedSettings = {
    paused: !!stored.paused,
    blocked: Array.isArray(stored.blocked) ? stored.blocked : [],
    // The sites the user lets Nook act on without asking first (a task from the side panel; see `approve`).
    trusted: Array.isArray(stored.trusted) ? stored.trusted : []
  };
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
      chrome.runtime.sendMessage({
        type: 'chatUpdate', conversation: message.conversation, messages: message.messages, earlier: message.earlier,
        revision: message.revision
      })
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
  const current = await currentTab();
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
    const error = commandError(command, { ...(await settings()), url: tab ? tab.url || tab.pendingUrl || '' : undefined })
      || await approve(command, tab);
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
      const [, result] = await Promise.all([presence(tab.id, 'busy'), agent(tab.id, method, { ...params, _from: cursors.get(tab.id) })]);
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
      // Listening for a page or a tab the action opens starts before the action: a link can open one before the page
      // answers.
      const watch = watchFrom(tab.id);
      let result;
      let after;
      try {
        // The strip goes up while the cursor already moves: the hold on the user's input is there long before the click.
        [, result] = await Promise.all([presence(tab.id, 'busy'), agent(tab.id, method, { ...params, _from: cursors.get(tab.id) })]);
        keepCursor(tab.id, result);
        // Typing a password or a sign-in code is the user's: Nook waits for them to sign in, then goes on.
        if (!result.ok && result.signIn) return waitForSignIn(tab.id, command, '');
        if (!result.ok) return result;
        // What the action did, and what can be used now: Nook takes its next step from this without looking again.
        after = await settle(tab.id, watch);
      } finally {
        watch.stop();
      }
      let text = result.text;
      if (after.opened) text += ` It opened a new tab (tab ${after.tabId}); Nook works there now.`;
      if (after.navigated) text += ' A new page loaded.';
      const login = await signInWait(after.tabId, command, text, after.state);
      if (login) return login;
      const look = await glance(after.tabId, after.state);
      if (look) text += '\n\n' + look;
      return { ...result, text };
    }
    default:
      return { ok: false, error: `Nook's extension does not know "${method}".` };
  }
}

// The tab Nook works in, kept here as well as in session storage (which outlives a sleeping worker), so a command does
// not wait for storage each time.
let current = undefined;

async function currentTab() {
  if (current === undefined) current = (await chrome.storage.session.get('current')).current ?? null;
  return current;
}

/** From now on Nook works in this tab, until it opens or names another. */
async function use(tab) {
  if (current === tab.id) return;
  current = tab.id;
  await chrome.storage.session.set({ current: tab.id });
}

async function listTabs() {
  const tabs = await chrome.tabs.query({});
  const focused = await chrome.windows.getLastFocused({ windowTypes: ['normal'] }).catch(() => null);
  const { group } = await chrome.storage.session.get('group');
  return { ok: true, text: describeTabs(tabs, { focusedWindow: focused?.id, nookGroup: group, current: await currentTab() }) };
}

async function open(params, tab, command) {
  const since = Date.now();
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
  const loaded = await waitForLoad(tab.id, LOAD_TIMEOUT, since);
  const [, state] = await Promise.all([presence(tab.id, 'busy'), afterLook(tab.id)]);
  const login = await signInWait(tab.id, command, `Opened ${loaded.url} in tab ${tab.id}.`, state);
  if (login) return login;
  // What can be used on it goes along, so the next step needs no chrome_find first.
  const look = await glance(tab.id, state);
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
  if (current === tab.id) current = null;
  await chrome.storage.session.remove('current');
  return { ok: true, text: `Closed tab ${tab.id}.` };
}

/**
 * Waits until the page in a tab can be used: its document is parsed (`interactive`), not until every picture, font and
 * advert is in (`complete`, often seconds later on a busy site). `since`: when the navigation started; a document from
 * before then is the old page still showing, so only a newer one counts (its `performance.timeOrigin`). Without
 * `since`, or when the page cannot be asked, the browser's own `complete` decides.
 */
function waitForLoad(tabId, timeout = LOAD_TIMEOUT, since = 0) {
  return new Promise((resolve) => {
    let done = false;
    let checking = false;
    const finish = async () => {
      if (done) return;
      done = true;
      chrome.tabs.onUpdated.removeListener(listener);
      clearTimeout(timer);
      clearInterval(poll);
      resolve(await chrome.tabs.get(tabId).catch(() => ({ url: '', title: '', status: 'gone' })));
    };
    const listener = (id, change) => {
      if (id === tabId && change.status === 'complete') finish();
    };
    const timer = setTimeout(finish, timeout);
    chrome.tabs.onUpdated.addListener(listener);
    const check = async () => {
      if (done || checking) return;
      checking = true;
      try {
        const tab = await chrome.tabs.get(tabId).catch(() => null);
        if (!tab) return finish();
        // It may have loaded before the listener was there.
        if (tab.status === 'complete' && tab.url && tab.url !== 'about:blank') return finish();
        // A page Nook may not look at (the browser's own, or a site the user switched off) is never asked anything.
        if (!since || !(await mayRead(tabId))) return;
        const [frame] = await chrome.scripting.executeScript({
          target: { tabId }, func: () => ({ state: document.readyState, origin: performance.timeOrigin, url: location.href })
        }).catch(() => []);
        const page = frame?.result;
        if (page && page.state !== 'loading' && page.origin >= since - 50 && page.url !== 'about:blank') finish();
      } finally {
        checking = false;
      }
    };
    setTimeout(check, 60);
    const poll = setInterval(check, 150);
  });
}

/**
 * Notes from now on, until `stop()`, what an action in `tabId` sets going: a new page loading there, or a tab of its
 * own (a link with target=_blank).
 */
function watchFrom(tabId) {
  const since = Date.now();
  const watch = {
    since, tab: null, loading: false,
    stop: () => {
      chrome.tabs.onCreated?.removeListener(onCreated);
      chrome.tabs.onUpdated?.removeListener(onUpdated);
    }
  };
  function onCreated(created) {
    if (created.openerTabId === tabId && !watch.tab) watch.tab = created;
  }
  function onUpdated(id, change) {
    if (id === tabId && change.status === 'loading') watch.loading = true;
  }
  chrome.tabs.onCreated?.addListener(onCreated);
  chrome.tabs.onUpdated?.addListener(onUpdated);
  return watch;
}

/**
 * After a click, a key or typing: waits for what it did, so the next look sees it, and looks in the same trip. A new
 * page loading: until it can be used. A link that opened a tab of its own: Nook goes on in that tab. Otherwise until the
 * page stops changing (a menu opening, results coming in), never a fixed wait. `state` is the page's answer to
 * `after` (sign-in and glance), when it gave one.
 */
async function settle(tabId, watch = { tab: null, loading: false, since: Date.now() }) {
  // The browser says a navigation or a new tab started within a few milliseconds of the click; a short look covers it.
  await new Promise((resolve) => setTimeout(resolve, 40));
  for (let round = 0; round < 2; round += 1) {
    if (watch.tab) {
      const opened = watch.tab;
      await waitForLoad(opened.id, 10_000, watch.since);
      await use(opened);
      return { tabId: opened.id, opened: true, state: await afterLook(opened.id) };
    }
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (watch.loading || tab?.status === 'loading') {
      await waitForLoad(tabId, 10_000, watch.since);
      return { tabId, navigated: true, state: await afterLook(tabId) };
    }
    // Quiet, then sign-in and what is in view, in one trip. A page that navigates while it waits does not answer: then
    // the round above waits for the new one.
    const state = (await mayRead(tabId)) ? await withTimeout(agent(tabId, 'after', {}), 2_500) : null;
    if (state?.ok || (!watch.loading && !watch.tab)) return { tabId, state: state?.ok ? state : null };
  }
  return { tabId };
}

/** Sign-in and what is in view on a page that just loaded (`after` without waiting for quiet); null when it may not. */
async function afterLook(tabId) {
  if (!(await mayRead(tabId))) return null;
  const state = await withTimeout(agent(tabId, 'after', { idle: 80, limit: 600 }), 2_000);
  return state?.ok ? state : null;
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

/**
 * What the user sees on the page now, in short (page/agent.js `glance`); '' when the page does not answer in time.
 * `state`: what `after` already saw, so the page is not asked twice.
 */
async function glance(tabId, state = null) {
  if (!(await mayRead(tabId))) {
    return 'The page is now on a site the user switched Nook off for (or one of the browser\'s own pages); Nook did not look at it.';
  }
  if (state?.look?.ok) return state.look.text;
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
    const call = () => chrome.scripting.executeScript({
      target: { tabId },
      func: (name, hold) => {
        if (!globalThis.__nookPresence) return 'missing';
        globalThis.__nookPresence[name]?.(hold);
        return 'done';
      },
      args: [mode, BUSY_HOLD]
    });
    // The strip stays in the page until it reloads: injected only when it is not there yet (one trip instead of two).
    // Releasing needs nothing new on a page that never had the strip.
    const [frame] = await call();
    if (frame?.result === 'missing' && mode !== 'release') {
      await chrome.scripting.executeScript({ target: { tabId }, files: ['page/presence.js'] });
      await call();
    }
  } catch {
    // A page the browser keeps to itself, or one that is loading: nothing to show there.
  }
}

async function releaseCurrent() {
  const tabId = await currentTab();
  if (Number.isInteger(tabId)) await presence(tabId, 'release');
}

/** How long the user's own clicks wait after Nook's last action on a page (its next step usually comes sooner). */
const BUSY_HOLD = 12_000;
/** How long Nook waits for the user to sign in on a page. */
const SIGN_IN_WAIT = 5 * 60_000;

/** True while the user looks at another tab than the one Nook works in: Nook then works beside them, not in their view. */
async function userElsewhere() {
  const tabId = await currentTab();
  if (!Number.isInteger(tabId)) return false;
  const front = await activeTab(null).catch(() => null);
  return !!front && front.id !== tabId;
}

/** When the page now asks to sign in, waits for the user to do so (`waitForSignIn`); null when it does not. */
async function signInWait(tabId, command, before, seen = null) {
  if (!(await mayRead(tabId))) return null;
  const state = seen?.signIn || await withTimeout(agent(tabId, 'signin', {}), 2_000);
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

// MARK: - Asking before a step of a task from the side panel

// A task the user gives Nook in the side panel runs live (BrowserTask in Nook): each step comes with `ask`, and waits
// here for the user's yes in the side panel, unless they let Nook act on that site without asking and the step is not
// one that cannot be undone. Steps from anywhere else (Nook Chat on the Mac, a coding agent) already passed Nook's own
// approval card and come without `ask`.

/** The steps waiting for the user, by command id. */
const approvals = new Map();
/** How long a step waits for the user's answer. */
const APPROVAL_WAIT = 5 * 60_000;

/** Null when the step may run; else why it did not (the text Nook's brain reads). */
async function approve(command, tab) {
  const ask = command.ask;
  if (!ask || typeof ask !== 'object' || !ACT_METHODS.has(command.method)) return null;
  const params = command.params || {};
  const url = tab ? tab.url || tab.pendingUrl || '' : normalizeURL(params.url) || '';
  // What the step touches, in the page's own words: a send or pay button always asks.
  let words = typeof params.text === 'string' ? params.text : '';
  if (tab && ['click', 'type', 'key'].includes(command.method) && await mayRead(tab.id)) {
    const seen = await withTimeout(agent(tab.id, 'intent', params), 1_500);
    if (seen?.ok && typeof seen.words === 'string') words += ' · ' + seen.words;
  }
  const { trusted } = await settings();
  const verdict = mustAsk({ url, trusted, submits: ask.submits === true, words });
  if (!verdict.ask) return null;
  const card = approvalCard(command.id, ask, siteOf(url), verdict.final);
  if (!card) return 'This step could not be shown to the user; it did not run.';
  // Nook's deadline for the command moves on while the user decides.
  request({ kind: 'extend', id: command.id, seconds: APPROVAL_WAIT / 1000 + 30 }).catch(() => {});
  const decision = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve('timeout'), APPROVAL_WAIT);
    approvals.set(card.id, { card, resolve: (answer) => { clearTimeout(timer); resolve(answer); } });
    publishApprovals();
  });
  approvals.delete(card.id);
  publishApprovals();
  if (decision === 'site') await trustSite(card.site, true);
  if (decision === 'once' || decision === 'site') return null;
  if (decision === 'timeout') {
    return `The user did not answer in the side panel within ${APPROVAL_WAIT / 60_000} minutes; the step did not run. Say what you wanted to do and stop.`;
  }
  return 'The user said no to this step in the side panel; it did not run. Do not try it another way. Say what is done and what is left, and stop.';
}

/** The steps waiting for the user, for the side panel (which reads them from session storage, also when it opens later). */
function publishApprovals() {
  chrome.storage.session.set({ approvals: [...approvals.values()].map((entry) => entry.card) }).catch(() => {});
}

/** The side panel's answer for a waiting step. */
function decide(id, decision) {
  const entry = approvals.get(id);
  if (!entry) return false;
  entry.resolve(approvalDecision(decision, entry.card));
  return true;
}

/** Every waiting step is refused (the user paused Nook here, or stopped its answer). */
function refuseAll() {
  for (const id of [...approvals.keys()]) decide(id, 'deny');
}

async function trustSite(site, allowed) {
  if (!site) return;
  const { trusted } = await settings();
  const next = allowed ? [...new Set([...trusted, site])] : trusted.filter((entry) => entry !== site);
  await chrome.storage.local.set({ trusted: next });
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
      if (message.paused) refuseAll();
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
      // With `before`: the messages before the oldest one the panel has, to read further back.
      if (typeof message.before === 'string') {
        return request({ kind: 'chat', conversation: message.conversation, before: message.before.slice(0, 64) });
      }
      return request({ kind: 'chat', conversation: message.conversation, watch: !!message.watch });
    // The panel's "Earlier chats" menu: only the conversations it started itself.
    case 'chats':
      return request({ kind: 'chats', conversations: chatIds(message.conversations) });
    case 'stopChat':
      refuseAll();
      return request({ kind: 'stopChat', conversation: message.conversation });
    // A step of a task waiting for the user: once, always on this site, or no.
    case 'decide':
      return { ok: decide(String(message.id || ''), String(message.decision || '')) };
    // Acting on a site without asking first (the side panel's second switch).
    case 'trust': {
      const site = siteOf(message.url);
      if (!site) return { ok: false };
      await trustSite(site, !!message.allowed);
      return { ok: true };
    }
    // The composer's model chip: the models Nook could think with, and picking one.
    case 'brain':
      return request({ kind: 'brain' });
    case 'setBrain':
      return request({ kind: 'setBrain', choice: String(message.choice || '').slice(0, 400) });
    // The panel's crosshair: select an element (or a spot in a PDF) on the page in front for the clipboard.
    case 'pick':
      return pick(await activeTab(message.windowId));
    default:
      return { ok: false, error: 'Unknown message.' };
  }
}

// MARK: - Selecting on a page for an agent

// Pointing at an element (or a spot in a PDF) on any page and copying where it is, so pasting it in a coding agent's
// prompt says exactly what to change: the gesture of Nook's own browser and PDF viewer, in every tab. It is the user's
// own act and what it takes only goes to their clipboard, never to Nook, so it works while Nook is paused or switched
// off for the site. Started from the side panel's crosshair or the keyboard shortcut; starting it again stops it.

/** The tabs the user is selecting in now. */
const picking = new Set();

async function pickScript(tabId, method, args = []) {
  await chrome.scripting.executeScript({ target: { tabId }, files: ['page/pick.js'] });
  const [frame] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (name, input) => globalThis.__nookPick?.[name]?.(...input),
    args: [method, args]
  });
  return frame?.result;
}

/**
 * Selects on the page in `tab` and copies it: elements on a web page, a spot in a PDF the browser shows. Resolves
 * when the user clicked (or stopped) with `{ ok, name }`, `{ ok: true, stopped: true }` or `{ ok: false, error }`, the
 * error a key of the side panel's texts.
 */
async function pick(tab) {
  if (!tab?.id) return { ok: false, error: 'pickNoPage' };
  if (picking.has(tab.id)) {
    picking.delete(tab.id);
    await pickScript(tab.id, 'cancel').catch(() => {});
    return { ok: true, stopped: true };
  }
  const url = tab.url || tab.pendingUrl || '';
  if (!mayPick(url)) return { ok: false, error: 'pickRestricted' };
  picking.add(tab.id);
  // The browser stops an idle worker after 30 s, and waiting for a click is idle: a call every 20 s keeps it awake
  // until the user clicked, so the copy does not get lost.
  const awake = setInterval(() => chrome.runtime.getPlatformInfo?.().catch(() => {}), 20_000);
  try {
    const pdf = looksLikePdf(url) || await pickScript(tab.id, 'isPdf');
    return pdf ? await pickPoint(tab, url) : await pickElements(tab, url);
  } catch {
    // The tab went to another page (or closed) while selecting: that only ends it.
    const now = await chrome.tabs.get(tab.id).catch(() => null);
    if (!now || (now.url || now.pendingUrl || '') !== url) return { ok: true, stopped: true };
    return { ok: false, error: url.toLowerCase().startsWith('file:') ? 'pickFileAccess' : 'pickRestricted' };
  } finally {
    clearInterval(awake);
    picking.delete(tab.id);
  }
}

async function pickElements(tab, url) {
  const picked = await pickScript(tab.id, 'element');
  const copied = elementsCopy(url, picked);
  if (!copied) return { ok: true, stopped: true };
  const ok = await pickScript(tab.id, 'copy', [copied.text, null, copied.name]);
  return ok ? { ok: true, name: copied.name } : { ok: false, error: 'pickNotCopied', text: copied.text };
}

async function pickPoint(tab, url) {
  const point = await pickScript(tab.id, 'point');
  const copied = pdfPointCopy(url, point);
  if (!copied) return { ok: true, stopped: true };
  // The picture shows the PDF as the window does; a tab no longer in front gives no picture, only the text.
  const [front] = await chrome.tabs.query({ active: true, windowId: tab.windowId });
  const image = front?.id === tab.id ? await pdfPicture(tab.windowId, point).catch(() => null) : null;
  const ok = await pickScript(tab.id, 'copy', [copied.text, image, copied.name]);
  return ok ? { ok: true, name: copied.name } : { ok: false, error: 'pickNotCopied', text: copied.text };
}

/** The iris Nook marks what you selected with (PdfPointCapture.markColor). */
const PICK_IRIS = '#7c6cf0';

/** A PNG (as a data URL) of the window around the spot, the spot marked with a crosshair in a ring. */
async function pdfPicture(windowId, point) {
  const shot = await chrome.tabs.captureVisibleTab(windowId, { format: 'png' });
  const bitmap = await createImageBitmap(await (await fetch(shot)).blob());
  const crop = pdfCrop(point, bitmap.width, bitmap.height);
  const canvas = new OffscreenCanvas(crop.width, crop.height);
  const context = canvas.getContext('2d');
  context.drawImage(bitmap, crop.left, crop.top, crop.width, crop.height, 0, 0, crop.width, crop.height);
  const radius = 9 * crop.scale, arm = 16 * crop.scale;
  for (const [color, width] of [['rgba(255,255,255,.9)', 4], [PICK_IRIS, 1.75]]) {
    context.strokeStyle = color;
    context.lineWidth = width * crop.scale;
    context.beginPath();
    context.arc(crop.spot.x, crop.spot.y, radius, 0, Math.PI * 2);
    context.moveTo(crop.spot.x - arm, crop.spot.y);
    context.lineTo(crop.spot.x + arm, crop.spot.y);
    context.moveTo(crop.spot.x, crop.spot.y - arm);
    context.lineTo(crop.spot.x, crop.spot.y + arm);
    context.stroke();
  }
  const png = new Uint8Array(await (await canvas.convertToBlob({ type: 'image/png' })).arrayBuffer());
  let binary = '';
  for (let start = 0; start < png.length; start += 0x8000) binary += String.fromCharCode(...png.subarray(start, start + 0x8000));
  return 'data:image/png;base64,' + btoa(binary);
}

chrome.tabs.onRemoved?.addListener((tabId) => picking.delete(tabId));

// The keyboard shortcut (Alt+Shift+E unless the user set another in the browser's shortcuts): the same as the crosshair.
chrome.commands?.onCommand?.addListener((command, tab) => {
  if (command !== 'pick') return;
  (tab?.id ? Promise.resolve(tab) : activeTab(null)).then(pick).catch(() => {});
});

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
  if (area === 'local' && (changes.paused || changes.blocked || changes.trusted)) cachedSettings = null;
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

