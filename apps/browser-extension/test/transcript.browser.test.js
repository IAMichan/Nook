// Moving through the side panel's conversation in a real Chromium against a fake `chrome.*`: following the answer
// until the user scrolls up, back to the newest answer, question by question, finding text, reading further back, and
// going back to an earlier chat. Runs where Playwright is installed; skipped elsewhere, so `npm test` needs no
// dependencies.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
let chromium = null;
try {
  ({ chromium } = require('playwright'));
} catch {
  // No Playwright here: the test below is skipped.
}

const root = fileURLToPath(new URL('../', import.meta.url));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json' };
const C1 = '11111111-1111-4111-8111-111111111111';
const C2 = '22222222-2222-4222-8222-222222222222';

function serve() {
  const server = createServer(async (request, response) => {
    const path = normalize(join(root, decodeURIComponent(new URL(request.url, 'http://x').pathname)));
    if (!path.startsWith(root)) return response.writeHead(403).end();
    try {
      const body = await readFile(path);
      response.writeHead(200, { 'content-type': types[extname(path)] || 'application/octet-stream' }).end(body);
    } catch {
      response.writeHead(404).end();
    }
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

/** A fake browser for the panel: conversation C1 with six questions and four earlier messages, C2 as an earlier chat. */
function fakeChrome({ C1, C2 }) {
  const listeners = [];
  const event = () => ({ addListener() {} });
  const area = (data) => ({
    async get(keys) {
      if (typeof keys === 'string') keys = [keys];
      if (Array.isArray(keys)) return Object.fromEntries(keys.filter((k) => k in data).map((k) => [k, data[k]]));
      return Object.fromEntries(Object.entries(keys || {}).map(([k, v]) => [k, k in data ? data[k] : v]));
    },
    async set(values) { Object.assign(data, values); },
    async remove(key) { delete data[key]; }
  });
  const start = Date.now() - 60 * 60_000;
  const pair = (n, answer) => [
    { id: `q${n}`, fromNook: false, text: `Question ${n}`, at: start + n * 60_000 },
    { id: `a${n}`, fromNook: true, text: answer || `Answer ${n}. ` + 'alpha beta gamma delta. '.repeat(30), at: start + n * 60_000 + 5_000 }
  ];
  const window1 = [1, 2, 3, 4, 5, 6].flatMap((n) => pair(n));
  // What Nook has now: the panel also asks now and then while Nook writes.
  let current = { messages: window1, revision: 'r0' };
  const before = [-1, 0].flatMap((n) => pair(n, `Earlier answer ${n}`));
  window.__requests = [];
  window.__push = (text) => {
    const messages = [...window1, { id: 'q7', fromNook: false, text: 'Question 7' }, { id: 'a7', fromNook: true, text, streaming: true }];
    current = { messages, revision: 'r' + text.length };
    for (const listener of listeners) listener({ type: 'chatUpdate', conversation: C1, earlier: 4, ...current });
  };
  window.chrome = {
    i18n: { getMessage: (key, subs) => [key, ...(subs || [])].join(' '), getUILanguage: () => 'en' },
    runtime: {
      id: 'abcdefghijklmnopabcdefghijklmnop',
      onMessage: { addListener: (fn) => listeners.push(fn) },
      async sendMessage(message) {
        window.__requests.push(message);
        if (message.type === 'chat' && message.before) {
          return { ok: true, older: true, conversation: C1, messages: before, earlier: 0 };
        }
        if (message.type === 'chat' && message.conversation === C2) {
          return { ok: true, live: true, conversation: C2, messages: pair(9, 'The other chat'), earlier: 0, revision: 'c2' };
        }
        if (message.type === 'chat') return { ok: true, live: true, conversation: C1, earlier: 4, ...current };
        if (message.type === 'chats') {
          return { ok: true, chats: [
            { id: C1, title: 'Six questions', updated: Date.now(), busy: false },
            { id: C2, title: 'The other chat', updated: Date.now() - 2 * 3_600_000, busy: false }
          ] };
        }
        return { ok: true };
      }
    },
    storage: {
      local: area({ chats: [{ id: C1, title: 'Question 1' }, { id: C2, title: 'Question 9' }] }),
      session: area({ conversation: C1, status: { nook: 'connected' } }),
      onChanged: event()
    },
    tabs: { async query() { return []; }, onActivated: event(), onUpdated: event() },
    windows: { async getCurrent() { return { id: 1 }; } }
  };
}

const scroll = (page) => page.$eval('#chat', (chat) => ({
  top: chat.scrollTop, end: chat.scrollHeight - chat.clientHeight
}));
const settle = (page) => page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 700)));

test('the panel can be moved through: follow, newest, question by question, find, earlier, other chats',
  { skip: !chromium && 'Playwright is not installed' }, async () => {
    const server = await serve();
    const browser = await chromium.launch();
    try {
      const page = await browser.newPage({ viewport: { width: 380, height: 640 } });
      await page.addInitScript(fakeChrome, { C1, C2 });
      await page.goto(`http://127.0.0.1:${server.address().port}/sidepanel.html`);
      await page.waitForSelector('[data-role="you"]');
      await settle(page);

      // At the end, following the conversation.
      let at = await scroll(page);
      assert.ok(at.end > 0 && at.end - at.top < 4, `starts at the end (${at.top} of ${at.end})`);
      assert.equal(await page.isHidden('#to-latest'), true);
      assert.equal(await page.isVisible('#question-nav'), true, 'question by question once there is more than one');

      // Scrolling up to read stops following; a pushed answer leaves the reader where they are and says so.
      await page.mouse.move(190, 300);
      await page.mouse.wheel(0, -600);
      await settle(page);
      const reading = (await scroll(page)).top;
      assert.equal(await page.isVisible('#to-latest'), true, '"to the newest" shows once you scrolled up');
      await page.evaluate(() => window.__push('Streaming answer '.repeat(80)));
      await settle(page);
      assert.ok(Math.abs((await scroll(page)).top - reading) < 2, 'stays where the user reads');
      assert.equal(await page.$eval('#to-latest', (b) => b.classList.contains('fresh')), true, 'says Nook wrote more');

      // Back to the newest answer, and following again.
      await page.click('#to-latest');
      await settle(page);
      at = await scroll(page);
      assert.ok(at.end - at.top < 4, 'back at the end');
      await page.evaluate(() => window.__push('Streaming answer '.repeat(160)));
      await settle(page);
      at = await scroll(page);
      assert.ok(at.end - at.top < 4, 'follows the answer as it grows');

      // ⌥↑ goes to the question above, ⌥↓ to the next; past the last, to the end.
      await page.keyboard.press('Alt+ArrowUp');

      await settle(page);
      const questionTop = () => page.evaluate(() => {
        const chat = document.getElementById('chat');
        const rows = [...document.querySelectorAll('[data-role="you"]')];
        const tops = rows.map((row) => row.getBoundingClientRect().top - chat.getBoundingClientRect().top);
        return rows[tops.findIndex((top) => top >= -2 && top < 40)]?.textContent.trim();
      });
      assert.match(await questionTop(), /Question 7/);
      await page.keyboard.press('Alt+ArrowUp');
      await settle(page);
      assert.match(await questionTop(), /Question 6/);
      await page.click('#question-next');
      await settle(page);
      assert.match(await questionTop(), /Question 7/);

      // Find: every match marked, Enter to the next, the count says where.
      await page.keyboard.press('Control+f');
      assert.equal(await page.isVisible('#find-bar'), true);
      await page.keyboard.type('gamma');
      const count = await page.textContent('#find-count');
      assert.match(count, /^findCount \d+ \d+$/, count);
      const total = Number(count.split(' ')[2]);
      assert.equal(total, 6 * 30);
      await page.keyboard.press('Enter');
      const next = await page.textContent('#find-count');
      assert.notEqual(next, count, 'Enter goes to the next match');
      assert.equal(await page.evaluate(() => CSS.highlights.get('nook-find')?.size), total);
      await page.keyboard.press('Escape');
      assert.equal(await page.isHidden('#find-bar'), true);
      assert.equal(await page.evaluate(() => CSS.highlights.has('nook-find')), false);

      // Reading further back keeps the place and adds the earlier messages above.
      await page.$eval('#chat', (chat) => (chat.scrollTop = 0));
      await settle(page);
      assert.equal(await page.isVisible('#earlier'), true);
      await page.click('#earlier');
      await settle(page);
      assert.equal(await page.isHidden('#earlier'), true, 'nothing earlier left');
      const questions = await page.$$eval('[data-role="you"]', (rows) => rows.map((row) => row.textContent.trim()));
      assert.deepEqual(questions.slice(0, 3).map((q) => q.replace(/^.*(Question -?\d+)$/s, '$1')), ['Question -1', 'Question 0', 'Question 1']);
      const asked = await page.evaluate(() => window.__requests.find((m) => m.before));
      assert.equal(asked.before, 'q1', 'asks for what comes before the oldest message it has');

      // The questions menu lists every question and jumps to one.
      await page.click('#outline-open');
      await page.waitForFunction(() => document.querySelectorAll('#outline-list button').length > 0);
      const items = await page.$$eval('#outline-list button', (buttons) => buttons.map((b) => b.textContent));
      assert.equal(items.length, 9, JSON.stringify(items));
      await page.click('#outline-list li:nth-child(4) button');
      await settle(page);
      assert.match(await questionTop(), /Question 2/);

      // Earlier chats: Nook's titles, and opening one follows it.
      await page.click('#history-open');
      await page.waitForFunction(() => document.querySelector('#history-list')?.textContent.includes('Six questions'));
      await page.click('#history-list li:nth-child(2) button');
      await page.waitForFunction(() => document.querySelector('#transcript')?.textContent.includes('The other chat'));
      const opened = await page.evaluate(() => window.__requests.filter((m) => m.type === 'chat').at(-1));
      assert.equal(opened.conversation, C2);
      assert.equal(opened.watch, true);
    } finally {
      await browser.close();
      server.close();
    }
  });
