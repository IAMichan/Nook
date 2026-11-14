// The extension's pure logic (lib/core.js): which pages Nook may touch, how commands are checked, and how the side
// panel shows things. Run with `npm test` (Node's own test runner, no dependencies).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  activityLine, browserName, cleanLook, commandError, describeTabs, inlineTokens, isAnswering, isBlocked, isRestricted,
  lookIsDark, lookVariables, normalizeURL, reconnectDelay, siteOf, targetError
} from '../lib/core.js';

test('a site is its host without www', () => {
  assert.equal(siteOf('https://www.github.com/IAMichan/nook'), 'github.com');
  assert.equal(siteOf('http://localhost:3000/'), 'localhost');
  assert.equal(siteOf('not a url'), '');
});

test('the browser keeps its own pages and its store to itself', () => {
  for (const url of ['chrome://settings', 'edge://extensions', 'brave://wallet', 'about:blank', 'chrome-extension://abc/x.html',
    'https://chromewebstore.google.com/detail/x', 'https://chrome.google.com/webstore/category', 'file:///etc/passwd', '']) {
    assert.equal(isRestricted(url), true, url);
  }
  for (const url of ['https://example.com', 'http://localhost:5173', 'https://chrome.google.com/search']) {
    assert.equal(isRestricted(url), false, url);
  }
});

test('a site switched off covers its subdomains, not look-alikes', () => {
  assert.equal(isBlocked('https://mail.google.com/u/0', ['google.com']), true);
  assert.equal(isBlocked('https://google.com', ['google.com']), true);
  assert.equal(isBlocked('https://notgoogle.com', ['google.com']), false);
  assert.equal(isBlocked('https://example.com', []), false);
});

test('addresses become https, http only for this Mac, and nothing else opens', () => {
  assert.equal(normalizeURL('example.com/a'), 'https://example.com/a');
  assert.equal(normalizeURL('localhost:3000'), 'http://localhost:3000/');
  assert.equal(normalizeURL('http://example.com'), null, 'plain http only for this Mac');
  assert.equal(normalizeURL('http://127.0.0.1:8080/x'), 'http://127.0.0.1:8080/x');
  assert.equal(normalizeURL('javascript:alert(1)'), null);
  assert.equal(normalizeURL('file:///etc/hosts'), null);
  assert.equal(normalizeURL('chrome://settings'), null);
  assert.equal(normalizeURL(''), null);
});

test('an element is named exactly once', () => {
  assert.match(targetError({}), /Say which element/);
  assert.match(targetError({ ref: 'e1', text: 'Send' }), /only one/);
  assert.match(targetError({ ref: 'x"]' }), /looks like/);
  assert.equal(targetError({ ref: 'e12' }), null);
  assert.equal(targetError({ text: 'Send' }), null);
});

test('commands are checked before anything runs', () => {
  const open = { paused: false, blocked: ['bank.example'] };
  assert.equal(commandError({ method: 'read', params: {} }, { ...open, url: 'https://news.example/' }), null);
  assert.match(commandError({ method: 'eval', params: {} }, open), /does not know/);
  assert.match(commandError({ method: 'read', params: {} }, { ...open, paused: true, url: 'https://x.example' }), /paused/);
  assert.match(commandError({ method: 'click', params: { ref: 'e1' } }, { ...open, url: 'https://www.bank.example/pay' }), /switched Nook off/);
  assert.match(commandError({ method: 'read', params: {} }, { ...open, url: 'chrome://settings' }), /does not let extensions/);
  assert.match(commandError({ method: 'open', params: { url: 'javascript:void(0)' } }, open), /web address/);
  assert.match(commandError({ method: 'open', params: { url: 'https://bank.example' } }, open), /switched Nook off/);
  assert.equal(commandError({ method: 'open', params: { url: 'back' } }, { ...open, url: 'https://x.example' }), null);
  assert.match(commandError({ method: 'type', params: { ref: 'e1' } }, open), /needs value/);
  assert.match(commandError({ method: 'key', params: {} }, open), /needs key/);
  assert.match(commandError({ method: 'wait', params: {} }, open), /needs text or selector/);
  assert.equal(commandError({ method: 'tabs', params: {} }, { ...open, url: 'chrome://newtab' }), null, 'listing tabs never needs a page');
});

test('tabs read per window, with the active tab and Nook\'s own marked', () => {
  const text = describeTabs([
    { id: 1, windowId: 10, active: true, title: 'Inbox', url: 'https://mail.example', groupId: -1 },
    { id: 2, windowId: 10, active: false, title: 'Docs', url: 'https://docs.example', groupId: 5 },
    { id: 3, windowId: 11, active: true, title: '', url: 'https://x.example', groupId: -1 }
  ], { focusedWindow: 10, nookGroup: 5, current: 2 });
  assert.match(text, /Window 1 \(in front\):/);
  assert.match(text, /- tab 1 \[active\]: Inbox \| https:\/\/mail.example/);
  assert.match(text, /- tab 2 \[Nook works here, Nook group\]: Docs/);
  assert.match(text, /Window 2:\n- tab 3 \[active\]: \(no title\)/);
  assert.equal(describeTabs([]), 'No tabs are open.');
});

test('the activity list says what Nook did in a few words', () => {
  assert.equal(activityLine({ method: 'click', params: { ref: 'e1' } }, { ok: true, element: 'button "Send"' }).text, 'Clicked button "Send"');
  assert.equal(activityLine({ method: 'open', params: { url: 'example.com' } }, { ok: true }).text, 'Opened example.com');
  assert.equal(activityLine({ method: 'key', params: { key: 'Enter' } }, { ok: false, error: 'x' }).ok, false);
});

test('answers become plain pieces: never markup', () => {
  assert.deepEqual(inlineTokens('Run `npm test` on **main**, see https://example.com/a.'), [
    { type: 'text', value: 'Run ' }, { type: 'code', value: 'npm test' }, { type: 'text', value: ' on ' },
    { type: 'bold', value: 'main' }, { type: 'text', value: ', see ' },
    { type: 'link', value: 'https://example.com/a', href: 'https://example.com/a' }, { type: 'text', value: '.' }
  ]);
  assert.deepEqual(inlineTokens('[Nook](https://nook.app) <img src=x>'), [
    { type: 'link', value: 'Nook', href: 'https://nook.app' }, { type: 'text', value: ' <img src=x>' }
  ]);
  assert.deepEqual(inlineTokens('[x](javascript:alert(1))'), [{ type: 'text', value: '[x](javascript:alert(1))' }]);
});

test('Nook is answering while the last message is the user\'s or still streams', () => {
  assert.equal(isAnswering([]), false);
  assert.equal(isAnswering([{ fromNook: false }]), true);
  assert.equal(isAnswering([{ fromNook: false }, { fromNook: true, streaming: true }]), true);
  assert.equal(isAnswering([{ fromNook: false }, { fromNook: true, streaming: false }]), false);
});

test('the browser is named from its brands', () => {
  assert.equal(browserName([{ brand: 'Not.A/Brand' }, { brand: 'Chromium' }, { brand: 'Google Chrome' }]), 'Google Chrome');
  assert.equal(browserName([{ brand: 'Chromium' }, { brand: 'Brave' }]), 'Brave');
  assert.equal(browserName([], 'Mozilla/5.0 Chrome/120 Edg/120'), 'Microsoft Edge');
});

test('reconnecting backs off to at most half a minute', () => {
  assert.deepEqual([0, 1, 2, 5, 9].map(reconnectDelay), [1000, 2000, 4000, 30000, 30000]);
});

test('Nook\'s look is taken only as colors, never as other CSS', () => {
  const look = cleanLook({
    ok: true, appearance: 'light', textScale: 0.93, spacingScale: 9,
    dark: { canvas: '#000000', paper: '#F5F5F5', accent: 'red; background: url(x)', unknown: '#123456' },
    light: { canvas: '#FCFCFC', 'text-strong': '#27272a' }
  });
  assert.equal(look.appearance, 'light');
  assert.equal(look.textScale, 0.93);
  assert.equal(look.spacingScale, 1.4);
  assert.deepEqual(look.dark, { canvas: '#000000', paper: '#f5f5f5' });
  assert.deepEqual(look.light, { canvas: '#fcfcfc', 'text-strong': '#27272a' });
  assert.equal(cleanLook({ ok: false, error: 'Nook does not know "look".' }), null);
  assert.equal(cleanLook({ dark: { canvas: 'black' } }), null);
  assert.equal(cleanLook({ appearance: 'neon', dark: { canvas: '#000000' } }).appearance, 'system');
});

test('the panel shows the appearance Nook is set to, or the system\'s', () => {
  const look = (appearance) => ({ appearance, dark: {}, light: {} });
  assert.equal(lookIsDark(look('dark'), false), true);
  assert.equal(lookIsDark(look('light'), true), false);
  assert.equal(lookIsDark(look('system'), true), true);
  assert.equal(lookIsDark(null, false), false);
});

test('a look becomes the CSS variables of the appearance that shows', () => {
  const look = cleanLook({ appearance: 'system', dark: { canvas: '#000000' }, light: { canvas: '#ffffff' } });
  assert.deepEqual(lookVariables(look, true), { '--canvas': '#000000', '--text-scale': '1', '--space-scale': '1' });
  assert.equal(lookVariables(look, false)['--canvas'], '#ffffff');
  assert.deepEqual(lookVariables(null, true), {});
});
