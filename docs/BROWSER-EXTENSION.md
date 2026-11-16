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

## Nook's look in the browser

The side panel wears the same look as Nook's main window. It uses the same tokens (`NookPalette`), radii, spacing and type
scale as `NookTheme`. When it connects, and again whenever the panel opens, comes back into view, or every 15 seconds
while it shows, the extension asks Nook for its `look` (`BrowserExtensionLook`). The look holds System / Light / Dark,
both palettes of the chosen themes (an imported VS Code theme too), the colors set one by one in Settings › Appearance ›
Colors, the accent as drawn, the diff colors and the density. The panel sets these as CSS variables, so a theme change
in Nook shows in the browser within seconds. The extension keeps the last look, so the panel draws Nook's colors at once,
also while Nook is not running. The strip on a page while Nook acts takes the same theme's menu color and violet.

Only `#RRGGBB` values are taken (`cleanLook` in `lib/core.js`), so a value can never become other CSS. A Nook that does
not know `look` yet leaves the panel in Nook's own theme.

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

### Double Tap in the browser

Double Tap (tap right ⌘ twice) uses the extension too, without the chat tools and without its side panel open. In a
Chromium browser whose extension is connected, it asks the page agent in one call what the tab in front holds (`form`:
every fillable field with its label, value and focus, the text around the fields, the buttons that could send the form,
and the selection). The field's suggestions and the line above it ("Google Chrome · 4 empty fields · Via your browser")
come from that, and "fill in the form" fills every field in one more call (`fill`), with React-safe value setters, and
puts the cursor back where it was. Undo writes the old values back; Send clicks the form's own button, only from the
result card. Both commands go through the same brakes as every other: while Nook is paused in that browser, or the site
is switched off in the side panel, Double Tap leaves the page alone and says so. Which connected browser is the one in front is
decided by process, not by name: the browser starts the extension's host, the host's client id begins with its pid,
and Nook checks that the host runs below the app in front (`ProcessTree`). So Chrome and Arc (which often says hello as
Chrome) running side by side each get their own form, and a browser without the extension never borrows another's.
When the extension is not connected
(or the page is one the browser keeps to itself), Double Tap reads and fills the page through the accessibility layer as
before (`Services/DoubleTap/DoubleTapBrowserLogic.swift`, `DoubleTapBrowserTests`).

The service worker keeps its port to Nook while the browser runs, side panel open or not. When the browser has put the
worker to sleep, switching to the browser window or to another tab wakes it (`windows.onFocusChanged`,
`tabs.onActivated`, `tabs.onUpdated`), and it connects again before you tap; a half-minute alarm (the shortest a browser
allows) keeps trying in between.

## Watching Nook work

While Nook acts on a page, a cursor in Nook's color glides to what it clicks, types in, chooses or scrolls, and a badge
under it says what it does, in your language: *Klikt · Verzenden*, *Typt · Lisa de Vries*, *Scrolt ↓*, *Drukt op
Enter*. A click shows as a short press and a ripple. On the next page the cursor goes on from where it was. It is
drawn in a closed shadow root, never takes a click itself, and does not glide when you asked for reduced motion.

## Your hands and Nook's

- **Nook is not in your way, and you are not in Nook's.** While Nook acts on a page, your own clicks, keys, typing,
  pasting and mouse moves on that page wait (`page/presence.js` holds back trusted input in the capture phase; Nook's
  own events come from a script and pass). Scrolling and looking stay free, and so does the strip's **Stop**. A click
  you try anyway nudges the strip: *Nook is working here; your clicks wait until it is done.* Your hands are free again
  12 seconds after Nook's last action, at once when its answer in the side panel is done, or when you press Stop.
- **Work in another tab meanwhile.** Nook keeps working in its own tab while you use another: a command goes to the tab
  Nook works in, not the one in front. In a tab in the background the cursor does not glide (nobody sees it, and the
  browser draws nothing there), so every step is done at once. A page Nook opens while you are elsewhere opens beside
  yours instead of taking your view, and a screenshot of a background tab is refused rather than switching your tab.
- **Signing in is yours.** When a page asks to sign in (a password or one-time-code field you can see, after any of
  Nook's actions, or when Nook would type into such a field), Nook steps aside: the tab comes to the front, the strip
  says *Sign in on this page; Nook goes on by itself once you are in*, and your clicks and keys work as always. Once the
  sign-in fields are gone and the page settled (or you press **Continue**), Nook goes on with its task by itself. It
  waits up to 5 minutes and never sees what you type. Meanwhile the extension gives that command more time in Nook
  (`{"kind": "extend"}` to `BrowserExtensionHub`, only for the browser that runs it, at most 6 minutes at a time).

## Quick, and sure of where it clicks

- **One step at a time, no extra looks.** After every click, key and typing, the extension waits until the page has
  done what the action caused (a new page loading, a link that opened a tab, a menu or results appearing, never a
  fixed wait) and sends what the page shows now and what can be used in view, with refs. `chrome_open` and
  `chrome_scroll` do the same. Nook takes its next step from that, without a `chrome_find` round in between.
- **The right element.** By text, what you can see wins: an exact name before one that starts with it before one that
  contains it, in view before off screen, a button or link before a label. Refs, selectors and text also reach into
  web components (open shadow roots).
- **Something in the way.** Before a click the extension checks what is really under the cursor. When a cookie banner,
  dialog or sticky bar covers the target, Nook hears so, with that layer's buttons and their refs, so it can accept or
  close it first.
- **Like a person.** Pointer and mouse events land where the cursor is, short text is typed in a few quick steps so
  search fields and suggestions react, and a link that opens a new tab moves Nook there.

`test/agent.browser.test.js` runs the page agent in Chromium on a checkout page when Playwright is installed.

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
- **Your privacy settings, in the browser too.** The extension follows what you set in Nook's main window. A page in
  your browser is part of your screen: whenever the screen stays on this Mac (the Strict privacy level, or
  **Settings › Privacy** by hand), the browser extension does too (`PrivacyLevel.keptOnMac`), and you can also keep only
  the browser here. While it stays here, an external brain never gets the page's text or the `chrome_*` tools, and
  neither does a coding agent. With a model on this Mac picked under **Settings › Brain › Screen work**:
  - A question about the page goes to that model (`AppModel.pageWorker`). It reads the page on this Mac and either
    answers itself, or (with "It gives Claude a short, filtered note") writes the external brain a note with only what
    the question needs (`PrivateBrief`). The note is filtered at the strictest level before it leaves: secrets, mail
    addresses and phone numbers go out first. The external brain answers from it, with its own sources.
  - A request to act on the page (fill in, type, click, choose, send; `ScreenBrain.actsOnPage`) stays with the model on
    this Mac. It has the page and the `chrome_*` tools, fills in the form itself, and every action still waits for your
    approval. What you fill in never passes through the cloud.
  - The side panel shows how Nook answered under the answer, as on the Mac ("read on this Mac…").
  Without such a model, only the page's title and address go along, and Nook says it cannot read the page.

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
- **Side panel.** A question becomes `app.ask(…, in: conversation, reveal: false, note:, page:)`, the same path the
  iPhone companion uses. The page in front goes along as a note that is never shown in the chat
  (`BrowserExtensionPanel.note`). When Nook may use the site (not paused, not switched off), the extension also reads
  the page's text and the user's selection as the question is asked (at most 16,000 characters, and only when the page
  answers within 1.5 s). That text goes to the brain like a dropped file (`ReplyContext.page`), so Nook answers about
  the page without first spending a round on `chrome_read`. It goes only to a brain that may see the browser
  extension; see "Your privacy settings, in the browser too" for what happens when it stays on this Mac.
- **Composer.** The side panel writes with Nook's shared web composer (`packages/web-ui`), the same one as the Tauri
  app: Return sends, Shift+Return is a new line, Up in an empty field brings back an earlier question, Escape stops the
  answer, and pictures can be pasted, dropped or picked. The pictures go with the question as `images`
  (`questionImages` in `lib/core.js`: PNG, JPEG, GIF or WebP, at most 10); the Mac scales and encodes them as every
  picture it sends a model (`ImageAttachment`). Documents are not taken in the browser.
- **Live answers.** The side panel follows its conversation: Nook pushes every change (at most every 100 ms) as a
  `{"kind": "chat"}` line on the host's poll (`BrowserExtensionHub.push`, a newer change replaces one still waiting),
  and the panel draws it when it changed (`revision`). The panel asks itself only every few seconds in case a push got
  lost, and every second with an older Nook that does not push (`live` is false).

## Developing

```sh
cd apps/browser-extension
npm test                       # lib/core.js, the manifest and id, the five languages, the page agent in Chromium (Node's test runner)
npm run build                  # the composer into ui/composer.js (once: npm ci in packages/web-ui)
npm run package                # the Chrome Web Store zip in .scratch/, without the manifest's key
../../scripts/core-tests.sh --filter BrowserExtensionTests   # the Mac side: host, hub, tools
```

The composer's sources are `composer/` here and `packages/web-ui/src`. The built `ui/composer.js` is checked in, so the
Mac app carries a working extension without a build step and the extension's folder holds no `node_modules` (the app
copies all of it). Run `npm run build` after changing either and commit the result; CI fails when it is not up to date.

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
