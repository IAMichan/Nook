# Nook's browser extension

The extension for Chrome, Brave, Edge, Arc, Vivaldi and Chromium. It lets you ask Nook about the page you are on from
the browser's side panel. It also lets Nook Chat and your coding agents read your tabs and act in them, after you
approve each action, or at once on a site you let Nook act on without asking.

- Set it up in Nook: **Settings › Editor & browser › Nook in your browser**.
- How it works, the tools, and what keeps it safe: [`docs/BROWSER-EXTENSION.md`](../../docs/BROWSER-EXTENSION.md).
- Tests: `npm test` (Node's own test runner, no dependencies).
- The composer: `npm run build` (after `npm ci` in `packages/web-ui`). The Chrome Web Store zip: `npm run package`.

| File | What it is |
|---|---|
| `manifest.json` | Manifest V3. The `key` fixes the extension's id, which Nook's host allows. |
| `background.js` | Service worker: the port to Nook, the commands, and the side panel's messages |
| `lib/core.js` | Pure logic (checks, texts for Nook), tested in `test/` |
| `page/agent.js` | Nook's hands on a page (find, read, click, type, scroll, key, and form and fill for Double Tap), injected only when asked |
| `page/pick.js` | Selecting an element (or a spot in a PDF) on any page and copying where it is, for a coding agent's prompt |
| `page/presence.js` | The glow (in the driving agent's logo colors) and the "… is working · Stop" strip while Nook acts |
| `sidepanel.*` | The side panel: status, the switch per site, pause, chat, and activity, in Nook's own theme (`look`) |
| `composer/` | The side panel's composer (with the model chip) and transcript: Nook's shared ones (`packages/web-ui`) in the panel's tokens and texts |
| `ui/composer.js` | `composer/` (composer and transcript) built by `npm run build`; checked in, so Nook carries the extension without a build step |
| `scripts/package.js` | `npm run package`: the zip for the Chrome Web Store, without tests, sources and the manifest's `key` |
| `_locales/` | Texts in English, Dutch, German, French and Spanish |
