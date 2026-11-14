// The page agent (page/agent.js) in a real Chromium: it fills in, chooses, clicks through a shadow root, says what
// covers a button, scrolls, and shows its cursor with a badge. Runs where Playwright is installed; skipped elsewhere,
// so `npm test` needs no dependencies.
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

const agentSource = readFileSync(new URL('../page/agent.js', import.meta.url), 'utf8');
const presenceSource = readFileSync(new URL('../page/presence.js', import.meta.url), 'utf8');
const page = fileURLToPath(new URL('./fixtures/checkout.html', import.meta.url));
const texts = { presenceWorking: 'Nook is hier bezig', presenceBlocked: 'Je klikken wachten', presenceStop: 'Stop', cursorClick: 'Klikt', cursorType: 'Typt', cursorScroll: 'Scrolt', cursorKey: 'Drukt op $1', cursorChoose: 'Kiest' };

test('the page agent works on a real page and shows what it does', { skip: !chromium && 'Playwright is not installed' }, async () => {
  const browser = await chromium.launch();
  try {
    const tab = await browser.newPage({ viewport: { width: 900, height: 640 } });
    await tab.goto('file://' + page);
    await tab.evaluate((nl) => {
      window.chrome = window.chrome || {};
      window.chrome.i18n = { getMessage: (key, subs) => (nl[key] || '').replace('$1', (subs || [])[0] || '') };
    }, texts);
    await tab.addScriptTag({ content: agentSource });
    const run = (method, params = {}) => tab.evaluate(([m, p]) => window.__nookAgent.run(m, p), [method, params]);
    const badge = () => tab.evaluate(() => {
      // The cursor lives in a closed shadow root: read its badge through the agent's own element by layout.
      const host = document.querySelector('nook-cursor');
      return host ? host.getBoundingClientRect().width > 0 : false;
    });

    const typed = await run('type', { text: 'Naam', value: 'Lisa de Vries' });
    assert.equal(typed.ok, true, typed.error);
    assert.equal(await tab.inputValue('#name'), 'Lisa de Vries');
    assert.ok(Number.isFinite(typed.cursor?.x), 'the cursor position comes back, for the next page');
    assert.equal(await badge(), true, 'the cursor is on the page');

    assert.equal((await run('type', { text: 'Verzending', value: 'Express' })).ok, true);
    assert.equal(await tab.inputValue('#ship'), 'Express');

    const covered = await run('click', { text: 'Helemaal onderaan' });
    assert.equal(covered.ok, false);
    assert.match(covered.error, /covered by a banner or dialog/);
    const accept = covered.error.match(/\[(e\d+)\] button "Accepteren"/);
    assert.ok(accept, 'the banner\'s own button comes with its ref');
    assert.equal((await run('click', { ref: accept[1] })).ok, true);
    assert.equal(await tab.$('#banner'), null, 'the banner is gone');

    assert.equal((await run('click', { text: 'Nieuwsbrief' })).ok, true, 'a button inside a shadow root');
    assert.equal(await tab.evaluate(() => document.querySelector('my-widget').shadowRoot.querySelector('button').textContent), 'Nieuwsbrief: aan');

    assert.equal((await run('click', { text: 'Betalen' })).ok, true);
    assert.equal(await tab.textContent('#out'), 'Betaald!');

    const scrolled = await run('scroll', { direction: 'bottom' });
    assert.equal(scrolled.ok, true);
    assert.match(scrolled.text, /In view:\n\[e\d+\] button "Helemaal onderaan"/, 'what can be used now comes along');

    const look = await run('glance');
    assert.match(look.text, /^Now: Testwinkel · Afrekenen \|/);
  } finally {
    await browser.close();
  }
});

test('while Nook works the user\'s own clicks wait, Nook\'s own pass, and a sign-in page frees them',
  { skip: !chromium && 'Playwright is not installed' }, async () => {
    const browser = await chromium.launch();
    try {
      const tab = await browser.newPage({ viewport: { width: 900, height: 640 } });
      await tab.goto('file://' + page);
      await tab.evaluate((nl) => {
        window.chrome = window.chrome || {};
        window.chrome.i18n = { getMessage: (key, subs) => (nl[key] || '').replace('$1', (subs || [])[0] || '') };
        window.chrome.runtime = { sendMessage: async () => ({}) };
      }, texts);
      await tab.addScriptTag({ content: presenceSource });
      await tab.addScriptTag({ content: agentSource });
      const run = (method, params = {}) => tab.evaluate(([m, p]) => window.__nookAgent.run(m, p), [method, params]);
      await tab.click('#ok'); // the cookie banner, as the user would

      await tab.evaluate(() => window.__nookPresence.busy(10_000));
      await tab.click('#pay', { force: true }); // a real (trusted) click by the user
      assert.equal(await tab.textContent('#out'), '', 'the user\'s click waited');
      await tab.keyboard.press('KeyA');
      await tab.click('#name', { force: true });
      await tab.keyboard.type('xyz');
      assert.equal(await tab.inputValue('#name'), '', 'the user\'s typing waited too');

      assert.equal((await run('type', { text: 'Naam', value: 'Lisa' })).ok, true, 'Nook types');
      assert.equal(await tab.inputValue('#name'), 'Lisa');
      assert.equal((await run('click', { text: 'Betalen' })).ok, true, 'Nook clicks');
      assert.equal(await tab.textContent('#out'), 'Betaald!');

      await tab.evaluate(() => { document.getElementById('out').textContent = ''; window.__nookPresence.release(); });
      await tab.click('#pay');
      assert.equal(await tab.textContent('#out'), 'Betaald!', 'once Nook is done the user\'s clicks work again');

      // A sign-in page: Nook sees that it asks to sign in, and the user's hands are free.
      assert.equal((await run('signin')).needed, false);
      await tab.evaluate(() => {
        const field = document.createElement('input');
        field.type = 'password';
        field.id = 'secret';
        document.querySelector('main').prepend(field);
        window.__nookPresence.busy(10_000);
        window.__nookPresence.signIn();
      });
      assert.equal((await run('signin')).needed, true);
      await tab.click('#secret');
      await tab.keyboard.type('hunter2');
      assert.equal(await tab.inputValue('#secret'), 'hunter2', 'the user types their own password');
      const refused = await run('type', { selector: '#secret', value: 'x' });
      assert.equal(refused.ok, false);
      assert.equal(refused.signIn, true, 'Nook never types a password: it waits for the user');
      await tab.evaluate(() => document.getElementById('secret').remove());
      assert.equal((await run('signin')).needed, false, 'signed in: Nook goes on');

      // A sign-in code the user typed never shows in what Nook reads.
      await tab.evaluate(() => {
        const code = document.createElement('input');
        code.autocomplete = 'one-time-code';
        code.setAttribute('aria-label', 'Code');
        code.value = '483920';
        document.querySelector('main').prepend(code);
      });
      const look = await run('find', { query: 'code' });
      assert.match(look.text, /value=\(hidden\)/);
      assert.doesNotMatch(look.text, /483920/);

      // Escape is Stop from the keyboard while Nook works here.
      await tab.evaluate(() => {
        window.__sent = [];
        window.chrome.runtime.sendMessage = async (message) => { window.__sent.push(message); return { ok: true }; };
        window.__nookPresence.busy(10_000);
      });
      await tab.keyboard.press('Escape');
      assert.deepEqual(await tab.evaluate(() => window.__sent), [{ type: 'pause', paused: true }]);
      assert.equal(await tab.evaluate(() => window.__nookPresence.mode), 'idle', 'the page is the user\'s again');
    } finally {
      await browser.close();
    }
  });
