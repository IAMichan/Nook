# Changelog

Notable changes to Nook, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org) with `-beta.N` pre-releases.

Every [GitHub release](https://github.com/IAMichan/nook/releases) also lists each merged pull request, grouped by label
(see `.github/release.yml`). This file is the short, human-written summary: when your pull request changes something a
user or contributor notices, add a line under **Unreleased**. When a release is published, the release workflow moves
the entries it shipped under its version (`scripts/changelog-release.py`); a stable release gathers its betas.

## Unreleased

### Added

- Coding agents can now use your chat apps directly through Nook's MCP: `chat_list`, `chat_read` and `chat_send` work
  with every chat Nook links (WhatsApp, Messages, Telegram, Slack, Teams, Signal and more; WhatsApp on Windows and
  Linux). Every message waits for your approval with the exact text, whatever rights the agent has. Together with
  `nook_chat_*` an agent can read a chat, ask Nook about it and send a reply, and an assistant in another app gets
  the same tools at the **Full** access level.

- The changelog keeps up with the releases by itself: once a release is public, the release workflow opens a pull
  request that moves the **Unreleased** entries it shipped under its version and merges it when `Check` passes. Entries
  merged while the release was building wait for the next one, and a stable release gathers its betas into one
  section (`scripts/changelog-release.py`).

- One composer for Nook's web surfaces: the browser extension's side panel now writes with the same composer as the
  Windows and Linux app (packages/web-ui). In the browser you can paste, drop or pick pictures to ask about, bring back
  an earlier question with Up, and stop an answer with Escape. `npm run package` in apps/browser-extension makes the
  Chrome Web Store zip, and the extension's descriptions now fit the store's 132-character limit.

- Automations in Nook Chat: ask "check my mail every morning at 8, tell me what happened and draft the replies" and Nook
  proposes a scheduled task you approve with one click. Each run is a conversation of its own with an overview and a
  ready reply per mail that needs one, so you only click Send; a notice says when it is ready. Nothing is sent or changed
  by the run itself. Nook's own tasks run without the switch for agent tasks, a morning overview the Mac slept through
  runs when it wakes, and you can also pick *Nook Chat* as the destination in Settings › Automation › Scheduled tasks.

- Nook as your personal secretary: automations work across everything Nook sees (mail, every chat app, calendar,
  reminders, pull requests, agents, connected services). Each run reports what is new since the last one and prepares
  every reply and action so you only approve or say what to change. Checks through the day can stay quiet until
  something new needs you, and *Set up personal secretary* (or asking for one in the chat) adds a morning briefing, a
  quiet midday check and an end-of-day wrap-up.

- Automations that start on a message: "as soon as Lisa writes on WhatsApp, prepare an answer" or "when a mail about an
  invoice comes in, add a reminder". Filter by app (every chat app Nook reads, Mail included), sender and words, with
  group chats optional; Nook reads the chat and prepares the reply and other steps for your approval. A source you keep on
  this Mac (Settings › Privacy) never starts one, so its messages never reach an external brain this way.

- Better mail in Nook Chat: replies go out as Mail's own reply to the message (same thread and account) instead of a new
  mail, also from the Chats tab; `inbox_mail` lists each message's id (so Nook can open, mark or answer exactly that
  mail) and takes `unread_only` and `limit`; drafts follow your earlier mail to that person and the sender's language.

- Nook Companion stays usable without your Mac: Nook's chats and the Chats tab are now kept on the iPhone with their
  last messages, so every tab reads while the Mac is off, asleep or out of reach. What you write still waits on the
  iPhone and goes as soon as the Mac is back. While offline, every conversation keeps an amber strip in sight saying
  that no new messages or updates come in and that what you send is not sent yet, and each waiting message says
  *Not sent yet · waiting for your Mac*. A chat the iPhone never kept says it opens once the Mac is connected, instead
  of loading forever. The Android companion does the same, and its chat messages now wait in the outbox too.

- The Android app is now the same companion as the iPhone app, with the same layout, look and words: once paired it
  opens on your Mac's tabs Nook, Agents and Chats, with what waits on you as cards, a session as its whole conversation
  in turns, approvals and questions above the composer (deny with a reason, Steer now or After this turn), New session,
  Nook's chat, the Chats tab (WhatsApp chats look like WhatsApp) and Settings. While it is open it follows your Mac live.
  Nook on the phone itself is in Settings. Review a session's changes and comment on lines, work through pull requests
  (review, merge, work on this), send pictures and dictate, as on the iPhone (see docs/COMPANION.md, *Android*).

- Nook in your browser wears your look: the extension's side panel now draws Nook's own design (the same colors, radii,
  type scale and composer as the main window) and follows the theme, accent, custom colors, System / Light / Dark and
  density you chose in Settings › Appearance, within seconds of a change. The strip on a page while Nook acts follows
  the theme too.

- Nook Companion's Agents list reads like the Mac's: the search and a view menu on one row, and sessions grouped by
  project (on by default), each folder folding away and its **+** starting a new session right in that project. A long
  press on a session offers Send a message, Stop and New session here, so you steer and start agents from the phone in
  a tap or two; the New session sheet opens on what your Mac offers at once, and a session you just started opens
  without a "This session is gone." in between. Approving or answering clears the card at the tap, an agent's
  words reach the phone twice as often, and the Agents list redraws only the rows that changed.

- Share your look: Settings › Appearance › Share your look saves your accent, appearance, themes (an imported VS Code
  theme travels along), custom colors, diff colors, density and Nook's face as one `.nooklook` file. Someone who imports
  it gets the same look and feel; nothing else of theirs changes.

- Nook in your browser: an extension for Chrome, Brave, Edge, Arc and Vivaldi. Click Nook's icon to ask Nook about the
  page you are on in the browser's side panel. Nook Chat and every coding agent can also read your tabs as you see them
  and open, click, type and press keys there (`chrome_*` tools), always after your approval. You can switch Nook off per
  site or pause it in the whole browser, and a strip with Stop shows while Nook acts on a page. Set it up in Settings ›
  Editor & browser › Nook in your browser (see docs/BROWSER-EXTENSION.md).

- CLIProxyAPI hubs as a source of limits: add a hub in Settings › Usage & costs (its address and management key, kept
  in the Keychain) and its accounts show in the usage modal and in Settings with their state, cooldowns, request
  counts and the Claude and Codex limits the hub saw on its requests. Nook only reads what the hub reports about its
  own accounts and never asks it to call a provider with an account's token. Plain http is accepted only for this Mac
  and the local network (see docs/INTEGRATIONS.md).

- Option previews under an agent's question options (mock-ups, code snippets, ASCII layouts) now always show in the
  code font in Nook and on the iPhone, and "Reply" in the footer of an agent's final answer (or its long-press menu on
  the phone) puts the answer or your selection from it as a quote at the top of the composer, shown as an inset card
  when sent.

- The "Viewed" checkmarks on a pull request's Code tab now follow GitHub's own checkbox: a file you mark viewed in
  Nook (or on your phone) is marked viewed on GitHub too, and a file you ticked on github.com shows as viewed in Nook.
  A file that changed since you viewed it shows as changed again. Other forges keep the marks on your Mac, because
  their APIs have no viewed state (see docs/INTEGRATIONS.md).

- Close several pull requests at once from the selection bar, with an optional comment that is posted on each before
  it closes. When some do not close, the note names each one and says why; the rest still close.

- Cloning a repository from the new session box now runs in the background: the box is free again at once, and a
  quiet notice in the corner shows git's stage and percentage, with Hide and Cancel. When it is done a note offers
  Open, and the box that started it switches to the new project by itself.

- Nook's browser can open a local dev server that uses its own HTTPS certificate (`vite --https`, mkcert, a
  self-signed one). For `localhost`, `*.localhost`, `*.local`, `127.0.0.1` and private network addresses, a bar above
  the page asks whether to trust that certificate for this session or always, instead of the page silently failing.
  Public sites are never offered this, and only you can approve it, not an agent. Settings › Editor & browser lists how many
  you always trust and can forget them.

- When one of Nook's own databases (`nook.sqlite`, `chats.sqlite`, `runs.sqlite`) cannot be opened, Nook says so
  instead of quietly running without it: which file, why, and what to do. A damaged file is moved aside under a dated
  name (never deleted) and a fresh one takes its place; the notice shows the copy in Finder and copies the command
  that recovers what is still readable. A file that is out of reach for another reason (a full disk, a lock) is left
  where it is.

- Settings › General › "Hold ⌘Q to quit" (off by default): a quick ⌘Q shows a hint instead of quitting, and holding
  it for a moment quits. Quit from a menu, logging out and restarting are never held up. Works with the notch off.

- OpenCode 2.0.18 and newer now runs through its own server (`opencode serve`) instead of ACP. Its questions show
  with their options in place of the composer, "Deny with reason" reaches OpenCode with your words without stopping
  the turn, and the effort level picks the model's variant. Sessions of the same account share one server, which only
  listens on this Mac and stops when no session needs it. An older OpenCode, or a server that does not start, keeps
  using ACP. Settings › Agents › "OpenCode via its own server" turns it off.

- OpenTelemetry export, in Settings › Maintenance › Diagnostics: give each signal (traces, metrics, logs) an OTLP HTTP
  endpoint, with optional headers kept in the Keychain and a Test that sends an empty export. Nook then sends its own
  agent turns (agent, model, outcome, duration, tokens), scheduled task runs and launch time, without prompts, answers
  or file contents, and tells every coding agent it starts about the same receiver in that agent's own settings
  (Claude Code, Codex, Gemini CLI, OpenCode and Grok export on their own). Standard `OTEL_EXPORTER_OTLP_*` variables
  override the fields and show as "Set by environment". Off until you set an endpoint.

- Nook Companion runs on the iPad. With room, the tabs become a split view: a section's list on the left (sessions,
  chats, Nook's chats, pull requests) and what you opened on the right, with a session's files, terminals and pull
  requests in an inspector beside it. A hardware keyboard gets shortcuts (⌘N new session, ⌘[ and ⌘] the previous or
  next session, ⌘F search, ⌘K find a session, ⌘1… a section, ⌘↩ send), and pictures, a file, links and text can be
  dragged into a composer. In Slide Over or a narrow window, and on the iPhone, the layout stays the phone's.

- While a coding agent works through a task list, the step it is on now (say, "Phase 2: agent parity") also shows in
  the Tasks strip above the composer, with a soft shimmer, so you see which phase runs without scrolling to it. This
  holds for every coding agent that keeps a task list, also in sessions Nook reads from their transcript.

- Double Tap suggests what Nook can do with what is in front of you: under its field, one-click chips such as
  **Improve this**, **Translate this into English** and **Explain the selected text** for a selection, **Write a
  reply** for an empty message box, **Fill in the form** for a form with empty fields, and **Put this in my calendar**
  or **Summarize this window** for the window behind it. What you asked lately comes back as a chip too. Settings ›
  Assistant › Double Tap can turn them off, which also forgets those requests.

- Taking over a task with mouse and keyboard got smarter. Every step now returns a fresh read of the window, so Nook
  needs fewer rounds and notices when a step changed nothing. Reading again really reads again, so a loading page
  is seen once it has loaded. The same steps asked for a third time are refused, so Nook tries another way. Nook can
  use the menu bar, scrolls an off-screen button into view before clicking it, and knows the browser shortcuts. Large
  windows are shrunk before Nook looks at them so its clicks land where it aimed. A task started from Nook's own panel
  sees the window behind it. Typing a line break into a field, or pressing Space on a focused "Place order" button,
  now waits for your yes like the click would.

- Settings › Maintenance can copy a redacted diagnostics report: versions and set-up facts with secrets, mail
  addresses, phone numbers, IBANs, link queries and your name in file paths taken out. Nothing is sent anywhere.
  Nook also has a shared last-synced and offline line, and plural-aware texts, for every surface.

- A new session remembers your choices per folder: its agent, account, model, effort, mode, permissions and whether
  it works in a worktree come back whenever you start in that folder, instead of the choices you last used elsewhere.
  A folder you have not used yet starts with your last choices, and what a project sets in Settings still wins. Also
  for sessions started from the iPhone or by an agent, and in the Tauri app.

- Ask Nook about any text you select in Nook: a message in the Chats tab, an agent's answer, a page in Nook's
  browser, the terminal. A small bar above the selection answers, explains or translates it in a card right there,
  with room for a follow-up and a way to continue in the chat (Settings › Assistant › Ask about selected text).

- Chats show what happened to a message, in every chat app that says it: a message deleted for everyone keeps its
  place as "This message was deleted" (or "You deleted this message"), and an edited message says "Edited" beside its
  time. WhatsApp now also follows edits and deletions made on a phone, and Telegram and Slack show their edits.

- An Actions page beside Pull requests under the Agents list (the play icon): a repository's GitHub Actions runs,
  newest first under a heading per day, filtered by workflow (CI, Promote, Release…) and by state (running, failed).
  A run opens with its jobs, each job's steps and log, and re-run (all or only the failed jobs) or cancel. Runs that
  are still going are followed live. On the Mac and in the Tauri app.

- The session list on the left of the Agents tab can be put away beside a session, with the cross at the end of its
  title row or the new left toggle in the session's header (list, bottom panel, side panel); it is remembered.

- Downloaded builds (the release .dmg/.zip) update themselves from GitHub Releases through the footer's Update
  button: Nook downloads the release's .zip, checks its Ed25519 signature against the key it carries, and installs it
  (`docs/UPDATES.md`, "Release builds"). The release workflow signs the .zip when `NOOK_UPDATE_SIGNING_KEY` is set.
- An update that crashes the new build before it has run for a minute is rolled back on the next launch: Nook keeps
  the previous app and a snapshot of `nook.sqlite` until the new build proves healthy, puts both back, and says so
  (`docs/UPDATES.md`, "Rollback").
- Push notifications for everyone, through the relay: the Mac seals each notification with the phone's pairing key,
  the relay forwards it to Apple with Nook's APNs key (opt-in Worker secrets, `POST /v1/push`, rate limited, no
  logging), and a new Notification Service Extension on the iPhone opens it. The own-`.p8` path stays
  (`docs/COMPANION.md`, "Push through Nook's relay").
- A short demo video at the top of the README (`docs/assets/nook-demo.mp4`, with a GIF preview), made with the
  `nook-video` skill, which can now render landscape clips (`--size`).
- Area labels (`area: macos`, `area: tauri`, …) that are added to pull requests automatically, defined in
  `.github/labels.yml`.
- Release notes grouped by label, and this changelog.
- Dependabot updates for the Tauri app (Cargo and npm) and `nook-chatd` (Go modules).
- `CODEOWNERS`, `.editorconfig`, and `.gitattributes`.
- A *Related issues* section in the pull request template.
- Agent transcripts read more clearly: the thought behind the running step shows above it, a message sent while
  the agent worked splits its turn's fold ("Continued for 20s"), a stopped turn stays open ("You stopped after 12s"),
  compactions, API errors and usage limits stay in sight, and a command opens to its output.
- iPhone companion: repeated commands are carried out once (an LRU receipt store), protocol and app versions with
  "Update Nook on your Mac" / "Update the app" banners, "Why can't I connect?" on the phone and *Test relay* on the Mac,
  per-phone scopes chosen at pairing, one phone paired with several Macs, a local redacted *Copy diagnostics* log, and
  shared golden protocol fixtures checked from Swift, Rust and the relay.

### Fixed

- Merging a GitHub pull request in a repository whose ruleset only allows squash (or rebase) no longer fails with
  "Merge commits are not allowed on this repository": Nook now reads the merge methods the base branch's rulesets
  allow and picks one of those, on macOS and in the Windows, Linux and Android app.
- Chats list rows now follow their chat: a chat that moved to another group no longer keeps its old line and time, and
  shows as selected.
- Writing in an old chat no longer marks all its messages unread, in every chat app.
- Sending a message no longer brings back the unread bar above the answer field for a chat you read on your phone, in
  every chat app.
- Two different chats of one name in Teams, Slack, Telegram or a chat helper network are now two rows with a short mark,
  and an answer reaches the right chat. Answers in a row with two threads to one person go to the newest.
- A Teams message with several files says how many there are.
- A picture that never arrives shows as a named file that opens its app instead of an empty tile. Teams files in
  SharePoint or OneDrive show that way at once.
- Xcode 27 opens `Nook.xcodeproj` and `NookCompanion.xcodeproj` again: XcodeGen no longer lists a group or file in two
  groups, which Xcode 27 refuses with "is a member of more than one group".
- Scrolling through every chat of every app in the Chats tab no longer stutters: a chat picture that comes in redraws
  only the faces instead of the whole tab, app icons are drawn once into a small bitmap, the row's hover button is
  made only under the pointer, and a chat that changes no longer makes every other row again.
- A coding agent that `cd`s into a subfolder no longer shows up as two chats in Agents (one under the subfolder,
  one for its process): the session stays in the folder it started in, and the process scan matches it by process
  and parent folder (macOS and Tauri).
- Sending a mail draft from the chat no longer fails with "error -1712" when Mail was not running: Nook starts Mail
  first and gives it time to send. Mail errors are now shown in your language, and a draft can send from the account
  you named ("vanuit mijn gmail").
- A mail draft (or a chat message) is the only step to approve: Nook no longer adds a second "takes over" proposal
  for the same message, and asking for a change replaces the open draft instead of stacking a new one under it. The
  "only on this Mac" notice for Contacts no longer shows when the request already gave the address.
- The pull request list loads much faster and no longer looks like it is always loading: the quick refresh reads only
  the open pull requests, the closed ones and watched organizations follow in the background every few minutes, and
  only a refresh you ask for shows a spinner.
- "Post this on LinkedIn" and other requests to post on a site that don't start with a known verb are taken over
  again instead of being answered with text.

### Changed

- Connecting Nook's browser extension is one click: Nook's host now lets in the extension from the Chrome Web Store
  (before, only the unpacked build could connect), **Connect** opens its store page when no browser has it yet, and
  Settings recognizes it by itself: connected, found and connecting, or switched off.
- Nook Chat answers sooner: an API brain gets 5 s instead of 8 s to plan a question before Nook falls back to its own
  search, the connection to the brain is opened while Nook prepares (also with the chat open), and a retry (a chart, a
  corrected detail, an empty answer) reuses what was already looked up instead of planning and searching again.
- Your answer style and a space's instructions now reach the brain as your own instructions instead of inside the
  context marked as third-party data, so they are followed; the prompt names the date line correctly ("Now").
- Nook in your browser is much faster and answers better: a question from the side panel takes the page's text (and
  what you selected) along, so Nook answers about the page right away instead of first reading it with a tool. Nook
  pushes its answer to the side panel as it writes it, as live as in Nook's own window, instead of the panel asking
  every second. Commands on a page take one trip instead of two, clicks no longer wait a fixed time, and finding the
  buttons and fields on a long page is quicker. The page's text goes only to a brain that may see your browser.
- Nook in your browser follows your privacy settings: a page in your browser is part of your screen, so it stays on
  your Mac whenever the screen does (Strict, or by hand). The model you picked for screen work then reads the page,
  answers itself or gives your external brain a short, filtered note, and fills in forms on the page itself, so what
  you fill in never goes through the cloud. The side panel says how Nook answered.
- Watch Nook work in your browser: a cursor glides to what Nook clicks, types in or scrolls, with a badge under it that
  says what it does ("Klikt · Verzenden", "Typt", "Scrolt"). Nook also clicks more surely and needs fewer steps: every
  action reports what the page shows now, a cookie banner or dialog in the way is named with its buttons, buttons in
  web components are found, and a link that opens a new tab takes Nook along.
- While Nook works on a page, your own clicks and keys there wait, so you never get in each other's way (scrolling and
  Stop stay free). Nook keeps working in its tab while you use another one, at full speed. When a page asks to sign
  in, Nook lets you type and click, and goes on by itself once you are in; it never sees your password.
- Nook's answers stream into the iPhone and Android companions as Nook writes them: the Mac sends the open
  conversation by itself over the live connection instead of the phone asking every second and a half. Only Nook's new
  words travel, a slow connection gets one catch-up update instead of a growing backlog, a reconnect fetches only what
  was missed, and a lost update repairs itself.
- Every tooltip looks and feels the same: Nook's dark card, shown after a short rest instead of the system's gray tip
  after a second. Only the items inside a menu keep the system's tooltip, since macOS draws those itself.
- The side panel on the right opens its tabs faster: a pull request shows its page as soon as it is read instead of
  waiting a third of a second first, switching tabs shows the new one at once instead of animating both, the Changes
  tab lists files as soon as git knows them (before the slower branch comparison) and reads git once when it opens, the
  Pull request tab's list no longer waits for git, and a file you come back to in the File tab shows at once. The pull
  request page, its list and the Changes tab are drawn again only when what they show changed, not whenever something
  else in the window does, and a panel that opens on a tab far down a long tab row scrolls that tab into view.
- Every tab of the side panel on the right was gone over:
  - **Outputs and Subagents** redraw only when what they show changed (one streaming subagent redraws only its
    card), read pictures off the main thread, and start with the same bar as every other tab. The subagents' progress
    stays in view while the list scrolls.
  - **Changes** says "Reading git…" while it reads, instead of "The agent is working…", and "Nothing changed here." for
    an empty branch or commit. A commit that cannot be found no longer spins forever.
  - **File** no longer joins the whole file into one string on every redraw and every key while you edit. A file that
    is gone offers to open another.
  - **Browser** checks the folder's servers all at once and only while you can see the window. Its bar of servers is
    there at once when you come back to the tab, and the empty browser's note sits in the middle of the tab.
  - **Terminal**: an agent's command does its output work once per update, with the same spacing under its bar as the
    other tabs. A project script with a preview opens its page as soon as the server answers, instead of after a fixed
    four seconds (often too early, or needlessly late).
  - **Artifact** starts with the same bar as every tab: the artifact's title, a spinner while it loads, and the
    button that opens it in your browser.
  - **⌘F in a diff** reads several files at once instead of one after another, so the first match shows sooner on a
    large branch.
  - Git's slower half (branches, the comparison with the base) runs at full priority while a panel waits for it or you
    press refresh; the polling in the background stays at low priority.

- The tabs at the top left of the main window no longer carry counts, dots or other status marks. The notch's tabs keep their amber count of agents that wait for you.
- Nook works less in the background. A running check or pulse no longer redraws the whole window at the display rate. Polling pull requests costs no GitHub limit when nothing changed, and a slow forge no longer holds up the others. Settled pull requests, idle folders and agent pages nobody looks at are read less often or put away. Opening a long session no longer waits for saves.
- Much lighter with many agents at work: the working dots, halos, spinners, the shimmer on the running step, Nook's
  writing dots and the music bars now run in Core Animation instead of being drawn frame by frame on the main thread.
  Each of them used to make the whole window lay itself out again on every frame, over a hundred times a second with a
  dozen sessions running; now they cost the main thread nothing per frame. Nook himself is drawn without the separate
  hosting view that did the same, and looking a session up by id no longer walks every session.
- A smoothness and UX pass: Escape closes the notch, the notch no longer opens while you sweep past it, toasts stay off the composer, and lists (Agents, Nook, palette, search, terminals) work with the keyboard and the pointer alike. Drafts, stashes and carets survive switching sessions, copy buttons all behave the same, Nook chat streams with far less redrawing, and Settings saves and confirms where it did not.
- Smoother throughout: typing in the Nook chat and under a terminal or past agent session draws only the composer,
  not the conversation above it; starting and stopping a scroll no longer redraws every message; stickers and GIFs
  decode off the main thread; the notch opens sooner (shorter hover wait and open spring) without the hover's curve
  taking over the open animation. Pull requests keep their list (and where it was scrolled) when one opens or closes
  beside it, switch tabs at once, reuse a diff's colors, and poll without redrawing the page. The main window holds
  its animations while you resize it or it goes into or out of full screen. Older sessions load their timeline in the
  background, transcript rows and chat text are drawn again only when they change, @ mentions and pasted pictures no
  longer block typing, the notch redraws only its ring and mood as agents work, Double Tap and the UI driver read
  other apps off the main thread, and typing in Settings redraws only the field.

- Every side panel is one shared panel: the lists of the Nook, Agents and Chats tabs, a command's terminal, the tool
  panel, a turn's diff or a file, a pull request beside its list, an artifact beside its app and the docked session
  panel get the same line, gap, 32 pt header and cross to close. A diff or file and the tool panel take turns instead
  of stacking, and the docked session panel moved to the far right so the panel toggles above it keep their place.
- What the side panel's tabs show lines up: each starts with the same 34 pt bar (browser, terminal, changes, local
  servers, file), a tab with nothing in it (plans, file, artifact) says what to do instead of staying blank, a pull
  request goes back to the list from its own top bar instead of an extra row, and a session's changes can be read
  again like a folder's.
- A pull request opens beside the list: half the page, its edge dragged wider or
  narrower (remembered), and a button on its tab line that makes it fill the page.
- A pull request's page is redesigned: a one-line title, segmented tabs, its tabs as `#number` whose mark turns
  into a close button, refreshing in the ⋯ menu, and a timeline with each commit as its own entry.
- A pull request's Summary opens with whether it can merge: conflicts, checks, reviews and a branch behind, one line
  each with its state's color, and a click on a line goes to what needs you. Failing checks are listed first.
- `docs/WERKRUIMTE-AGENTS.md` is now `docs/WORKSPACE-AGENTS.md`.

## [0.1.0-beta.1] - 2026-10-23

First public beta of the macOS app, published from `.github/workflows/release.yml`.

[0.1.0-beta.1]: https://github.com/IAMichan/nook/releases/tag/v0.1.0-beta.1
