# Nook in your browser

Nook's browser extension (`apps/browser-extension`) brings Nook into the browser you already use: Chrome, Brave, Edge,
Arc, Vivaldi or Chromium. You get two things:

- **Ask Nook about the page you are on.** Click Nook's icon in the toolbar and the side panel opens. Ask "what is this
  about?" or "fill in my name here". The same assistant answers as in Nook's main window, with the same conversations,
  sources and memory. Nook knows which page you have in front.
- **Nook can read and act in your tabs.** Nook Chat and every coding agent (through `nook_tools`/`nook_use`) can list
  your tabs, read a page as you see it (signed in), find the buttons and fields on it, and open, click, type and press
  keys there. Reading runs directly. Every action waits for your approval in Nook first and is written to the audit log,
  like every other side effect.

The extension is a thin pair of hands. Nook decides what may happen, and the extension carries it out. Nothing runs on
a page until Nook is asked, and the extension sends nothing anywhere but to Nook on your Mac.

## Setting it up

1. In Nook, open **Settings › Editor & browser › Nook in your browser** and click **Connect**. Nook writes a small
   native messaging host (`~/Library/Application Support/Nook/nook-browser-host`), registers it with every Chromium
   browser on the Mac, and puts a copy of the extension in `~/Library/Application Support/Nook/Browser Extension`.
2. Click **Copy address**, paste it in your browser's address bar (`chrome://extensions`, `brave://extensions`…), and
   turn on **Developer mode**.
3. Click **Load unpacked** and choose the `Browser Extension` folder (**Show folder** in Settings opens it).
4. Click Nook's icon in the toolbar. The side panel opens and says **Connected**.

**Disconnect** in Settings removes the host and its registrations. The browsers then cannot reach Nook any more.

## The tools

| Tool | What it does | Approval |
|---|---|---|
| `chrome_tabs` | The open tabs per window, with the active one and the one Nook works in | no |
| `chrome_read` | Title, address, scroll position, the user's selection, and the page's text | no |
| `chrome_find` | The links, buttons and fields on the page, with refs (`e7`), optionally filtered | no |
| `chrome_screenshot` | A JPEG of the tab, saved in `Browser Screenshots` in Nook's folder (the newest 20) | no |
| `chrome_wait` | Waits for text or a selector to appear or disappear | no |
| `chrome_console` | The page's console errors and warnings (it starts listening on the first call) | no |
| `chrome_scroll` | Scrolls the page, or brings an element into view | no |
| `chrome_open` | Opens an address in a new tab in Nook's tab group (or in a given tab); back, forward, reload | yes |
| `chrome_click` | Clicks an element by ref, CSS selector or visible text | yes |
| `chrome_type` | Types into a field (or picks an option); `submit` sends the form | yes, with the exact text |
| `chrome_key` | Presses a key (Enter, Escape, Tab, arrows…) | yes |
| `chrome_close` | Closes a tab Nook opened (only those in Nook's group) | yes |

Coding agents also reach these tools without `nook_use`: Nook's own browser tools (`browser_open`, `browser_read`,
`browser_screenshot`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_wait_for`) take `in: "user"` to work
in your browser instead of Nook's (`BridgeUserBrowser`). They become `chrome_open`, `chrome_read`, `chrome_screenshot`,
`chrome_find`, `chrome_click`, `chrome_type` and `chrome_wait`, and run as `nook_use` with every rule of that path:
actions still wait for your approval whatever the session's rights, an agent on another machine never gets them, and
switching off **Nook's apps** for an agent switches them off too. `tab` and `browser` go along as the `chrome_*` tools
take them. The other tools (`chrome_tabs`, `chrome_key`, `chrome_scroll`, `chrome_console`, `chrome_close`) stay behind
`nook_use`, so the tool list every request carries does not grow.

A command goes to the tab it names (`tab`), else to the tab Nook worked in last, else to the active tab of the window
in front. When several browsers run the extension, `browser` picks one; otherwise the one you used last gets it. The
approval card says what Nook will do and where. For example: *Click button "Send" · mail.example.com*. Nook takes the
element's name from the last `chrome_find` (`BrowserExtensionRefs`).

## What keeps it safe

- **Approval for every action.** Opening, clicking, typing, pressing keys and closing tabs are actions
  (`ToolSpec.Kind.action`). They go through Nook's approval card and the audit log, whoever asks: Nook Chat, a
  Think-Along card or a coding agent.
- **Your brakes in the browser.** The side panel has a switch per site ("Nook on github.com"). A site you switch off is
  never read or touched, including its subdomains. **Pause** stops Nook in the whole browser until you resume, and the
  toolbar icon shows a badge while it is paused. While Nook acts on a page, a violet glow and a strip with **Stop** show
  at the bottom. Stop pauses Nook in that browser.
- **Pages the browser keeps to itself.** `chrome://` and the other browsers' own pages, `file://`, and the web stores
  are refused (`isRestricted` in `lib/core.js`).
- **No passwords.** The extension never types into a password field. Snapshots show only that a password field has a
  value, never the value itself.
- **Only https.** Nook opens only https addresses. Plain http works only for a server on this Mac (localhost), as in
  Nook's own browser.
- **Only Nook's tabs close.** `chrome_close` only closes tabs Nook opened itself (its tab group).
- **Untrusted text.** Page text, titles and console output are untrusted data for the assistant and for agents, never
  instructions. The side panel shows Nook's answers as plain text. Code, bold and links are built as DOM nodes, never as
  HTML.
- **Who may connect.** The host manifest allows only this extension's id (`allowed_origins`). The id is fixed by the
  public key in `manifest.json`. The host talks to Nook over `browser.sock`, which only your user can open (0600, and
  each connection's user is checked). The extension has no `debugger` permission and no content scripts. It injects its
  page agent into a tab only when Nook sends a command for that tab, into the page's isolated world, where the page's
  own scripts cannot reach it.
- **Privacy level.** The source counts as personal data on this Mac (`SourceCatalog.personal`). With a privacy level
  that keeps personal sources local, an external brain or agent does not get these tools.

## How it fits together

```text
Side panel / page agent ─┐
                         ├─ service worker (background.js) ── native messaging ── nook-browser-host (Perl)
Nook's commands ─────────┘                                                        │ one line of JSON per request
                                                                                  ▼
                                   BrowserExtensionHub ◀── browser.sock (UnixSocketServer) ── BrowserExtensionService
                                          ▲
                     BrowserExtensionConnector (chrome_* tools) ── Nook Chat, Think Along, nook_use and browser_* in: "user" for agents
```

- **Host** (`BrowserExtensionHost`). This is a Perl script, like `nook-mcp`, with no logic of its own. The browser
  starts it and talks to it with length-prefixed JSON on stdin and stdout. The host keeps one long poll open to Nook
  for its next command, and passes the extension's own messages (hello, a side panel question, a command's result) as
  single requests. Without Nook it tells the extension "Nook is not running". When Nook comes back, the extension
  connects again by itself.
- **Hub** (`BrowserExtensionHub`). This is plain Foundation code that the core tests run on Linux. It tracks the
  browsers that are there, holds a poll for up to 25 s and then answers "idle", and queues commands for the right
  browser. It hands each result to its caller and times out a command nobody answers. A browser that has not polled for
  70 s is gone.
- **Tools** (`BrowserExtensionTools`). One definition per tool covers the name, method, schema, timeout, how its
  arguments are checked, and how its approval reads. `BrowserExtensionConnector` turns these definitions into Nook's
  `ToolSpec`s.
- **Side panel.** A question becomes `app.ask(…, in: conversation, reveal: false, note:)`, the same path the iPhone
  companion uses. The page in front goes along as a note that is never shown in the chat
  (`BrowserExtensionPanel.note`). The panel reads the conversation again every second while Nook answers.

## Developing

```sh
cd apps/browser-extension
npm test                       # lib/core.js, the manifest and id, the five languages (Node's test runner)
../../scripts/core-tests.sh --filter BrowserExtensionTests   # the Mac side: host, hub, tools
```

After you change the extension, click **Reload** on it in `chrome://extensions`. When Nook updates, it copies the new
version into `Browser Extension` the next time it starts.

The extension's own texts are in `_locales/{en,nl,de,fr,es}/messages.json`. The Mac side's texts are in
`apps/macos/Core/I18n+BrowserExtension.swift`.

## Limits

- **Chromium only.** Safari needs an app extension built with Xcode, and Firefox has its own native messaging
  locations and manifest keys. Neither is supported yet (see [`INTEGRATIONS.md`](INTEGRATIONS.md)). Safari and Firefox
  tabs can still be read with `read_browser_tab`.
- **Events from a script.** Clicks and keys are DOM events, not real input, because the extension has no `debugger`
  permission. Most sites accept them. A key's own effect (a new line, moving focus) does not follow by itself: Enter in
  a form field submits the form, and Tab moves to the next field.
- **One frame.** The page agent works in the page's main frame, not inside iframes.
- **Loaded unpacked.** The extension is not in the Chrome Web Store yet, so the browser loads it from Nook's folder in
  Developer mode. A Web Store build would get a different id, which would have to be added to `allowed_origins` in
  `BrowserExtensionHost.manifest`.
