// Pure logic of Nook's browser extension: no `chrome.*`, no DOM, so Node's test runner checks it (`npm test`).
// The service worker (background.js) and the side panel import it.

/** The native messaging host Nook installs (Settings › Editor & browser › Nook in your browser). */
export const HOST_NAME = 'app.nook.browser';

/** Version of the messages between the extension and Nook; Nook refuses a newer major version than it knows. */
export const PROTOCOL_VERSION = 1;

/** The tab group that holds the tabs Nook opened, so the user sees at a glance where Nook works. */
export const GROUP_TITLE = 'Nook';

/** Methods that only look; everything else changes the page and is refused while Nook is paused. */
export const READ_METHODS = new Set(['tabs', 'read', 'find', 'screenshot', 'wait', 'console', 'form']);
export const ACT_METHODS = new Set(['open', 'click', 'type', 'scroll', 'key', 'close', 'fill']);
export const METHODS = new Set([...READ_METHODS, ...ACT_METHODS]);

/** Pages no extension may script (the browser's own pages and its web store), by URL prefix or host. */
const RESTRICTED_PREFIXES = [
  'chrome:', 'chrome-extension:', 'chrome-search:', 'chrome-untrusted:', 'devtools:', 'edge:', 'brave:', 'vivaldi:', 'opera:',
  'arc:', 'about:', 'view-source:', 'file:', 'data:', 'javascript:', 'blob:'
];
const RESTRICTED_HOSTS = ['chromewebstore.google.com', 'microsoftedge.microsoft.com'];

/** The site of an address as the user knows it ("github.com"), or '' for one without a host. */
export function siteOf(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host.startsWith('www.') ? host.slice(4) : host;
  } catch {
    return '';
  }
}

/** True for a page the browser never lets an extension read or touch. */
export function isRestricted(url) {
  const text = String(url || '').trim().toLowerCase();
  if (!text) return true;
  if (RESTRICTED_PREFIXES.some((prefix) => text.startsWith(prefix))) return true;
  const site = siteOf(text);
  if (RESTRICTED_HOSTS.includes(site)) return true;
  return site === 'chrome.google.com' && new URL(text).pathname.startsWith('/webstore');
}

/** True when the user switched Nook off for this site in the side panel (the site itself or a parent domain). */
export function isBlocked(url, blocked) {
  const site = siteOf(url);
  if (!site) return false;
  return (blocked || []).some((entry) => site === entry || site.endsWith('.' + entry));
}

// MARK: - Asking before a step of a task from the side panel

/**
 * Words on a button (or a form's send button) for a step that cannot be undone: paying, ordering, sending, deleting,
 * booking, signing up, publishing, confirming. Such a step always waits for the user's yes in the side panel, also on a
 * site they let Nook act on without asking. In Nook's five languages; stems, so "bestellen" and "Bestellung" count.
 */
const NO_RETURN_WORDS = [
  // Whole words only: short ones that also start other words ("Postcode", "Bookmarks", "Placeholder").
  'pay', 'buy', 'order', 'send', 'submit', 'delete', 'remove', 'book', 'reserve', 'transfer', 'donate', 'publish', 'post',
  'confirm', 'cancel', 'place order', 'sign up', 'check out', 'checkout', 'purchase', 'subscribe', 'unsubscribe',
  'koop', 'boek', 'stuur', 'wis', 'plaats', 'kauf', 'kaufen', 'buchen', 'spenden', 'zahlen', 'senden', 'pagar', 'donar'
];
const NO_RETURN_STEMS = [
  // Dutch
  'betaal', 'betalen', 'kopen', 'bestel', 'afrekenen', 'verstuur', 'versturen', 'verzend', 'verwijder', 'reserveer',
  'overmaken', 'doneer', 'abonneer', 'opzeg', 'zeg op', 'publiceer', 'bevestig', 'annuleer', 'aanmelden', 'inschrijven',
  // German
  'bezahl', 'bestell', 'zur kasse', 'absenden', 'versenden', 'lösch', 'entfern', 'reservier', 'überweis', 'abonnier',
  'kündig', 'veröffentlich', 'bestätig', 'storn', 'registrier',
  // French
  'payer', 'paiement', 'acheter', 'commander', 'envoyer', 'supprimer', 'réserver', 'virement', 'faire un don',
  's\'abonner', 'désabonner', 'publier', 'confirmer', 'valider', 'annuler', 's\'inscrire',
  // Spanish
  'comprar', 'pedido', 'enviar', 'eliminar', 'borrar', 'reservar', 'transferir', 'suscrib', 'publicar', 'confirmar',
  'cancelar', 'registrar'
];
const escaped = (words) => words.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
/**
 * Words on a button (or a form's send button) for a step that cannot be undone: paying, ordering, sending, deleting,
 * booking, signing up, publishing, confirming. Such a step always waits for the user's yes in the side panel, also on a
 * site they let Nook act on without asking. In Nook's five languages; stems where a word has many forms.
 */
const POINT_OF_NO_RETURN = new RegExp(
  `(?:^|[^\\p{L}])(?:(?:${escaped(NO_RETURN_WORDS)})(?![\\p{L}])|(?:${escaped(NO_RETURN_STEMS)}))`, 'iu');

/** True when a step's words say it cannot be undone (`POINT_OF_NO_RETURN`). */
export function pointOfNoReturn(words) {
  return typeof words === 'string' && POINT_OF_NO_RETURN.test(words);
}

/**
 * Whether a step of a task from the side panel must wait for the user's yes there. Not when they let Nook act on the
 * step's site without asking (`trusted`, subdomains included) and nothing about the step is final; always when it is
 * (`ask.submits` from Nook: typing that sends a form, or the words on what it clicks).
 */
export function mustAsk({ url, trusted, submits = false, words = '' }) {
  if (submits || pointOfNoReturn(words)) return { ask: true, final: true };
  return { ask: !siteOf(url) || !isBlocked(url, trusted), final: false };
}

/**
 * A step Nook only asked about (`ask.trusted`) that must wait for the user: it did not run, and Nook asks in its own
 * approval card. `site` names the step's site for "Always on <site>" there, never offered for a `final` step.
 */
export function approvalNeeded(site, final) {
  return {
    ok: false,
    error: 'This step waits for the user\'s approval in Nook; it did not run.',
    approval: { site: typeof site === 'string' ? site.slice(0, 120) : '', final: !!final }
  };
}

/** A step waiting for the user, as the side panel's card shows it: only plain, clipped text. */
export function approvalCard(id, ask, site, final) {
  if (typeof id !== 'string' || !id) return null;
  return {
    id: id.slice(0, 64),
    summary: clip(typeof ask?.summary === 'string' ? ask.summary.replace(/\s+/g, ' ').trim() : '', 240),
    site: typeof site === 'string' ? site.slice(0, 120) : '',
    final: !!final,
    at: Date.now()
  };
}

/** What the side panel may answer for a step: once, always on this site (never for a final step), or no. */
export function approvalDecision(decision, card) {
  if (decision === 'once' || decision === 'deny') return decision;
  if (decision === 'site' && card && !card.final && card.site) return 'site';
  return 'deny';
}

/**
 * An address the user or Nook typed, made openable: "example.com" becomes https, plain http only for this Mac.
 * Returns null for anything else (a script, a file, the browser's own pages).
 */
export function normalizeURL(input) {
  let text = String(input || '').trim();
  if (!text) return null;
  // "localhost:3000" has no scheme; "javascript:…" and "https://…" do.
  const hasScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(text) || /^(javascript|data|file|about|blob|vbscript|mailto|chrome|view-source):/i.test(text);
  if (!hasScheme) {
    const local = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/|$)/i.test(text);
    text = (local ? 'http://' : 'https://') + text;
  }
  let url;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  if (url.protocol === 'https:') return url.href;
  // Plain http only for a server on this Mac, as in Nook's own browser: anywhere else it is readable on the way.
  if (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) return url.href;
  return null;
}

/** How a target element is given: exactly one of ref, selector and text. Returns an error text or null. */
export function targetError(params) {
  const given = ['ref', 'selector', 'text'].filter((key) => typeof params?.[key] === 'string' && params[key].trim() !== '');
  if (given.length === 0) return 'Say which element: ref (from chrome_find), selector or text.';
  if (given.length > 1) return 'Give only one of ref, selector and text.';
  if (given[0] === 'ref' && !/^e\d{1,5}$/.test(params.ref.trim())) return 'A ref looks like "e7"; take it from chrome_find.';
  return null;
}

/** The element target of a command, trimmed. */
export function targetOf(params) {
  const target = {};
  for (const key of ['ref', 'selector', 'text']) {
    if (typeof params?.[key] === 'string' && params[key].trim() !== '') target[key] = params[key].trim();
  }
  return target;
}

/**
 * Checks a command from Nook before anything runs. Returns an error text, or null when it may run.
 * `state`: { paused, blocked: [site], url: the address of the tab it targets (when known) }.
 */
export function commandError(command, state) {
  if (!command || typeof command !== 'object') return 'Not a command.';
  if (!METHODS.has(command.method)) return `Nook's extension does not know "${command.method}".`;
  if (state?.paused) {
    return 'The user paused Nook in this browser (the side panel of Nook\'s extension). Do not try again; tell the user what you wanted to do there. They can resume it in the side panel.';
  }
  const params = command.params || {};
  if (['click', 'type'].includes(command.method)) {
    const error = targetError(params);
    if (error) return error;
  }
  // scroll and key take a target too, but only optionally: when one is given it must be a real one, or a blank text
  // would match the first element on the page and Nook would act on something it never meant.
  if (['scroll', 'key'].includes(command.method) && ['ref', 'selector', 'text'].some((key) => params[key] !== undefined && params[key] !== null)) {
    const error = targetError(params);
    if (error) return error;
  }
  if (command.method === 'type' && typeof params.value !== 'string') return 'type needs value: the text to enter.';
  if (command.method === 'fill') {
    const values = params.values;
    if (!Array.isArray(values) || !values.length) return 'fill needs values: [{ ref, value }] from form.';
    if (values.some((item) => !item || typeof item.ref !== 'string' || typeof item.value !== 'string')) {
      return 'Each of fill\'s values needs ref (from form) and value (text).';
    }
  }
  if (command.method === 'key' && (typeof params.key !== 'string' || !params.key.trim())) return 'key needs key, such as "Enter", "Escape" or "Tab".';
  if (command.method === 'open') {
    const where = String(params.url || '').trim().toLowerCase();
    if (!['back', 'forward', 'reload'].includes(where) && !normalizeURL(params.url)) {
      return 'url must be a web address (https://…, or http://localhost for a server on this Mac), or back, forward or reload.';
    }
    const target = normalizeURL(params.url);
    if (target && isBlocked(target, state?.blocked)) return blockedText(target);
  }
  if (command.method === 'wait' && !params.text && !params.selector) return 'wait needs text or selector.';
  if (state?.url !== undefined && command.method !== 'tabs' && command.method !== 'open' && command.method !== 'close') {
    if (isRestricted(state.url)) return restrictedText(state.url);
    if (isBlocked(state.url, state.blocked)) return blockedText(state.url);
  }
  return null;
}

export function restrictedText(url) {
  return `The browser does not let extensions read or use ${url || 'this page'} (its own pages and its web store). Open a normal web page, or ask the user.`;
}

export function blockedText(url) {
  return `The user switched Nook off for ${siteOf(url) || url} in the side panel of Nook's extension. Do not try another way; tell the user what you wanted to do there.`;
}

/** The tabs as text for Nook: one line per tab, the active tab of each window marked, Nook's own group named. */
export function describeTabs(tabs, { focusedWindow, nookGroup, current } = {}) {
  if (!tabs.length) return 'No tabs are open.';
  const windows = [];
  for (const tab of tabs) {
    if (!windows.includes(tab.windowId)) windows.push(tab.windowId);
  }
  const lines = [];
  windows.forEach((windowId, index) => {
    const label = `Window ${index + 1}` + (windowId === focusedWindow ? ' (in front)' : '');
    lines.push(label + ':');
    for (const tab of tabs.filter((t) => t.windowId === windowId)) {
      const marks = [];
      if (tab.active) marks.push('active');
      if (tab.id === current) marks.push('Nook works here');
      if (nookGroup !== undefined && tab.groupId === nookGroup) marks.push('Nook group');
      const title = clip(tab.title || '(no title)', 100);
      lines.push(`- tab ${tab.id}${marks.length ? ' [' + marks.join(', ') + ']' : ''}: ${title} | ${tab.url || ''}`);
    }
  });
  return lines.join('\n') + '\n\nPass tab: <number> to work in a tab other than the one Nook works in.';
}

/** One line of the side panel's activity list, from a finished command. */
export function activityLine(command, outcome) {
  const params = command.params || {};
  const what = targetOf(params);
  const element = what.text ? `"${clip(what.text, 40)}"` : what.ref ? 'an element' : what.selector ? 'an element' : '';
  switch (command.method) {
    case 'open': return { icon: 'open', text: `Opened ${siteOf(normalizeURL(params.url) || '') || params.url}`, ...outcome };
    case 'click': return { icon: 'click', text: `Clicked ${outcome.element || element}`.trim(), ...outcome };
    case 'type': return { icon: 'type', text: `Typed into ${outcome.element || element}`.trim(), ...outcome };
    case 'fill': return { icon: 'type', text: `Double Tap filled in ${outcome.element || 'a form'}`, ...outcome };
    case 'form': return { icon: 'read', text: 'Double Tap looked at the form', ...outcome };
    case 'key': return { icon: 'key', text: `Pressed ${params.key}`, ...outcome };
    case 'scroll': return { icon: 'scroll', text: 'Scrolled', ...outcome };
    case 'close': return { icon: 'close', text: 'Closed a tab', ...outcome };
    case 'read': return { icon: 'read', text: 'Read the page', ...outcome };
    case 'find': return { icon: 'read', text: 'Looked at the page', ...outcome };
    case 'screenshot': return { icon: 'read', text: 'Took a screenshot', ...outcome };
    case 'console': return { icon: 'read', text: 'Read the console', ...outcome };
    case 'wait': return { icon: 'read', text: 'Waited for the page', ...outcome };
    default: return { icon: 'read', text: 'Looked at your tabs', ...outcome };
  }
}

/** At most `limit` characters, with an ellipsis when cut. */
export function clip(text, limit) {
  const value = String(text ?? '');
  return value.length > limit ? value.slice(0, Math.max(0, limit - 1)) + '…' : value;
}

/** The browser's name from its user agent data ("Google Chrome", "Brave", "Microsoft Edge", "Arc"…). */
export function browserName(brands, userAgent = '') {
  const names = (brands || []).map((b) => b.brand).filter((b) => b && !/not.?a.?brand/i.test(b) && b !== 'Chromium');
  if (names.length) return names[0];
  if (/Edg\//.test(userAgent)) return 'Microsoft Edge';
  return /Chrome\//.test(userAgent) ? 'Chromium' : 'Browser';
}

/** Waits between reconnect tries to Nook: quick at first, then at most every 30 seconds. */
export function reconnectDelay(attempt) {
  return Math.min(30_000, 1_000 * 2 ** Math.max(0, Math.min(attempt, 5)));
}

/**
 * Nook's answer split into plain pieces for the side panel: `code`, **bold**, and web links, everything else text.
 * The panel builds DOM nodes from these with textContent, so an answer can never inject markup.
 */
export function inlineTokens(text) {
  const tokens = [];
  const pattern = /`([^`\n]+)`|\*\*([^*\n]+)\*\*|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])/g;
  let last = 0;
  for (const match of String(text ?? '').matchAll(pattern)) {
    if (match.index > last) tokens.push({ type: 'text', value: text.slice(last, match.index) });
    if (match[1] !== undefined) tokens.push({ type: 'code', value: match[1] });
    else if (match[2] !== undefined) tokens.push({ type: 'bold', value: match[2] });
    else if (match[3] !== undefined) tokens.push({ type: 'link', value: match[3], href: match[4] });
    else tokens.push({ type: 'link', value: match[5], href: match[5] });
    last = match.index + match[0].length;
  }
  if (last < String(text ?? '').length) tokens.push({ type: 'text', value: text.slice(last) });
  return tokens;
}

/** True while Nook is still on it: the last message is the user's, or Nook's answer still streams. */
export function isAnswering(messages) {
  if (!messages?.length) return false;
  const last = messages[messages.length - 1];
  return !last.fromNook || !!last.streaming;
}

/** Pictures that go with one question at most, and the most one may weigh (base64 characters, about 12 MB). */
export const MAX_QUESTION_IMAGES = 10;
export const MAX_IMAGE_BASE64 = 16_000_000;
const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

/**
 * The pictures from the side panel's composer as Nook takes them: `{ mediaType, base64 }` of a kind Nook can read,
 * at most `MAX_QUESTION_IMAGES`, none larger than `MAX_IMAGE_BASE64`. Anything else is dropped, not sent.
 */
export function questionImages(raw) {
  if (!Array.isArray(raw)) return [];
  const images = [];
  for (const image of raw) {
    if (images.length >= MAX_QUESTION_IMAGES) break;
    const mediaType = String(image?.mediaType || '').toLowerCase();
    const base64 = image?.base64;
    if (!IMAGE_TYPES.has(mediaType) || typeof base64 !== 'string' || !base64 || base64.length > MAX_IMAGE_BASE64) continue;
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) continue;
    images.push({ mediaType, base64 });
  }
  return images;
}

/**
 * Runs async tasks one after another, so a read-modify-write of the extension's storage (the activity list, the tab
 * groups per window) never loses a concurrent change. A failed task does not stop the ones after it.
 */
export function serial() {
  let tail = Promise.resolve();
  return (task) => {
    const result = tail.then(task);
    tail = result.catch(() => {});
    return result;
  };
}

/**
 * Whether a runtime message may reach the service worker's handler. The side panel (an extension page) may send every
 * kind; a page (the presence strip's Stop button runs in the page's isolated world, and a page's renderer is never
 * fully trusted) may only pause Nook, never resume it, ask Nook something, or switch a site back on.
 */
export function panelMessageAllowed(message, sender, extensionId) {
  if (!message || typeof message !== 'object' || !sender || sender.id !== extensionId) return false;
  const fromExtensionPage = !sender.tab && typeof sender.url === 'string' && sender.url.startsWith(`chrome-extension://${extensionId}/`);
  if (fromExtensionPage) return true;
  return message.type === 'pause' && message.paused === true;
}

/**
 * The console entries collected in the page's main world, as text for Nook. That world belongs to the page, so the
 * list may be anything the page put there: only real entries count, each as one clipped line.
 */
export function consoleText(entries, limit = 200) {
  const list = Array.isArray(entries) ? entries.slice(-limit) : [];
  const lines = [];
  for (const entry of list) {
    if (!entry || typeof entry !== 'object') continue;
    const level = entry.level === 'warn' ? 'warn' : 'error';
    lines.push(`${level}: ${clip(typeof entry.text === 'string' ? entry.text : String(entry.text ?? ''), 2000)}`);
  }
  return lines.length ? lines.join('\n') : null;
}

// MARK: - Nook's look

/**
 * The colors of Nook's theme the side panel draws, as its CSS variables (`--canvas`, `--text-strong`…). Nook sends them
 * for dark and for light (`BrowserExtensionLook` on the Mac): the chosen theme, the colors set one by one, the accent.
 */
export const LOOK_TOKENS = [
  'canvas', 'well', 'surface', 'field', 'graphite', 'smoke', 'row-hover', 'row-selected', 'bubble', 'composer',
  'composer-tray', 'menu', 'line', 'line2', 'border', 'separator', 'field-stroke', 'paper', 'text-strong',
  'text-secondary', 'text-muted', 'text-tertiary', 'blue', 'mint', 'amber', 'coral', 'violet', 'accent', 'on-accent',
  'accent-hover', 'added', 'removed'
];

const HEX = /^#[0-9a-f]{6}$/i;
const clamp = (value, low, high, fallback) => (Number.isFinite(value) ? Math.min(high, Math.max(low, value)) : fallback);

/**
 * Nook's look as Nook sent it, checked: only known tokens, each a `#RRGGBB` (so a value can never become other CSS),
 * the appearance one of system, light and dark, and the density's scales within reason. Null when it is not a look.
 */
export function cleanLook(raw) {
  if (!raw || typeof raw !== 'object' || raw.ok === false) return null;
  const side = (colors) => {
    const out = {};
    for (const token of LOOK_TOKENS) {
      const value = colors && typeof colors === 'object' ? colors[token] : undefined;
      if (typeof value === 'string' && HEX.test(value)) out[token] = value.toLowerCase();
    }
    return out;
  };
  const dark = side(raw.dark);
  const light = side(raw.light);
  if (!Object.keys(dark).length && !Object.keys(light).length) return null;
  return {
    appearance: ['system', 'light', 'dark'].includes(raw.appearance) ? raw.appearance : 'system',
    textScale: clamp(raw.textScale, 0.85, 1.15, 1),
    spacingScale: clamp(raw.spacingScale, 0.6, 1.4, 1),
    dark,
    light
  };
}

/** Whether the panel shows dark: what Nook is set to, or the system's when Nook follows it (or no look is known yet). */
export function lookIsDark(look, systemIsDark) {
  if (look?.appearance === 'dark') return true;
  if (look?.appearance === 'light') return false;
  return !!systemIsDark;
}

/** The CSS variables for one appearance: `{ '--canvas': '#000000', …, '--text-scale': '1' }`. */
export function lookVariables(look, dark) {
  if (!look) return {};
  const vars = {};
  for (const [token, value] of Object.entries(dark ? look.dark : look.light)) vars['--' + token] = value;
  vars['--text-scale'] = String(look.textScale);
  vars['--space-scale'] = String(look.spacingScale);
  return vars;
}

// MARK: - Following the side panel's conversation

/** How long Nook follows the side panel's conversation after the panel last asked (BrowserExtensionService.watchFor). */
export const WATCH_LEASE = 10 * 60_000;
/** How often the open panel asks again, well within the lease. */
export const WATCH_RENEW = 4 * 60_000;

/**
 * Whether the open panel should ask Nook again to keep following its conversation: when its last ask is WATCH_RENEW
 * old, whether or not Nook is writing. During a long answer the pushes keep coming and the panel itself asks nothing
 * else, so the lease would otherwise run out mid-answer.
 */
export function watchRenewalDue(now, lastAsked) {
  return now - lastAsked >= WATCH_RENEW;
}


// MARK: - Moving through the side panel's conversation

/** The most earlier chats the panel remembers and asks Nook about (BrowserExtensionPanel.maxChats). */
export const MAX_CHATS = 30;
const CONVERSATION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The conversation ids a `chats` request may carry: real ids only, each once, at most MAX_CHATS. */
export function chatIds(raw) {
  const ids = Array.isArray(raw) ? raw.filter((id) => typeof id === 'string' && CONVERSATION_ID.test(id)) : [];
  return [...new Set(ids)].slice(0, MAX_CHATS);
}

/**
 * The panel's earlier chats with this one in front (newest first, each once), as it remembers them in
 * `chrome.storage.local`: the id, a title to show while Nook does not answer, and when it was last used.
 */
export function rememberChat(list, chat) {
  if (!chat?.id) return Array.isArray(list) ? list : [];
  const before = (Array.isArray(list) ? list : []).find((entry) => entry?.id === chat.id) || {};
  const entry = { ...before, ...chat, title: String(chat.title || before.title || '').slice(0, 120) };
  return [entry, ...(Array.isArray(list) ? list : []).filter((other) => other?.id && other.id !== chat.id)].slice(0, MAX_CHATS);
}

/**
 * The remembered chats as Nook knows them now: Nook's title, time and whether it is still answering, newest first. A
 * chat Nook no longer has is dropped. Without an answer from Nook (an older Nook, or offline) the list stays as it was.
 */
export function mergeChats(list, fromNook) {
  const remembered = Array.isArray(list) ? list : [];
  if (!Array.isArray(fromNook)) return remembered;
  const byId = new Map(fromNook.filter((chat) => chat?.id).map((chat) => [chat.id, chat]));
  return remembered
    .filter((entry) => byId.has(entry.id))
    .map((entry) => {
      const chat = byId.get(entry.id);
      return {
        ...entry,
        title: String(chat.title || entry.title || '').slice(0, 120),
        updated: Number(chat.updated) || entry.updated || 0,
        busy: !!chat.busy
      };
    })
    .sort((a, b) => (b.updated || 0) - (a.updated || 0));
}

/**
 * The conversation the panel draws: the earlier messages it read back (`older`, oldest first) and the newest window
 * Nook keeps sending. A message in both counts once, as the newest window has it.
 */
export function withEarlier(older, newest) {
  const latest = Array.isArray(newest) ? newest : [];
  if (!Array.isArray(older) || !older.length) return latest;
  const ids = new Set(latest.map((message) => message?.id).filter(Boolean));
  return [...older.filter((message) => !message?.id || !ids.has(message.id)), ...latest];
}

/** Where `query` occurs in `text`, ignoring case, as `[start, end]` pairs in `text`'s own indices. */
export function matchRanges(text, query) {
  const needle = String(query ?? '').trim();
  const haystack = String(text ?? '');
  if (!needle || !haystack) return [];
  const pattern = new RegExp(needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
  const ranges = [];
  for (const match of haystack.matchAll(pattern)) {
    ranges.push([match.index, match.index + match[0].length]);
    if (ranges.length >= 2_000) break;
  }
  return ranges;
}

/** The next of `count` items from `current`, one `step` (+1 or -1) on, going round; -1 when there are none. */
export function stepIndex(count, current, step) {
  if (!count) return -1;
  if (current < 0 || current >= count) return step < 0 ? count - 1 : 0;
  return (current + step + count) % count;
}

/**
 * The question to jump to from the view's top: the one above it (`direction` -1) or below it (+1), by the questions'
 * tops in the scrolled content (ascending). -1 when there is none that way. A few pixels of slack, so a question that
 * sits at the top already counts as "here", not as the next one up.
 */
export function questionTarget(tops, viewTop, direction) {
  const slack = 8;
  if (direction < 0) {
    for (let index = tops.length - 1; index >= 0; index -= 1) if (tops[index] < viewTop - slack) return index;
    return -1;
  }
  return tops.findIndex((top) => top > viewTop + slack);
}

/** A message's time as the panel shows it: "14:05" today, "12 Nov 14:05" earlier. Empty without a time. */
export function timeLabel(at, now = Date.now(), locale = undefined) {
  if (!Number.isFinite(at) || at <= 0) return '';
  const date = new Date(at);
  const time = date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === new Date(now).toDateString()) return time;
  const day = date.toLocaleDateString(locale, { day: 'numeric', month: 'short' });
  return `${day} ${time}`;
}

/** How long ago, as the earlier chats list says it ("5 min. ago", "yesterday"). */
export function agoLabel(at, now = Date.now(), locale = undefined) {
  if (!Number.isFinite(at) || at <= 0) return '';
  const seconds = Math.round((at - now) / 1000);
  const format = new Intl.RelativeTimeFormat(locale, { numeric: 'auto', style: 'short' });
  const units = [['day', 86_400], ['hour', 3_600], ['minute', 60]];
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit);
  }
  return format.format(0, 'minute');
}

/**
 * Whether an input means the user moves up to read, which stops the panel following Nook's answer. Only the user's
 * own input up does; the position never does by itself (a streamed answer makes "at the end" flicker for a frame).
 */
export function movesUp(event) {
  if (!event) return false;
  if (event.type === 'wheel') return event.deltaY < 0;
  if (event.type === 'keydown') return ['ArrowUp', 'PageUp', 'Home'].includes(event.key);
  return false;
}

// MARK: - Selecting on a page for an agent (page/pick.js)

/** As much visible text and markup as a selected element brings along (BrowserPickScript in Nook). */
export const PICK_TEXT_LIMIT = 1500;
export const PICK_HTML_LIMIT = 6000;
/** At most this many elements go along in one copy. */
export const PICK_MAX = 20;

/**
 * Whether the user may select on this page: every page the browser lets an extension script, and also local files
 * (the browser asks for their own switch, "Allow access to file URLs"). Nothing selected goes to Nook; it only goes to
 * the user's clipboard, so a site switched off for Nook still allows it.
 */
export function mayPick(url) {
  const text = String(url || '').trim().toLowerCase();
  if (text.startsWith('file:')) return true;
  return !isRestricted(text);
}

/** True for an address that is a PDF by its name; the page itself says so too (page/pick.js `isPdf`). */
export function looksLikePdf(url) {
  try {
    return new URL(url).pathname.toLowerCase().endsWith('.pdf');
  } catch {
    return false;
  }
}

function longestBacktickRun(text) {
  let longest = 0;
  for (const run of String(text).match(/`+/g) || []) longest = Math.max(longest, run.length);
  return longest;
}

/** One element as the page script took it, with every field a clipped string, or null when it is not one. */
export function pickedElement(raw) {
  if (!raw || typeof raw !== 'object' || typeof raw.selector !== 'string' || !raw.selector.trim()) return null;
  const text = (value, limit) => (typeof value === 'string' ? value.slice(0, limit) : '');
  return {
    selector: text(raw.selector, 600).trim(),
    label: text(raw.label, 200).trim(),
    text: text(raw.text, PICK_TEXT_LIMIT).trim(),
    html: text(raw.html, PICK_HTML_LIMIT + 40).trim()
  };
}

/** The name of a selected element: what its badge showed (`h2.mkt-title`), else its selector. */
export function elementName(element) {
  return element.label || element.selector;
}

/**
 * What an agent reads about one selected element, the same as Nook's own browser gives it (PickedElement.snippet):
 * where it is, its markup as code, and its text. Everything but the address comes from the page, so it is data, never
 * an order; the fence is longer than any run of backticks in the markup, so the page can never close it.
 */
export function elementSnippet(url, element) {
  const lines = [`Element \`${elementName(element)}\` on ${url}`, `Selector: \`${element.selector}\``];
  const markup = element.html.trim();
  if (markup) {
    const fence = '`'.repeat(Math.max(3, longestBacktickRun(markup) + 1));
    lines.push('', fence + 'html', markup, fence);
  }
  const words = element.text.trim();
  if (words && words !== markup) lines.push('', 'Text:', words);
  return lines.join('\n');
}

/**
 * Several selected elements as one text, with the name the toast shows (`h2.title +2`); null when there are none.
 * The same as PickedElement.combined in Nook.
 */
export function elementsCopy(url, raw) {
  const elements = (Array.isArray(raw) ? raw : []).map(pickedElement).filter(Boolean).slice(0, PICK_MAX);
  if (!elements.length) return null;
  const first = elementName(elements[0]);
  return {
    name: elements.length === 1 ? first : `${first} +${elements.length - 1}`,
    text: elements.map((element) => elementSnippet(url, element)).join('\n\n---\n\n')
  };
}

/** The file name in a PDF's address (`report.pdf`), else the address itself. */
export function pdfName(url) {
  try {
    const last = new URL(url).pathname.split('/').filter(Boolean).pop() || '';
    return decodeURIComponent(last) || url;
  } catch {
    return String(url || '');
  }
}

/**
 * A spot clicked in a PDF the browser shows. Its viewer keeps the page number and zoom to itself, so the spot is
 * measured in the window, and the picture copied along (the area around it, the spot marked with a crosshair, as
 * PdfPointCapture draws it in Nook) shows where it is. Null when the spot is not one.
 */
export function pdfPointCopy(url, raw) {
  const number = (value) => (Number.isFinite(value) ? value : NaN);
  const x = number(raw?.x), y = number(raw?.y), width = number(raw?.width), height = number(raw?.height);
  if (![x, y, width, height].every(Number.isFinite) || width <= 0 || height <= 0) return null;
  const left = Math.round(Math.min(Math.max(x / width, 0), 1) * 100);
  const top = Math.round(Math.min(Math.max(y / height, 0), 1) * 100);
  const file = pdfName(url);
  const lines = [
    `Point in PDF \`${file}\` (${url})`,
    `Where: ${left}% from the left and ${top}% from the top of the browser's PDF viewer (${Math.round(width)} × ${Math.round(height)} px); the viewer does not tell the page number or zoom.`,
    'A picture of the area around it was copied along with this text: the point is the marked crosshair in its middle.'
  ];
  return { name: `${file} · ${left}%, ${top}%`, text: lines.join('\n') };
}

/**
 * The part of a picture of the window (`imageWidth` × `imageHeight` pixels, for a window `point.width` CSS pixels
 * wide) to cut out around the spot, and where the spot is in it: `size` CSS pixels, less where the window is smaller,
 * moved inward at the window's edges.
 */
export function pdfCrop(point, imageWidth, imageHeight, size = { width: 560, height: 360 }) {
  const scale = point.width > 0 ? imageWidth / point.width : 1;
  const width = Math.round(Math.min(size.width * scale, imageWidth));
  const height = Math.round(Math.min(size.height * scale, imageHeight));
  const x = point.x * scale, y = point.y * scale;
  const left = Math.round(Math.min(Math.max(0, x - width / 2), imageWidth - width));
  const top = Math.round(Math.min(Math.max(0, y - height / 2), imageHeight - height));
  return { left, top, width, height, scale, spot: { x: x - left, y: y - top } };
}
