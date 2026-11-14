// The side panel: whether Nook is connected, whether Nook may work on the site in front, a pause for this whole
// browser, a chat with Nook about the page, and what Nook did here lately. Questions go to Nook on the Mac and are
// answered by the same assistant as in its main window; anything with a side effect still waits for approval there.
import { inlineTokens, isAnswering, isBlocked, isRestricted, siteOf } from './lib/core.js';

const t = (key, ...subs) => chrome.i18n.getMessage(key, subs) || key;
const $ = (id) => document.getElementById(id);

let status = { nook: 'connecting' };
let options = { paused: false, blocked: [] };
let page = null;
let conversation = null;
let messages = [];
let pollTimer = null;
let windowId = null;

function send(message) {
  return chrome.runtime.sendMessage(message);
}

// MARK: - Texts

for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = t(element.dataset.i18n);
for (const element of document.querySelectorAll('[data-i18n-placeholder]')) element.placeholder = t(element.dataset.i18nPlaceholder);

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
  renderComposer();
}

function renderSite() {
  const url = page?.url || '';
  const site = siteOf(url);
  const restricted = !url || isRestricted(url);
  const allowed = !restricted && !isBlocked(url, options.blocked);
  $('site-name').textContent = site || page?.title || t('siteNone');
  $('site-note').textContent = restricted ? t('siteRestricted') : allowed ? t('siteAllowed') : t('siteBlocked');
  const toggle = $('site-switch');
  toggle.checked = allowed;
  toggle.disabled = restricted;
  toggle.setAttribute('aria-label', t('siteSwitch', site || ''));

  $('paused-note').textContent = options.paused ? t('pausedNote') : t('activeNote');
  $('paused-note').className = 'note grow' + (options.paused ? ' wait' : '');
  const pause = $('pause');
  pause.textContent = options.paused ? t('resume') : t('pause');
  pause.className = options.paused ? 'warn' : 'quiet';
}

async function loadPage() {
  const query = windowId ? { active: true, windowId } : { active: true, currentWindow: true };
  const [tab] = await chrome.tabs.query(query);
  page = tab ? { url: tab.url || tab.pendingUrl || '', title: tab.title || '' } : null;
  renderSite();
}

$('site-switch').addEventListener('change', async (event) => {
  await send({ type: 'site', url: page?.url, allowed: event.target.checked });
});

$('pause').addEventListener('click', async () => {
  await send({ type: 'pause', paused: !options.paused });
});

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

function renderMessages() {
  const chat = $('chat');
  chat.replaceChildren();
  if (!messages.length) {
    const intro = document.createElement('p');
    intro.className = 'intro';
    intro.textContent = t('intro');
    chat.append(intro);
  }
  for (const message of messages) {
    const bubble = document.createElement('div');
    bubble.className = 'message ' + (message.fromNook ? 'nook' : 'you') + (message.failed ? ' failed' : '');
    if (message.fromNook && !message.text && message.streaming) {
      const dots = document.createElement('span');
      dots.className = 'dots';
      dots.setAttribute('aria-label', t('thinking'));
      dots.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
      bubble.append(dots);
    } else {
      for (const token of inlineTokens(message.text || '')) bubble.append(node(token));
    }
    if (message.status && message.streaming) {
      const line = document.createElement('span');
      line.className = 'status';
      line.textContent = message.status;
      bubble.append(line);
    }
    if (message.onMac) {
      const line = document.createElement('span');
      line.className = 'on-mac';
      line.textContent = t('onMacNote');
      bubble.append(line);
    }
    chat.append(bubble);
  }
  chat.scrollTop = chat.scrollHeight;
  renderComposer();
}

function node(token) {
  switch (token.type) {
    case 'code': {
      const code = document.createElement('code');
      code.textContent = token.value;
      return code;
    }
    case 'bold': {
      const strong = document.createElement('strong');
      strong.textContent = token.value;
      return strong;
    }
    case 'link': {
      const link = document.createElement('a');
      link.href = token.href;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.textContent = token.value;
      return link;
    }
    default:
      return document.createTextNode(token.value);
  }
}

function renderComposer() {
  const busy = isAnswering(messages);
  const connected = status.nook === 'connected';
  $('send').disabled = !connected || busy;
  $('input').disabled = !connected;
  $('stop').hidden = !busy || !conversation;
  $('new-chat').hidden = !messages.length;
}

function failure(reply) {
  if (reply?.error === 'nobrain') return t('noBrain');
  return reply?.error || t('errorGeneric');
}

async function ask(text) {
  messages = [...messages, { fromNook: false, text }, { fromNook: true, text: '', streaming: true }];
  renderMessages();
  let reply;
  try {
    reply = await send({ type: 'ask', text, conversation, windowId });
  } catch (error) {
    reply = { ok: false, error: String(error?.message || error) };
  }
  if (!reply?.ok) {
    messages = [...messages.slice(0, -1), { fromNook: true, text: failure(reply), failed: true }];
    renderMessages();
    return;
  }
  conversation = reply.conversation || conversation;
  await chrome.storage.session.set({ conversation });
  if (reply.messages) messages = reply.messages;
  renderMessages();
  follow();
}

/** Reads the conversation again every second while Nook answers, for at most five minutes. */
function follow(started = Date.now()) {
  clearTimeout(pollTimer);
  if (!conversation || Date.now() - started > 5 * 60_000) return;
  pollTimer = setTimeout(async () => {
    const reply = await send({ type: 'chat', conversation }).catch(() => null);
    if (reply?.ok && reply.messages) {
      messages = reply.messages;
      renderMessages();
    }
    if (!reply?.ok || isAnswering(messages)) follow(started);
  }, 1000);
}

$('composer').addEventListener('submit', (event) => {
  event.preventDefault();
  const input = $('input');
  const text = input.value.trim();
  if (!text || $('send').disabled) return;
  input.value = '';
  ask(text);
});

$('input').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    $('composer').requestSubmit();
  }
});

$('new-chat').addEventListener('click', async () => {
  clearTimeout(pollTimer);
  conversation = null;
  messages = [];
  await chrome.storage.session.remove('conversation');
  renderMessages();
  $('input').focus();
});

$('stop').addEventListener('click', async () => {
  if (!conversation) return;
  const reply = await send({ type: 'stopChat', conversation }).catch(() => null);
  if (reply?.messages) {
    messages = reply.messages;
    renderMessages();
  }
});

// MARK: - Start

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'session' && changes.status) {
    status = changes.status.newValue || status;
    renderStatus();
  }
  if (area === 'session' && changes.activity) renderActivity();
  if (area === 'local' && (changes.paused || changes.blocked)) {
    options = {
      paused: changes.paused ? !!changes.paused.newValue : options.paused,
      blocked: changes.blocked ? changes.blocked.newValue || [] : options.blocked
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
  windowId = (await chrome.windows.getCurrent().catch(() => null))?.id ?? null;
  const stored = await chrome.storage.session.get(['status', 'conversation']);
  status = stored.status || status;
  conversation = stored.conversation || null;
  options = await chrome.storage.local.get({ paused: false, blocked: [] });
  renderStatus();
  await loadPage();
  await renderActivity();
  renderMessages();
  await send({ type: 'connect' }).catch(() => {});
  if (conversation) {
    const reply = await send({ type: 'chat', conversation }).catch(() => null);
    if (reply?.ok && reply.messages) {
      messages = reply.messages;
      renderMessages();
      if (isAnswering(messages)) follow();
    } else {
      conversation = null;
      await chrome.storage.session.remove('conversation');
    }
  }
})();
