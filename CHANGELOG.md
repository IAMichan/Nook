# Changelog

Notable changes to Nook, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org) with `-beta.N` pre-releases.

Every [GitHub release](https://github.com/IAMichan/nook/releases) also lists each merged pull request, grouped by label
(see `.github/release.yml`). This file is the short, human-written summary: when your pull request changes something a
user or contributor notices, add a line under **Unreleased**. At release time that section becomes the new version.

## Unreleased

### Added

- The "Viewed" checkmarks on a pull request's Code tab now follow GitHub's own checkbox: a file you mark viewed in
  Nook (or on your phone) is marked viewed on GitHub too, and a file you ticked on github.com shows as viewed in Nook.
  A file that changed since you viewed it shows as changed again. Other forges keep the marks on your Mac, because
  their APIs have no viewed state (see docs/INTEGRATIONS.md).

- Close several pull requests at once from the selection bar, with an optional comment that is posted on each before
  it closes. When some do not close, the note names each one and says why; the rest still close.

- Cloning a repository from the new session box now runs in the background: the box is free again at once, and a
  quiet notice in the corner shows git's stage and percentage, with Hide and Cancel. When it is done a note offers
  Open, and the box that started it switches to the new project by itself.

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
