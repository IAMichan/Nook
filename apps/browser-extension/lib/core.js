// Pure logic of Nook's browser extension: no `chrome.*`, no DOM, so Node's test runner checks it (`npm test`).
// The service worker (background.js) and the side panel import it.

/** The native messaging host Nook installs (Settings › Editor & browser › Nook in your browser). */
export const HOST_NAME = 'app.nook.browser';

/** Version of the messages between the extension and Nook; Nook refuses a newer major version than it knows. */
export const PROTOCOL_VERSION = 1;

/** The tab group that holds the tabs Nook opened, so the user sees at a glance where Nook works. */
export const GROUP_TITLE = 'Nook';

/** Methods that only look; everything else changes the page and is refused while Nook is paused. */
export const READ_METHODS = new Set(['tabs', 'read', 'find', 'screenshot', 'wait', 'console']);
export const ACT_METHODS = new Set(['open', 'click', 'type', 'scroll', 'key', 'close']);
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
  if (command.method === 'type' && typeof params.value !== 'string') return 'type needs value: the text to enter.';
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
