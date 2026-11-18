// The side panel: whether Nook is connected, whether Nook may work on the site in front, a pause for this whole
// browser, a chat with Nook about the page, and what Nook did here lately. The conversation and the composer are Nook's
// shared ones (packages/web-ui): the answer as Nook's own window draws it (where Nook looked, its plan, Markdown) and
// the model chip to choose the model Nook thinks with. Questions go to Nook on the Mac and are
// answered by the same assistant as in its main window; anything with a side effect still waits for approval there.
// It wears Nook's look: the theme, accent and density chosen in Nook's Settings › Appearance.
import {
  agoLabel, cleanLook, isAnswering, isBlocked, isRestricted, lookIsDark, lookVariables, matchRanges, mergeChats,
  movesUp, questionTarget, rememberChat, siteOf, stepIndex, timeLabel, watchRenewalDue, withEarlier
} from './lib/core.js';
import { mountComposer, mountTranscript, questionsAsked } from './ui/composer.js';

const t = (key, ...subs) => chrome.i18n.getMessage(key, subs) || key;
const $ = (id) => document.getElementById(id);

let status = { nook: 'connecting' };
let options = { paused: false, blocked: [] };
let page = null;
let conversation = null;
// What the panel draws: the messages it read back (`older`, oldest first) and the newest ones Nook keeps sending
// (`latest`), together `messages`. `earlier` is how many come before what it draws.
let messages = [];
let latest = [];
let older = [];
let earlier = 0;
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
const locale = chrome.i18n.getUILanguage?.() || undefined;
const transcript = mountTranscript($('transcript'), {
  // A question back in the composer, to ask it again or change it first.
  onreuse: (text) => composer.fill(text),
  timeOf: (at) => timeLabel(at, Date.now(), locale)
});

$('new-chat').addEventListener('click', () => newChat());
for (const [id, key] of [
  ['pick', 'pickTitle'], ['find-open', 'findTitle'], ['outline-open', 'questionsTitle'], ['history-open', 'chatsTitle'], ['find-prev', 'findPrevious'],
  ['find-next', 'findNext'], ['find-close', 'findClose'], ['question-prev', 'questionPrevious'], ['question-next', 'questionNext']
]) {
  $(id).title = t(key);
  $(id).setAttribute('aria-label', t(key));
}

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

// MARK: - Selecting on the page

// The crosshair: select an element (or a spot in a PDF) on the page in front; the service worker copies where it is
// for a coding agent's prompt. Pressing it again, or Escape here, stops. The same as the keyboard shortcut.
let picking = false;
let pickTimer = null;

function pickNote(text, warn = false, stay = false) {
  const note = $('pick-note');
  clearTimeout(pickTimer);
  note.textContent = text;
  note.className = 'banner pick-note' + (warn ? ' warn' : '');
  note.hidden = !text;
  if (text && !stay) pickTimer = setTimeout(() => (note.hidden = true), 4000);
}

async function pick() {
  const starting = !picking;
  picking = starting;
  $('pick').classList.toggle('active', starting);
  if (starting) pickNote(t('pickStarted'), false, true);
  const reply = await trySend({ type: 'pick', windowId });
  // Pressing again only stops the first one, whose reply ends it here.
  if (!starting) return;
  picking = false;
  $('pick').classList.remove('active');
  if (reply?.ok && reply.name) pickNote(t('pickCopied', reply.name));
  else if (reply?.ok) pickNote('');
  else pickNote(t(/^pick\w+$/.test(reply?.error || '') ? reply.error : 'pickFailed'), true);
}
$('pick').addEventListener('click', pick);

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

/** Takes the conversation as Nook sent it (its newest messages); draws it again only when it changed. */
function applyMessages(next, nextRevision, nextEarlier) {
  lastUpdate = Date.now();
  if (!Array.isArray(next)) return;
  const same = nextRevision ? nextRevision === revision : JSON.stringify(next) === JSON.stringify(latest);
  revision = nextRevision || null;
  if (same && messages.length) return;
  setLatest(next, nextEarlier);
  renderMessages();
}

/**
 * The newest messages, with what the panel read back before them. Once the user read back, a message that leaves
 * Nook's newest window stays with the earlier ones, so nothing drops out of the middle.
 */
function setLatest(next, nextEarlier) {
  if (older.length) {
    const ids = new Set(next.map((message) => message?.id).filter(Boolean));
    older = messages.filter((message) => message?.id && !ids.has(message.id));
  } else {
    earlier = Number.isFinite(nextEarlier) ? nextEarlier : 0;
  }
  latest = next;
  messages = withEarlier(older, latest);
}

function renderMessages() {
  const changed = transcriptText !== null && JSON.stringify(messages) !== transcriptText;
  transcriptText = JSON.stringify(messages);
  $('empty').hidden = messages.length > 0;
  $('new-chat').hidden = messages.length === 0;
  $('find-open').hidden = messages.length === 0;
  $('outline-open').hidden = !messages.some((message) => !message.fromNook);
  const button = $('earlier');
  button.hidden = !(earlier > 0 && conversation);
  button.textContent = t('earlierMessages', String(earlier));
  transcript.set(messages);
  // Follow the answer while following (the transcript draws in a microtask; the resize observer catches what grows
  // later); otherwise leave the user where they read, and say Nook wrote more.
  if (following) queueMicrotask(() => requestAnimationFrame(stickToEnd));
  else if (changed) unseen = true;
  queueMicrotask(() => requestAnimationFrame(() => {
    renderNavigation();
    if (findOpen) runFind({ keepPlace: true });
  }));
  renderComposer();
}
let transcriptText = null;

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
  // Asking brings the panel to the end and follows the answer again.
  following = true;
  unseen = false;
  latest = [...latest, { fromNook: false, text }, { fromNook: true, text: '', streaming: true }];
  messages = withEarlier(older, latest);
  renderMessages();
  const reply = await trySend({ type: 'ask', text, images, conversation, windowId });
  if (asked !== chatEpoch) return;
  if (!reply?.ok) {
    latest = [...latest.slice(0, -1), { fromNook: true, text: failure(reply), failed: true }];
    messages = withEarlier(older, latest);
    renderMessages();
    return;
  }
  const started = !conversation || conversation !== reply.conversation;
  conversation = reply.conversation || conversation;
  rememberThisChat(started ? text : '');
  live = !!reply.live;
  // Asking starts Nook following this conversation for the panel.
  lastAsked = Date.now();
  await chrome.storage.session.set({ conversation }).catch(() => {});
  // "New chat" while that was being stored: this answer belongs to the conversation that was left.
  if (asked !== chatEpoch) return;
  applyMessages(reply.messages, reply.revision, reply.earlier);
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
  if (renewing === chatEpoch && reply?.ok) applyMessages(reply.messages, reply.revision, reply.earlier);
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
      applyMessages(reply.messages, reply.revision, reply.earlier);
    }
    if (!reply?.ok || isAnswering(messages)) follow(started);
  }, every);
}

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type !== 'chatUpdate' || !conversation || message.conversation !== conversation) return;
  live = true;
  applyMessages(message.messages, message.revision, message.earlier);
  if (isAnswering(messages) && !pollTimer) follow();
});

/** Leaves the conversation on screen: what it drew, where it was, and whatever was still on its way. */
function resetConversation(id) {
  chatEpoch += 1;
  clearTimeout(pollTimer);
  pollTimer = null;
  conversation = id;
  messages = [];
  latest = [];
  older = [];
  earlier = 0;
  revision = null;
  following = true;
  unseen = false;
  transcriptText = null;
  closeFind();
}

async function newChat() {
  resetConversation(null);
  renderMessages();
  composer.focus();
  await chrome.storage.session.remove('conversation').catch(() => {});
}

/** Goes back to an earlier chat from the panel's list, and follows it from now on. */
async function openChat(id) {
  if (!id || id === conversation) return;
  resetConversation(id);
  renderMessages();
  const opening = chatEpoch;
  await chrome.storage.session.set({ conversation: id }).catch(() => {});
  const reply = await readAndFollow(id);
  if (opening !== chatEpoch) return;
  if (!reply?.ok) {
    // Nook no longer has it: off the list, and a new chat instead.
    await forgetChat(id);
    await newChat();
    return;
  }
  live = !!reply.live;
  applyMessages(reply.messages, reply.revision, reply.earlier);
  if (isAnswering(messages)) follow();
  composer.focus();
}

/** Reads further back: the messages before the oldest one the panel has, without moving what the user reads. */
async function loadEarlier() {
  const oldest = messages.find((message) => message?.id);
  if (!conversation || !oldest) return;
  const button = $('earlier');
  button.disabled = true;
  const reading = chatEpoch;
  const reply = await trySend({ type: 'chat', conversation, before: oldest.id });
  button.disabled = false;
  if (reading !== chatEpoch || !reply?.ok || !reply.older || !Array.isArray(reply.messages)) return;
  const before = chat.scrollHeight - chat.scrollTop;
  older = withEarlier(reply.messages, older.length ? older : messages.filter((message) => !latest.includes(message)));
  earlier = Number.isFinite(reply.earlier) ? reply.earlier : 0;
  messages = withEarlier(older, latest);
  following = false;
  renderMessages();
  queueMicrotask(() => requestAnimationFrame(() => (chat.scrollTop = chat.scrollHeight - before)));
}
$('earlier').addEventListener('click', loadEarlier);

async function stopAnswer() {
  if (!conversation) return;
  const stopped = chatEpoch;
  const reply = await send({ type: 'stopChat', conversation }).catch(() => null);
  if (stopped === chatEpoch && reply?.messages) applyMessages(reply.messages, reply.revision);
}

// MARK: - Following and moving through the conversation

const chat = $('chat');
// Whether the panel keeps the newest answer in view. Only the user's own input up stops it (a wheel or key up, or
// dragging the scroll bar up); coming back to the end starts it again. A streamed answer makes "at the end" flicker,
// so the position alone never stops it (as t3code's timeline does).
let following = true;
// Nook wrote more while the user read further up: the "to the newest" button says so.
let unseen = false;
let dragging = false;
let lastTop = 0;

function nearEnd() {
  return chat.scrollHeight - chat.scrollTop - chat.clientHeight < 24;
}

function stickToEnd() {
  if (following) chat.scrollTop = chat.scrollHeight;
}

function release() {
  if (!following) return;
  following = false;
  renderNavigation();
}

function toLatest() {
  following = true;
  unseen = false;
  chat.scrollTo({ top: chat.scrollHeight, behavior: smooth() });
  renderNavigation();
}

function smooth() {
  return matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
}

chat.addEventListener('wheel', (event) => { if (movesUp(event)) release(); }, { passive: true });
chat.addEventListener('keydown', (event) => { if (movesUp(event)) release(); });
chat.addEventListener('pointerdown', (event) => { if (event.target === chat) dragging = true; });
addEventListener('pointerup', () => (dragging = false));
chat.addEventListener('scroll', () => {
  if (dragging && chat.scrollTop < lastTop) release();
  lastTop = chat.scrollTop;
  if (!following && nearEnd() && !jumping) {
    following = true;
    unseen = false;
  }
  renderNavigation();
}, { passive: true });
// What grows after it was drawn (sources opening, a code block, a font) keeps the end in view while following.
new ResizeObserver(() => stickToEnd()).observe($('transcript'));
$('to-latest').addEventListener('click', toLatest);

/** Your questions in the conversation, top to bottom. */
function questionRows() {
  return [...$('transcript').querySelectorAll('[data-role="you"]')];
}

/** Where a row starts in the scrolled content. */
function topOf(element) {
  return element.getBoundingClientRect().top - chat.getBoundingClientRect().top + chat.scrollTop;
}

// How far below the top of the view a row lands that the panel jumps to.
const JUMP_MARGIN = 12;

// While the panel scrolls to a place it chose, reaching the end does not count as the user coming back to follow.
let jumping = false;
let jumpTimer = null;

/** Brings a row into view near the top, and lights it up for a moment. */
function jumpTo(element, { flash = true } = {}) {
  if (!element) return;
  following = false;
  jumping = true;
  clearTimeout(jumpTimer);
  jumpTimer = setTimeout(() => (jumping = false), 600);
  chat.scrollTo({ top: Math.max(0, topOf(element) - JUMP_MARGIN), behavior: smooth() });
  if (flash) {
    element.classList.add('flash');
    setTimeout(() => element.classList.remove('flash'), 1_200);
  }
  renderNavigation();
}

/** To the question above (-1) or below (+1) the view's top; past the last one, back to the newest answer. */
function stepQuestion(direction) {
  const rows = questionRows();
  // From where a jumped-to question sits, so the next step never lands on the same one.
  const index = questionTarget(rows.map(topOf), chat.scrollTop + JUMP_MARGIN, direction);
  if (index >= 0) jumpTo(rows[index]);
  else if (direction > 0) toLatest();
}
$('question-prev').addEventListener('click', () => stepQuestion(-1));
$('question-next').addEventListener('click', () => stepQuestion(1));

/** The floating controls: "to the newest" once the user left the end, question by question once there is more than one. */
function renderNavigation() {
  const away = messages.length > 0 && !following && !nearEnd();
  const button = $('to-latest');
  button.hidden = !away;
  button.classList.toggle('fresh', away && unseen);
  chat.parentElement.classList.toggle('away', away);
  $('to-latest-label').textContent = unseen ? t('newerMessages') : t('toLatest');
  const scrolls = chat.scrollHeight > chat.clientHeight + 8;
  $('question-nav').hidden = !(scrolls && questionRows().length > 1);
}

// MARK: - The questions in this conversation

function renderOutline() {
  const list = $('outline-list');
  list.replaceChildren();
  const rows = questionRows();
  const tops = rows.map(topOf);
  // The question being read: the last one that starts above the middle of the view.
  const middle = chat.scrollTop + chat.clientHeight / 2;
  let current = -1;
  tops.forEach((top, index) => { if (top <= middle) current = index; });
  if (earlier > 0) {
    const item = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'quiet-item';
    button.textContent = t('earlierMessages', String(earlier));
    button.addEventListener('click', () => {
      $('outline').hidePopover();
      loadEarlier();
    });
    item.append(button);
    list.append(item);
  }
  const questions = messages.filter((message) => !message.fromNook);
  rows.forEach((row, index) => {
    const message = questions[index];
    const item = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    if (index === current) button.className = 'current';
    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = (message?.text || row.textContent || '').trim().split('\n')[0];
    button.append(label);
    const when = timeLabel(message?.at, Date.now(), locale);
    if (when) {
      const time = document.createElement('span');
      time.className = 'when';
      time.textContent = when;
      button.append(time);
    }
    button.addEventListener('click', () => {
      $('outline').hidePopover();
      jumpTo(row);
    });
    item.append(button);
    list.append(item);
  });
}
$('outline').addEventListener('toggle', (event) => {
  if (event.newState === 'open') {
    renderOutline();
    $('outline-list').querySelector('.current, button')?.focus();
  }
});

// MARK: - Earlier chats

/** The chats started in this panel, newest first, as the panel remembers them (`rememberChat`). */
async function storedChats() {
  const { chats = [] } = await chrome.storage.local.get('chats').catch(() => ({}));
  return Array.isArray(chats) ? chats : [];
}

async function rememberThisChat(question) {
  if (!conversation) return;
  const entry = { id: conversation, updated: Date.now() };
  if (question) entry.title = question.trim().split('\n')[0];
  await chrome.storage.local.set({ chats: rememberChat(await storedChats(), entry) }).catch(() => {});
}

async function forgetChat(id) {
  const chats = (await storedChats()).filter((entry) => entry.id !== id);
  await chrome.storage.local.set({ chats }).catch(() => {});
}

async function renderHistory() {
  const list = $('history-list');
  let chats = await storedChats();
  drawHistory(chats);
  if (!chats.length || status.nook !== 'connected') return;
  // Nook's own titles and times, and only the chats it still has.
  const reply = await trySend({ type: 'chats', conversations: chats.map((entry) => entry.id) });
  if (!reply?.ok || !Array.isArray(reply.chats)) return;
  chats = mergeChats(chats, reply.chats);
  await chrome.storage.local.set({ chats }).catch(() => {});
  if (list.isConnected) drawHistory(chats);
}

function drawHistory(chats) {
  const list = $('history-list');
  list.replaceChildren();
  const add = (button, separated = false) => {
    const item = document.createElement('li');
    if (separated) item.className = 'separated';
    item.append(button);
    list.append(item);
  };
  if (!chats.length) {
    const item = document.createElement('li');
    item.className = 'empty-item';
    item.textContent = t('chatsEmpty');
    list.append(item);
  }
  for (const entry of chats) {
    const button = document.createElement('button');
    button.type = 'button';
    if (entry.id === conversation) button.className = 'current';
    if (entry.busy) {
      const dot = document.createElement('span');
      dot.className = 'busy';
      dot.title = t('chatBusy');
      button.append(dot);
    }
    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = entry.title || t('newChat');
    const when = document.createElement('span');
    when.className = 'when';
    when.textContent = agoLabel(entry.updated, Date.now(), locale);
    button.append(label, when);
    button.addEventListener('click', () => {
      $('history').hidePopover();
      openChat(entry.id);
    });
    add(button);
  }
  const fresh = document.createElement('button');
  fresh.type = 'button';
  fresh.className = 'quiet-item';
  fresh.textContent = t('newChat');
  fresh.addEventListener('click', () => {
    $('history').hidePopover();
    newChat();
  });
  add(fresh, chats.length > 0);
}
$('history').addEventListener('toggle', (event) => {
  if (event.newState === 'open') renderHistory().then(() => $('history-list').querySelector('.current, button')?.focus());
});

/** Up and down in an open menu, as in a menu on the Mac. */
for (const menu of [$('outline'), $('history')]) {
  menu.addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    const buttons = [...menu.querySelectorAll('button')];
    const index = stepIndex(buttons.length, buttons.indexOf(document.activeElement), event.key === 'ArrowDown' ? 1 : -1);
    buttons[index]?.focus();
    event.preventDefault();
  });
}

// MARK: - Find in this conversation

let findOpen = false;
let findRanges = [];
let findCurrent = -1;
const highlights = globalThis.CSS?.highlights;

function openFind() {
  if (!messages.length) return;
  findOpen = true;
  $('find-bar').hidden = false;
  const field = $('find-field');
  // A selection in the conversation is what the user wants to find.
  const selected = String(getSelection() || '').trim();
  if (selected && selected.length < 100 && !selected.includes('\n')) field.value = selected;
  field.focus();
  field.select();
  runFind();
}

function closeFind() {
  if (!findOpen) return;
  findOpen = false;
  $('find-bar').hidden = true;
  findRanges = [];
  findCurrent = -1;
  highlights?.delete('nook-find');
  highlights?.delete('nook-find-current');
}

/** The text of the conversation as the user reads it: not the buttons, times and icons around it. */
function readableTextNodes() {
  const walker = document.createTreeWalker($('transcript'), NodeFilter.SHOW_TEXT, {
    acceptNode: (node) => (node.parentElement?.closest('button, svg, .actions, .meta, .dots')
      ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT)
  });
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  return nodes;
}

/** Marks every match; the current one stays where it was (`keepPlace`, while Nook writes) or moves to the first. */
function runFind({ keepPlace = false } = {}) {
  const query = $('find-field').value;
  findRanges = [];
  for (const node of readableTextNodes()) {
    for (const [start, end] of matchRanges(node.data, query)) {
      const range = document.createRange();
      range.setStart(node, start);
      range.setEnd(node, end);
      findRanges.push(range);
    }
  }
  if (!keepPlace) {
    // The first match from where the user reads, not from the top.
    const viewTop = chat.getBoundingClientRect().top;
    findCurrent = findRanges.findIndex((range) => range.getBoundingClientRect().top >= viewTop);
    if (findCurrent < 0) findCurrent = findRanges.length ? 0 : -1;
  } else if (findCurrent >= findRanges.length) {
    findCurrent = findRanges.length - 1;
  }
  paintFind(!keepPlace);
}

function paintFind(reveal) {
  const query = $('find-field').value.trim();
  const count = $('find-count');
  count.textContent = !query ? '' : findRanges.length ? t('findCount', String(findCurrent + 1), String(findRanges.length)) : t('findNone');
  count.classList.toggle('none', !!query && !findRanges.length);
  $('find-prev').disabled = findRanges.length < 2;
  $('find-next').disabled = findRanges.length < 2;
  if (!highlights || typeof Highlight === 'undefined') return;
  highlights.set('nook-find', new Highlight(...findRanges));
  const current = findRanges[findCurrent];
  if (current) highlights.set('nook-find-current', new Highlight(current));
  else highlights.delete('nook-find-current');
  if (reveal && current) {
    following = false;
    const box = current.getBoundingClientRect();
    const view = chat.getBoundingClientRect();
    if (box.top < view.top + 8 || box.bottom > view.bottom - 8) {
      jumping = true;
      clearTimeout(jumpTimer);
      jumpTimer = setTimeout(() => (jumping = false), 600);
      chat.scrollTo({ top: chat.scrollTop + box.top - view.top - chat.clientHeight / 3, behavior: smooth() });
    }
    renderNavigation();
  }
}

function stepFind(step) {
  findCurrent = stepIndex(findRanges.length, findCurrent, step);
  paintFind(true);
}

$('find-open').addEventListener('click', openFind);
$('find-close').addEventListener('click', () => {
  closeFind();
  composer.focus();
});
$('find-prev').addEventListener('click', () => stepFind(-1));
$('find-next').addEventListener('click', () => stepFind(1));
$('find-field').addEventListener('input', () => runFind());
$('find-field').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    stepFind(event.shiftKey ? -1 : 1);
    event.preventDefault();
  } else if (event.key === 'Escape') {
    closeFind();
    composer.focus();
    event.preventDefault();
    event.stopPropagation();
  }
});

// MARK: - Keys

// ⌘F / Ctrl+F finds in the conversation (the browser's own find does not reach a side panel); ⌥↑ and ⌥↓ go question
// by question, past the last one to the newest answer (not inside a draft of more lines); ⌘↓ / Ctrl+End in the
// conversation also goes to the newest answer.
addEventListener('keydown', (event) => {
  const command = event.metaKey || event.ctrlKey;
  if (picking && event.key === 'Escape') {
    event.preventDefault();
    pick();
    return;
  }
  if (command && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'f') {
    if (!messages.length) return;
    event.preventDefault();
    openFind();
  } else if (event.altKey && !command && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) {
    // In a draft of more than one line, ⌥↑ and ⌥↓ keep moving the cursor, as everywhere on the Mac.
    const field = event.target?.closest?.('textarea, input, [contenteditable="true"]');
    if (!messages.length || String(field?.value ?? field?.textContent ?? '').includes('\n')) return;
    event.preventDefault();
    stepQuestion(event.key === 'ArrowUp' ? -1 : 1);
  } else if (event.target === chat && ((event.metaKey && event.key === 'ArrowDown') || (event.ctrlKey && event.key === 'End'))) {
    event.preventDefault();
    toLatest();
  }
});

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
  // Chats from before this panel could list them: the one it shows goes on the list.
  if (conversation && !(await storedChats()).some((entry) => entry.id === conversation)) await rememberThisChat('');
  if (conversation) {
    const reply = await readAndFollow(conversation);
    if (reply?.ok && reply.messages) {
      live = !!reply.live;
      applyMessages(reply.messages, reply.revision, reply.earlier);
      if (isAnswering(messages)) follow();
    } else {
      conversation = null;
      await chrome.storage.session.remove('conversation');
    }
  }
})();
