// Selecting on a page for a coding agent (lib/core.js): what is copied for an element, for several, and for a spot in
// a PDF, and which pages allow it. Run with `npm test` (Node's own test runner, no dependencies).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  elementSnippet, elementsCopy, looksLikePdf, mayPick, pdfCrop, pdfName, pdfPointCopy, pickedElement, PICK_MAX, PICK_TEXT_LIMIT
} from '../lib/core.js';

const button = { selector: '#buy', label: 'button#buy', text: 'Buy now', html: '<button id="buy">Buy now</button>' };

test('an element reads as in Nook\'s own browser: where, its markup and its text', () => {
  assert.equal(elementSnippet('https://shop.test/p', pickedElement(button)), [
    'Element `button#buy` on https://shop.test/p',
    'Selector: `#buy`',
    '',
    '```html',
    '<button id="buy">Buy now</button>',
    '```',
    '',
    'Text:',
    'Buy now'
  ].join('\n'));
});

test('markup with backticks never closes its fence', () => {
  const snippet = elementSnippet('https://x.test', pickedElement({ ...button, html: '<code>````</code>' }));
  assert.match(snippet, /\n`````html\n<code>````<\/code>\n`````/);
});

test('an element without a label is named by its selector, and text equal to the markup is not repeated', () => {
  const element = pickedElement({ selector: 'main > p', label: '', text: 'hi', html: 'hi' });
  assert.equal(elementSnippet('https://x.test', element), 'Element `main > p` on https://x.test\nSelector: `main > p`\n\n```html\nhi\n```');
});

test('several elements go as one text, named after the first', () => {
  const copied = elementsCopy('https://x.test', [button, { selector: 'h1', label: 'h1.title', text: 'Hi', html: '<h1>Hi</h1>' }]);
  assert.equal(copied.name, 'button#buy +1');
  assert.equal(copied.text.split('\n\n---\n\n').length, 2);
  assert.equal(elementsCopy('https://x.test', [button]).name, 'button#buy');
});

test('what the page hands back is checked and clipped', () => {
  assert.equal(elementsCopy('https://x.test', null), null);
  assert.equal(elementsCopy('https://x.test', []), null);
  assert.equal(elementsCopy('https://x.test', [{ selector: '' }, 'x', { selector: 5 }]), null);
  assert.equal(pickedElement({ selector: 'p', text: 'a'.repeat(PICK_TEXT_LIMIT + 50) }).text.length, PICK_TEXT_LIMIT);
  assert.equal(pickedElement({ selector: 'p', text: 7 }).text, '');
  const many = Array.from({ length: PICK_MAX + 5 }, (_, i) => ({ selector: `li:nth-of-type(${i + 1})` }));
  assert.equal(elementsCopy('https://x.test', many).text.split('---').length, PICK_MAX);
});

test('a spot in a PDF says where in the viewer, and that a picture goes along', () => {
  const copied = pdfPointCopy('https://x.test/docs/Annual%20report.pdf', { x: 400, y: 150, width: 800, height: 600 });
  assert.equal(copied.name, 'Annual report.pdf · 50%, 25%');
  assert.match(copied.text, /^Point in PDF `Annual report\.pdf` \(https:\/\/x\.test\/docs\/Annual%20report\.pdf\)\n/);
  assert.match(copied.text, /50% from the left and 25% from the top/);
  assert.match(copied.text, /picture of the area around it/);
  assert.equal(pdfPointCopy('https://x.test/a.pdf', { x: 1, y: 1, width: 0, height: 10 }), null);
  assert.equal(pdfPointCopy('https://x.test/a.pdf', null), null);
  assert.equal(pdfName('https://x.test/'), 'https://x.test/');
});

test('the picture around a PDF spot stays inside the window', () => {
  // A 2x screen: the picture is twice the window's CSS size.
  const middle = pdfCrop({ x: 400, y: 300, width: 800, height: 600 }, 1600, 1200);
  assert.deepEqual(middle, { left: 240, top: 240, width: 1120, height: 720, scale: 2, spot: { x: 560, y: 360 } });
  const corner = pdfCrop({ x: 5, y: 5, width: 800, height: 600 }, 1600, 1200);
  assert.equal(corner.left, 0);
  assert.equal(corner.top, 0);
  assert.deepEqual(corner.spot, { x: 10, y: 10 });
  const small = pdfCrop({ x: 100, y: 50, width: 300, height: 200 }, 300, 200);
  assert.deepEqual([small.left, small.top, small.width, small.height], [0, 0, 300, 200]);
});

test('selecting works on every page the browser lets an extension script, and local files', () => {
  for (const url of ['https://example.com', 'http://localhost:3000/a', 'file:///Users/me/a.pdf']) assert.equal(mayPick(url), true, url);
  for (const url of ['chrome://settings', 'https://chromewebstore.google.com/x', 'about:blank', '']) assert.equal(mayPick(url), false, url);
  assert.equal(looksLikePdf('https://x.test/a.PDF?x=1'), true);
  assert.equal(looksLikePdf('https://x.test/pdf'), false);
});

test('the page script is there, with Nook\'s iris and the same limits as Nook\'s browser', () => {
  const source = readFileSync(new URL('../page/pick.js', import.meta.url), 'utf8');
  assert.match(source, /#7c6cf0/);
  assert.match(source, /TEXT_LIMIT = 1500/);
  assert.match(source, /HTML_LIMIT = 6000/);
  const swift = readFileSync(new URL('../../macos/Services/Workspace/BrowserPicker.swift', import.meta.url), 'utf8');
  assert.match(swift, /textLimit = 1500/);
  assert.match(swift, /htmlLimit = 6000/);
});
