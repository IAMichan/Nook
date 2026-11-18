// The picker (page/pick.js) in a real Chromium: hovering outlines an element, a click takes it without reaching the
// page, Shift-click takes several, Escape stops, a PDF gets a sheet that takes the spot, and `copy` puts the text on
// the clipboard. Runs where Playwright is installed; skipped elsewhere, so `npm test` needs no dependencies.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
let chromium = null;
try {
  ({ chromium } = require('playwright'));
} catch {
  // No Playwright here: the test below is skipped.
}

const pickSource = readFileSync(new URL('../page/pick.js', import.meta.url), 'utf8');
const page = fileURLToPath(new URL('./fixtures/checkout.html', import.meta.url));
const texts = { pickElementHint: 'Klik op een element', pickElementMore: '$1 geselecteerd', pickCopied: '$1 gekopieerd' };

async function open(browser) {
  const context = await browser.newContext({ viewport: { width: 900, height: 640 } });
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: 'http://localhost' }).catch(() => {});
  const tab = await context.newPage();
  await tab.goto('file://' + page);
  await tab.evaluate((nl) => {
    window.chrome = window.chrome || {};
    window.chrome.i18n = { getMessage: (key, subs) => (nl[key] || '').replace('$1', (subs || [])[0] || '') };
  }, texts);
  await tab.addScriptTag({ content: pickSource });
  await tab.click('#ok'); // the cookie banner, as the user would
  return tab;
}

async function middleOf(tab, selector) {
  const box = await tab.locator(selector).boundingBox();
  return [box.x + box.width / 2, box.y + box.height / 2];
}

test('a click takes the element under the pointer and never reaches the page', { skip: !chromium && 'Playwright is not installed' }, async () => {
  const browser = await chromium.launch();
  try {
    const tab = await open(browser);
    const picked = tab.evaluate(() => window.__nookPick.element());
    await tab.waitForFunction(() => window.__nookPick.busy());
    const [x, y] = await middleOf(tab, '#pay');
    await tab.mouse.move(x, y);
    const outline = await tab.evaluate(() => document.getElementById('__nook-pick-layer')?.textContent);
    assert.equal(outline, 'button#pay', 'the outline\'s badge names the element');
    await tab.mouse.click(x, y);
    const [element] = await picked;
    assert.equal(element.selector, '#pay');
    assert.equal(element.label, 'button#pay');
    assert.equal(element.text, 'Betalen');
    assert.match(element.html, /^<button id="pay"/);
    assert.equal(await tab.textContent('#out'), '', 'the page did not get the click');
    assert.equal(await tab.evaluate(() => window.__nookPick.busy()), false);
    await tab.click('#pay');
    assert.equal(await tab.textContent('#out'), 'Betaald!', 'afterwards the page is the user\'s again');
  } finally {
    await browser.close();
  }
});

test('Shift-click takes several, Return ends; Escape stops with nothing', { skip: !chromium && 'Playwright is not installed' }, async () => {
  const browser = await chromium.launch();
  try {
    const tab = await open(browser);
    let picked = tab.evaluate(() => window.__nookPick.element());
    await tab.waitForFunction(() => window.__nookPick.busy());
    for (const selector of ['h1', '#name']) {
      const [x, y] = await middleOf(tab, selector);
      await tab.mouse.move(x, y);
      await tab.keyboard.down('Shift');
      await tab.mouse.click(x, y);
      await tab.keyboard.up('Shift');
    }
    await tab.keyboard.press('Enter');
    assert.deepEqual((await picked).map((element) => element.selector), ['main > h1', '#name']);

    picked = tab.evaluate(() => window.__nookPick.element());
    await tab.waitForFunction(() => window.__nookPick.busy());
    await tab.mouse.move(...(await middleOf(tab, 'h1')));
    await tab.keyboard.press('Escape');
    assert.deepEqual(await picked, []);
    assert.equal(await tab.evaluate(() => document.getElementById('__nook-pick-layer')), null, 'no marks stay behind');
  } finally {
    await browser.close();
  }
});

test('in a PDF a sheet takes the spot, and copy puts the text on the clipboard', { skip: !chromium && 'Playwright is not installed' }, async () => {
  const browser = await chromium.launch();
  try {
    const tab = await open(browser);
    const spot = tab.evaluate(() => window.__nookPick.point());
    await tab.waitForFunction(() => window.__nookPick.busy());
    await tab.mouse.click(450, 160);
    assert.deepEqual(await spot, { x: 450, y: 160, width: 900, height: 640 });
    assert.equal(await tab.textContent('#out'), '');

    const copied = await tab.evaluate(() => window.__nookPick.copy('Element `h1` on x', null, 'h1'));
    assert.equal(copied, true);
    const toast = await tab.evaluate(() => !!document.querySelector('nook-pick'));
    assert.equal(toast, true, 'the toast says it was copied');
  } finally {
    await browser.close();
  }
});
