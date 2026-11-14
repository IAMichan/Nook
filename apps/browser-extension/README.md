# Nook's browser extension

The extension for Chrome, Brave, Edge, Arc, Vivaldi and Chromium. It lets you ask Nook about the page you are on from
the browser's side panel. It also lets Nook Chat and your coding agents read your tabs and act in them, after you
approve each action.

- Set it up in Nook: **Settings › Editor & browser › Nook in your browser**.
- How it works, the tools, and what keeps it safe: [`docs/BROWSER-EXTENSION.md`](../../docs/BROWSER-EXTENSION.md).
- Tests: `npm test` (Node's own test runner, no dependencies).

| File | What it is |
|---|---|
| `manifest.json` | Manifest V3. The `key` fixes the extension's id, which Nook's host allows. |
| `background.js` | Service worker: the port to Nook, the commands, and the side panel's messages |
| `lib/core.js` | Pure logic (checks, texts for Nook), tested in `test/` |
| `page/agent.js` | Nook's hands on a page (find, read, click, type, scroll, key), injected only when asked |
| `page/presence.js` | The glow and the "Nook is working · Stop" strip while Nook acts |
| `sidepanel.*` | The side panel: status, the switch per site, pause, chat, and activity |
| `_locales/` | Texts in English, Dutch, German, French and Spanish |
