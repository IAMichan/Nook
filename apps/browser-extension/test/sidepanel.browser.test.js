// The side panel (sidepanel.html) in a real Chromium against a fake `chrome.*`: while Nook writes a long answer and
// pushes it, the panel keeps asking Nook to follow its conversation before the lease runs out. Runs where Playwright is
// installed; skipped elsewhere, so `npm test` needs no dependencies.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WATCH_LEASE } from '../lib/core.js';

const require = createRequire(import.meta.url);
let chromium = null;
try {
  ({ chromium } = require('playwright'));
} catch {
  // No Playwright here: the test below is skipped.
}

const root = fileURLToPath(new URL('../', import.meta.url));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json' };

/** The extension's folder over http: a module script does not load from file://. */
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

test('the panel keeps Nook following a long answer it pushes, past the lease', { skip: !chromium && 'Playwright is not installed' }, async () => {
  const server = await serve();
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.clock.install({ time: new Date('2026-11-14T12:00:00Z') });
    await page.addInitScript(() => {
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
      const answer = (text, streaming) => [
        { id: 'q', fromNook: false, text: 'Vat dit samen', streaming: false },
        { id: 'a', fromNook: true, text, streaming }
      ];
      window.__asks = [];
      window.__push = (n) => {
        for (const listener of listeners) {
          listener({ type: 'chatUpdate', conversation: 'c1', messages: answer('word '.repeat(n), true), revision: 'r' + n });
        }
      };
      window.chrome = {
        i18n: { getMessage: () => '' },
        runtime: {
          id: 'abcdefghijklmnopabcdefghijklmnop',
          onMessage: { addListener: (fn) => listeners.push(fn) },
          async sendMessage(message) {
            if (message.type === 'chat' && message.watch) window.__asks.push(Date.now());
            if (message.type === 'chat') return { ok: true, live: true, conversation: 'c1', messages: answer('', true), revision: 'r0' };
            return { ok: true };
          }
        },
        storage: {
          local: area({}),
          session: area({ conversation: 'c1', status: { nook: 'connected' } }),
          onChanged: event()
        },
        tabs: { async query() { return []; }, onActivated: event(), onUpdated: event() },
        windows: { async getCurrent() { return { id: 1 }; } }
      };
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/sidepanel.html`);
    await page.waitForFunction(() => window.__asks.length >= 1);

    // Nook writes for 25 minutes and pushes every second, so the panel itself has no reason to ask.
    for (let second = 1; second <= 25 * 60; second += 1) {
      await page.evaluate((n) => window.__push(n), second);
      await page.clock.runFor(1_000);
    }
    const asks = await page.evaluate(() => window.__asks);
    const start = asks[0];
    const end = start + 25 * 60_000;
    const gaps = asks.slice(1).map((at, i) => at - asks[i]).concat(end - asks.at(-1));
    assert.ok(asks.length >= 6, `the panel kept asking (${asks.length} times)`);
    assert.ok(Math.max(...gaps) < WATCH_LEASE, `never a gap as long as the lease (longest ${Math.max(...gaps) / 60_000} min)`);
    assert.ok(asks.some((at) => at - start > WATCH_LEASE), 'also after the first lease would have ended');
  } finally {
    await browser.close();
    server.close();
  }
});
