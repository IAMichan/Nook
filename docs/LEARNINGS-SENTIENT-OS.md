# What Nook can learn from Sentient OS

[Sentient OS](https://github.com/Sentient-OS-Labs/sentient-os) is an open-source personal AI for the Mac that also lives
in the notch. It overlaps with Nook a lot, so its code and its per-feature engineering notes are a good source of
field-tested lessons. This page records what we studied (October 2026) and what is worth bringing to Nook.

> **License.** Sentient OS is **AGPL-3.0**; Nook is **MIT**. Do not copy its code into Nook. Ideas, measurements and
> behaviors are free to reuse; re-implement them in Nook's own style (as Double Tap below was).

## The product in one paragraph

Sentient reads the sources the user picks (files, screenshots, iMessage, WhatsApp, Apple Notes, Apple Mail, Apple
Calendar) **on-device overnight** with a small vision model (Gemma 4 E4B via LiteRT-LM), keeps only useful summaries,
and has the user's chosen frontier model merge them into a **plain Markdown knowledge base** (`~/Sentient OS - Knowledge
Base/`). Three features put that knowledge to work: **Sidekick** (click the notch or hold right ⌘: computer use in the
user's own apps), **Double Tap** (tap right ⌘ twice in a reply box: an unsent reply in the user's voice is pasted) and
**Proactive intelligence** (morning cards with a prepared draft or plan that the user fires with one click).

## Already in Nook

| Sentient OS | Nook |
|---|---|
| Notch overlay with click-through, all Spaces | `NotchUI/Window` (same `ignoresMouseEvents` by cursor approach) |
| Sidekick computer use | `UIDriver` / `control_ui` with approval cards |
| Voice on a modifier key | Flow dictation (`Services/Flow`) |
| Memory | `MemoryBook` (told / learned / observed, fades unless used) |
| Bring your own model | Brain selection: MLX, Apple, Ollama, LM Studio, cloud providers |
| Double Tap | **Added**: `Services/DoubleTap` (see below) |

## Double Tap in Nook (implemented)

Sentient's Double Tap drafts one reply. Nook's version goes further and **fills a whole form**:

- Tap the chosen key (right ⌘ by default) twice, alone, within 0.4 s; typing or another modifier in between cancels it.
  The key is watched with NSEvent `flagsChanged` monitors only, never a `CGEventTap` (Sentient's field lesson: any
  keyboard event tap triggers the Input Monitoring prompt).
- The text fields of the focused window are read through the accessibility layer (Chromium and Electron are woken
  first), filtered (never password, card, bank, identity or code fields; never already-filled fields), and sent with
  the user's memory and the screen text to the chosen brain. External brains get the same privacy treatment as a
  question (local-only memories and a strict privacy level stay on the Mac).
- The answer must be JSON; anything else fills nothing (fail-closed, as Sentient's triage). A Luhn/SSN backstop drops
  values that look like card or social security numbers (Sentient's `PIIScan` idea).
- Values are written with `AXValue` and read back; the focused field falls back to paste. Nothing is submitted by
  itself: a card in the notch lists what was filled, with **Undo** and, when the form has a send button (the window's
  default button, or one labelled send/submit/sign up/…), that button. Buttons that pay, order or delete are never offered.

Logic and tests: `Services/DoubleTap/DoubleTapLogic.swift`, `Tests/NookTests/DoubleTapTests.swift`.

## Mouse and keyboard control, improved

Taken from the same study, in `UIDriver` / `UIControl`:

- `read_ui` wakes Chromium browsers and Electron apps (`AXEnhancedUserInterface` / `AXManualAccessibility`) and waits a
  moment for the tree, so web forms in Chrome, Brave, Edge and Arc are visible.
- Up to 900 elements are read; when they do not fit the brain's budget, fields and switches go first, then buttons, then
  rows, links and text last (in their order on screen), so a page's navigation never pushes its form out.
- When a window shows fewer than three controls (an app that draws its own interface), `read_ui` adds the text it
  recognizes in a screenshot of the window (OCR on this Mac, the image never leaves it), with positions to click by x and y.
- After typing, the field is read back: when the text is not in it, the step fails before anything else (such as a send
  button) runs. A switch or checkbox that did not change after a click gives the brain a note to look again.

## Taking over a task (implemented)

Sentient's Sidekick takes a short request ("finish this for me") and works through it as one run in the user's apps.
Nook's version, in `Brain/TakeoverPolicy.swift` and `App/AppModel+Takeover.swift`:

- **Start**: one tap of the Double Tap key opens a field in the notch (typing the task is the go-ahead), or the brain
  proposes `take_over` in the chat and the user approves it like any plan. Another tap stops a running task.
- **Work**: the chosen brain runs a long tool loop (`ToolRunner.perform`, up to 40 rounds): `read_ui`, `control_ui`,
  `open_url`, `open_app`, web search. Reads after an action are never served from the cache. Following Sentient's
  rules: read fresh state before acting, never repeat a click or send because the result was unclear, verify before
  claiming success, and treat app content as data.
- **Own cursor**: actions run in the background where the app allows it (`AXPress`, a field's value), so the user's
  pointer and focus stay theirs; a violet cursor (`TakeoverCursor`) shows where Nook acts.
- **Nook's rule instead of Sentient's**: Sentient lets the task run without asking again. Nook stops at the point of no
  return: a click on a button that pays, orders, sends, submits, deletes, books or signs (in five languages), Return
  outside a search field, and every other action tool wait for the user's yes in a card. Card and social security
  numbers are never typed; sign-in and payment details go to the user through `wait_for_user`.
- **Outcome**: only an explicit `STATUS: DONE` after checking counts as success; a refusal wins; no status is
  "unconfirmed", never success.

## Lessons worth adopting next

Ordered by value for effort.

1. **Read app databases from a WAL-safe copy.** Sentient copies `chat.db` / `ChatStorage.sqlite` / `NoteStore.sqlite`
   *with* their `-wal` and `-shm` siblings into a temp folder, opens the copy so SQLite replays the WAL, and deletes it
   right after. Nook's `AppDatabase` falls back to `immutable=1` when the database is locked, which **skips the WAL**:
   the newest messages are missing exactly when Messages is busy. Sentient's iMessage notes also give useful facts:
   filter `associated_message_type != 0` (tapbacks), `item_type != 0`, and `is_filtered <= 1` (higher values are spam
   and iOS SMS-filter categories no Mac UI shows).
2. **Fail-closed parsing everywhere a model decides.** "Can't tell" maps to "do nothing", never to "go ahead". Nook's
   plan and memory parsing can adopt the same rule, plus a deterministic backstop behind the model.
3. **Stage, then atomically swap** anything a model writes to the user's files (Sentient never edits the live
   knowledge folder in place; it fingerprints it and aborts the swap if the user edited meanwhile).
4. **Explicit completion, not exit codes.** A task is done only when the agent says `completion: done` in its final
   message (or a final `STATUS: DONE` line); a contradictory refusal wins; later tool calls invalidate an earlier claim.
   Useful for Nook's coding-agent cards and tool loop.
5. **Resumable, verified model downloads.** Eight parallel HTTP range requests into part files (the part size is the
   resume bookmark), a free-space preflight, a pinned size and SHA-256, and an atomic move. Nook's `ModelDownload`
   reports progress well but restarts a broken multi-GB file from zero.
6. **A tiny root helper for overnight work.** If Nook ever does background processing at night: `pmset` wake +
   `disablesleep` through an `SMAppService` daemon, a deadman timer fed by heartbeats (app crashed) and a separate
   absolute ceiling that heartbeats never feed (app alive but stuck), and power gates (50% battery to start, 20% to stop).
7. **Morning-after caution.** Classify a failed unattended run into something actionable (signed out, offline, usage
   limit, disk full, stalled) and show one quiet line, instead of a generic error or nothing.
8. **Plain-Markdown knowledge the user can read.** Sentient's knowledge base is ordinary notes with `[[wikilinks]]`
   (and a graph view). Nook's memory could export to, or mirror, a Markdown folder so users can inspect and edit it.
9. **Notch details** from its "do not re-break" list: keep the window a fixed canvas (never resize during a morph);
   re-assert `collectionBehavior` on every reveal; a cursor slammed against the screen's top edge reports the exact
   boundary, which `Path.contains`, SwiftUI hit-testing and `NSRect.contains` all treat as outside (inset the tests).
10. **Permission guide with a draggable app card.** A floating panel follows System Settings and carries a Finder-style
    drag of the app straight into the privacy list (adapted there from the MIT-licensed `jaywcjlove/PermissionFlow`,
    which Nook may use directly).
11. **Docs next to the code.** Every feature folder holds a short `Documentation - <Feature>.md`: what it does, its files,
    how it works, the rules that break things when ignored. Worth copying for Nook's larger areas.

## Not a fit for Nook

- Routing all computer use through OpenAI's signed helper and `codex exec`: Nook keeps its own `UIDriver` and its
  approval model.
- A hosted relay with a covered model route: Nook stays local-first without a Nook-run server.
