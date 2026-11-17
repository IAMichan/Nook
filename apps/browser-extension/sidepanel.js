// The side panel: whether Nook is connected, whether Nook may work on the site in front, a pause for this whole
// browser, a chat with Nook about the page, and what Nook did here lately. The conversation and the composer are Nook's
// shared ones (packages/web-ui): the answer as Nook's own window draws it (where Nook looked, its plan, Markdown) and
// the model chip to choose the model Nook thinks with. Questions go to Nook on the Mac and are
// answered by the same assistant as in its main window; anything with a side effect still waits for approval there.
// It wears Nook's look: the theme, accent and density chosen in Nook's Settings › Appearance.
import {
  cleanLook, isAnswering, isBlocked, isRestricted, lookIsDark, lookVariables, siteOf, watchRenewalDue
} from './lib/core.js';
import { mountComposer, mountTranscript, questionsAsked } from './ui/composer.js';

const t = (key, ...subs) => chrome.i18n.getMessage(key, subs) || key;
const $ = (id) => document.getElementById(id);

let status = { nook: 'connecting' };
let options = { paused: false, blocked: [] };
let page = null;
let conversation = null;
let messages = [];
let pollTimer = null;
let windowId = null;
// What Nook last sent of the conversation, and whether Nook pushes its changes (Nook 2 and later) or the panel asks.
let revision = null;
let live = false;
let lastUpdate = 0;
// When the panel last asked Nook to follow its conversation (`watchRenewalDue`).
let lastAsked = 0;

/** Reads the conversation and asks Nook to keep following it for this panel. */
function readAndFollow(id) {
  lastAsked = Date.now();
  return send({ type: 'chat', conversation: id, watch: true }).catch(() => null);
}
// Bumped by "New chat": a reply or poll that started before belongs to the old conversation and is dropped.
let chatEpoch = 0;
let look = null;
const systemDark = matchMedia('(prefers-color-scheme: dark)');

function send(message) {
  return chrome.runtime.sendMessage(message);
}

/** Like send, but never throws: a worker that is gone answers like a refusal. */
async function trySend(message) {
  try {
    return await send(message);
  } catch (error) {
    return { ok: false, error: String(error?.message || error) };
  }
}

// MARK: - Texts

for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = t(element.dataset.i18n);
for (const element of document.querySelectorAll('[data-i18n-placeholder]')) element.placeholder = t(element.dataset.i18nPlaceholder);
$('new-chat').title = t('newChat');
$('new-chat').setAttribute('aria-label', t('newChat'));

// MARK: - Composer

// Nook's shared composer (packages/web-ui), the same as in the Tauri app: Return sends, Up brings back an earlier
// question, and pictures can be pasted, dropped or picked. Its row holds the model chip, as in Nook's own composer.
// sidepanel.js keeps it up to date in `renderComposer`.
const composer = mountComposer($('composer'), {
  onsend: (text, images) => ask(text, images),
  onstop: () => stopAnswer(),
  onbrain: () => loadBrain(),
  onchoosebrain: (id) => chooseBrain(id)
});
const transcript = mountTranscript($('transcript'));

$('new-chat').addEventListener('click', () => newChat());

// A suggestion puts its question in the field, so it can be sent as it is or changed first.
for (const button of document.querySelectorAll('[data-suggest]')) {
  button.textContent = t(button.dataset.suggest);
  button.addEventListener('click', () => composer.fill(t(button.dataset.suggest)));
}

// MARK: - The model

// The model chip: the model Nook thinks with and every one it could use, as the chip in Nook's own composer. A Nook
// that does not know `brain` yet leaves the chip out.
let brain = null;

function applyBrain(reply) {
  if (!reply?.ok || !Array.isArray(reply.choices)) return;
  brain = { label: String(reply.label || ''), group: String(reply.group || ''), choices: reply.choices };
  renderComposer();
}

async function loadBrain() {
  if (status.nook !== 'connected') return;
  applyBrain(await trySend({ type: 'brain' }));
}

async function chooseBrain(id) {
  const reply = await trySend({ type: 'setBrain', choice: id });
  if (reply?.ok) applyBrain(reply);
  else await loadBrain();
}

// MARK: - Nook's look

/** Draws the panel in the theme Nook shows (or Nook's own until it said which), in dark or light as Nook is set. */
function applyLook() {
  const root = document.documentElement;
  const dark = lookIsDark(look, systemDark.matches);
  for (const property of [...root.style]) {
    if (property.startsWith('--')) root.style.removeProperty(property);
  }
  if (!look) {
    delete root.dataset.theme;
    return;
  }
  root.dataset.theme = dark ? 'dark' : 'light';
  for (const [name, value] of Object.entries(lookVariables(look, dark))) root.style.setProperty(name, value);
}

/** Asks Nook for its look again: when the panel opens or comes back into view, and now and then while it shows. */
function refreshLook() {
  if (document.visibilityState !== 'visible') return;
  send({ type: 'look' }).catch(() => {});
  loadBrain();
}

systemDark.addEventListener('change', applyLook);
document.addEventListener('visibilitychange', refreshLook);
addEventListener('focus', refreshLook);
setInterval(refreshLook, 15_000);

// MARK: - Status, site and pause

function renderStatus() {
  const pill = $('status');
  const states = {
    connected: ['ok', t('statusConnected')],
    connecting: ['wait', t('statusConnecting')],
    offline: ['bad', t('statusOffline')],
    missing: ['bad', t('statusMissing')]
  };
  const [tone, label] = states[status.nook] || states.connecting;
  pill.className = 'pill ' + tone;
  pill.textContent = label;
  $('setup').hidden = status.nook !== 'missing';
  $('setup-detail').textContent = status.nook === 'missing' ? t('setupDetail', chrome.runtime.id) : '';
  if (status.nook === 'connected' && !brain) loadBrain();
  renderComposer();
}

function renderSite() {
  const url = page?.url || '';
  const site = siteOf(url);
  const restricted = !url || isRestricted(url);
  const allowed = !restricted && !isBlocked(url, options.blocked);
  $('site-name').textContent = site || page?.title || t('siteNone');
  $('site-note').textContent = restricted ? t('siteRestricted') : allowed ? t('siteAllowed') : t('siteBlocked');
  $('site-mark').className = 'site-mark' + (options.paused ? ' paused' : allowed ? '' : ' off');
  const toggle = $('site-switch');
  toggle.checked = allowed;
  toggle.disabled = restricted;
  toggle.setAttribute('aria-label', t('siteSwitch', site || ''));

  // Paused: an amber line with Resume under the header; otherwise only the quiet pause button in the header says it.
  $('paused-banner').hidden = !options.paused;
  $('paused-note').textContent = t('pausedNote');
  const pause = $('pause');
  const label = options.paused ? t('resume') : t('pauseHint');
  pause.className = 'icon' + (options.paused ? ' paused' : '');
  pause.title = label;
  pause.setAttribute('aria-label', label);
}

async function loadPage() {
  const query = windowId ? { active: true, windowId } : { active: true, currentWindow: true };
  const [tab] = await chrome.tabs.query(query);
  page = tab ? { url: tab.url || tab.pendingUrl || '', title: tab.title || '' } : null;
  renderSite();
}

// The switch and the button only show the new state once it is stored (storage.onChanged renders it); when the change
// did not go through, they show the real state again, so the panel never says a site is off while Nook may still use it.
$('site-switch').addEventListener('change', async (event) => {
  const reply = await trySend({ type: 'site', url: page?.url, allowed: event.target.checked });
  if (!reply?.ok) renderSite();
});

async function togglePause() {
  const reply = await trySend({ type: 'pause', paused: !options.paused });
  if (!reply?.ok) renderSite();
}
$('pause').addEventListener('click', togglePause);
$('resume').addEventListener('click', togglePause);

// MARK: - Activity

async function renderActivity() {
  const { activity = [] } = await chrome.storage.session.get('activity');
  const list = $('activity');
  list.replaceChildren();
  if (!activity.length) {
    const empty = document.createElement('li');
    empty.textContent = t('activityEmpty');
    list.append(empty);
    return;
  }
  for (const entry of activity) {
    const item = document.createElement('li');
    if (!entry.ok) item.className = 'failed';
    const time = document.createElement('time');
    time.textContent = new Date(entry.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const text = document.createElement('span');
    text.textContent = entry.text + (entry.site ? ` · ${entry.site}` : '') + (entry.ok ? '' : ` — ${entry.error || ''}`);
    item.append(time, text);
    list.append(item);
  }
}

// MARK: - Chat

/** Takes the conversation as Nook sent it; draws it again only when it changed. */
function applyMessages(next, nextRevision) {
  lastUpdate = Date.now();
  if (!Array.isArray(next)) return;
  const same = nextRevision ? nextRevision === revision : JSON.stringify(next) === JSON.stringify(messages);
  revision = nextRevision || null;
  if (same && messages.length) return;
  messages = next;
  renderMessages();
}

function renderMessages() {
  const chat = $('chat');
  // Follow the answer while the user is at the bottom; leave them where they are when they scrolled up to read.
  const atBottom = chat.scrollHeight - chat.scrollTop - chat.clientHeight < 48;
  $('empty').hidden = messages.length > 0;
  $('new-chat').hidden = messages.length === 0;
  transcript.set(messages);
  // The transcript draws in a microtask; scroll once it did.
  if (atBottom) queueMicrotask(() => requestAnimationFrame(() => (chat.scrollTop = chat.scrollHeight)));
  renderComposer();
}

function renderComposer() {
  const busy = isAnswering(messages);
  composer.set({
    connected: status.nook === 'connected',
    busy,
    canStop: busy && !!conversation,
    history: questionsAsked(messages),
    conversation,
    brain
  });
}

function failure(reply) {
  if (reply?.error === 'nobrain') return t('noBrain');
  return reply?.error || t('errorGeneric');
}

async function ask(text, images = []) {
  const asked = chatEpoch;
  messages = [...messages, { fromNook: false, text }, { fromNook: true, text: '', streaming: true }];
  renderMessages();
  const reply = await trySend({ type: 'ask', text, images, conversation, windowId });
  if (asked !== chatEpoch) return;
  if (!reply?.ok) {
    messages = [...messages.slice(0, -1), { fromNook: true, text: failure(reply), failed: true }];
    renderMessages();
    return;
  }
  conversation = reply.conversation || conversation;
  live = !!reply.live;
  // Asking starts Nook following this conversation for the panel.
  lastAsked = Date.now();
  await chrome.storage.session.set({ conversation }).catch(() => {});
  // "New chat" while that was being stored: this answer belongs to the conversation that was left.
  if (asked !== chatEpoch) return;
  applyMessages(reply.messages, reply.revision);
  follow();
}

/**
 * Nook follows this panel's conversation for ten minutes after it last asked. While the panel is open it asks again
 * every few minutes, whether Nook is writing or not: an answer that starts later (from Nook's own window, say) still
 * comes here by itself, and a long answer never outlives the lease.
 */
setInterval(async () => {
  if (!conversation || !live || !watchRenewalDue(Date.now(), lastAsked)) return;
  const renewing = chatEpoch;
  const reply = await readAndFollow(conversation);
  if (renewing === chatEpoch && reply?.ok) applyMessages(reply.messages, reply.revision);
}, 30_000);

/**
 * While Nook answers: Nook pushes every change (see the chatUpdate listener), and this only asks now and then in case a
 * push got lost. An older Nook does not push; then the panel asks every second, as before. At most ten minutes.
 */
function follow(started = Date.now()) {
  clearTimeout(pollTimer);
  if (!conversation || Date.now() - started > 10 * 60_000) return;
  const following = chatEpoch;
  const every = live ? 2_500 : 1_000;
  pollTimer = setTimeout(async () => {
    pollTimer = null;
    if (live && Date.now() - lastUpdate < every) {
      if (isAnswering(messages)) follow(started);
      return;
    }
    const reply = await readAndFollow(conversation);
    if (following !== chatEpoch) return;
    if (reply?.ok) {
      live = !!reply.live;
      applyMessages(reply.messages, reply.revision);
    }
    if (!reply?.ok || isAnswering(messages)) follow(started);
  }, every);
}

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type !== 'chatUpdate' || !conversation || message.conversation !== conversation) return;
  live = true;
  applyMessages(message.messages, message.revision);
  if (isAnswering(messages) && !pollTimer) follow();
});

async function newChat() {
  chatEpoch += 1;
  clearTimeout(pollTimer);
  pollTimer = null;
  conversation = null;
  messages = [];
  revision = null;
  renderMessages();
  composer.focus();
  await chrome.storage.session.remove('conversation').catch(() => {});
}

async function stopAnswer() {
  if (!conversation) return;
  const stopped = chatEpoch;
  const reply = await send({ type: 'stopChat', conversation }).catch(() => null);
  if (stopped === chatEpoch && reply?.messages) applyMessages(reply.messages, reply.revision);
}

// MARK: - Start

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'session' && changes.status) {
    status = changes.status.newValue || status;
    renderStatus();
  }
  if (area === 'session' && changes.activity) renderActivity();
  if (area === 'local' && changes.look) {
    look = cleanLook(changes.look.newValue);
    applyLook();
  }
  if (area === 'local' && (changes.paused || changes.blocked)) {
    options = {
      paused: changes.paused ? !!changes.paused.newValue : options.paused,
      blocked: changes.blocked ? (Array.isArray(changes.blocked.newValue) ? changes.blocked.newValue : []) : options.blocked
    };
    renderSite();
  }
});

chrome.tabs.onActivated.addListener((info) => {
  if (!windowId || info.windowId === windowId) loadPage();
});
chrome.tabs.onUpdated.addListener((_id, change, tab) => {
  if (tab.active && (!windowId || tab.windowId === windowId) && (change.url || change.title)) loadPage();
});

(async () => {
  // The look Nook had last, at once, so the panel never flashes in other colors; then Nook's look of now.
  look = cleanLook((await chrome.storage.local.get('look')).look);
  applyLook();
  windowId = (await chrome.windows.getCurrent().catch(() => null))?.id ?? null;
  const stored = await chrome.storage.session.get(['status', 'conversation']);
  status = stored.status || status;
  conversation = stored.conversation || null;
  const local = await chrome.storage.local.get({ paused: false, blocked: [] });
  options = { paused: !!local.paused, blocked: Array.isArray(local.blocked) ? local.blocked : [] };
  renderStatus();
  await loadPage();
  await renderActivity();
  renderMessages();
  await send({ type: 'connect' }).catch(() => {});
  refreshLook();
  if (conversation) {
    const reply = await readAndFollow(conversation);
    if (reply?.ok && reply.messages) {
      live = !!reply.live;
      applyMessages(reply.messages, reply.revision);
      if (isAnswering(messages)) follow();
    } else {
      conversation = null;
      await chrome.storage.session.remove('conversation');
    }
  }
})();
