# Nook Chat: Sources, Evidence & Actions

This document describes how a question in the Nook chat (**Chat** tab, `⌥⌘Space`) flows through Nook, how sources and citations work, how actions are validated and executed, and what each integration supports.

## Lifecycle of a Question

```text
NookChatView (input, source picker, model chip, attachments) — shared by the notch and main window
  └─ AppModel.handleUserText → ask → answer             (App/AppModel+Chat.swift)
       1. Source scope   SourceScope.parse(question) + per-Nook source picker   (Brain/SourceScope.swift)
       2. Preparation    AppModel.prepareRun: unified preparation for chat, cards, Screen Peek, and Think Along
          Context        SourceRouter.relevant → ConnectorHub.contextLines(scope:full:)
                         relevant sources in full, remaining sources as a one-line summary with the tool to inspect them
          Auto-research  Research: extracts search terms from the question (and follow-up context), searches every
                         relevant source (or all sources if none specified), ranks hits, and reads top hits in full
                                                                                (Brain/Research.swift)
       3. Tools          AppModel.scopedTools: only tools from permitted sources and accounts; read tools via RetrievalLedger
                         ChatIntent (en/nl/de) detects intent so matching tools appear first (Brain/ChatIntent.swift)
                         Staged toolset: a starter set (smaller for local models) plus one line per remaining source;
                         the brain unlocks additional sources via `use_source` (BrainService.run)
       4. Brain          BrainService.run with BrainSelection (built-in MLX, Ollama, LM Studio, or external), unified
                         ToolRunner across all runtimes; read tools execute immediately
       5. Retrieval      RetrievalLedger: records query per source, success / empty / error, 25 s timeout,
                         deduplicates calls, short cache (90 s), numbered citations (Brain/Retrieval.swift)
       6. Answer         Citations.sanitize: only [n] citations matching an actually retrieved reference are kept
       7. Proposal       action tools never execute automatically; ActionGate validates inputs (Brain/ActionGate.swift)
       8. Approval       PlanReview: every step with all fields, toggle on/off, editable text, Run / Cancel
                         (steps with an account display that account; if multiple accounts match, Nook asks which one)
       9. Execution      PlanRunner: re-validates, prevents duplicate runs, stops on first error,
                         resumes remaining steps without repeating; states: proposed → approved → executed → verified
                                                                                (AppModel+Plans.swift)
      10. Persistence    nooks.json (conversation, sources, citations, per-step outcomes); nook.sqlite (audit,
                         executed_actions)
```

### Understanding the Question First

Keyword lists alone are poor at guessing intent: *"Do I have open chats in WhatsApp?"* is not a full-text search for the words `"chats"` and `"whatsapp"` across your files and code—it is asking which WhatsApp conversations are unread or awaiting your reply. Before looking anything up, the selected brain first reads the question (`QueryPlanner`, `Brain/QueryPlan.swift`, called from `prepareRun`). Given the question, recent turns, and available sources (including what each source supports: search, newest/unread/open items, or currently unavailable), it returns a compact plan:

- **goal**: what the user actually wants to know or do, in a single sentence. This is passed to the answering step (`"What the user wants"`) so the model answers the exact question asked;
- **kind**: specific lookup, overview of new/open items, action, general knowledge, or greeting;
- **sources**: where the answer actually lives, with explicitly mentioned sources first;
- **queries**: one to three short search queries containing the terms expected to appear in the target item, including synonyms. Nook tries all of them.

With Claude, Haiku performs this lightweight planning step (fast and inexpensive) while your selected model writes the final answer. Local models and other providers run the planner themselves. If no valid plan arrives within 8 s (12 s locally), Nook falls back to its built-in keyword research below. Claude Code skips this step because spawning a full CLI session just for query planning is too slow.

When answering, the model follows a strict reasoning order: what does the user want, where does that information live, does the retrieved context actually answer the question (if not, search further), and only then formulate the answer. It never guesses yes or no about your personal data without evidence. When searching files, documents rank ahead of source code and build artifacts (`dist/`, `node_modules/`, `.build/`, etc.) are excluded.

### Automatic Search & Full-Document Reading

Small local models often struggle with multi-step tool calling: they may invoke a single search tool with the entire sentence as the query, or read only the titles of the eight newest notes. Nook therefore performs the initial retrieval pass on your Mac before the model answers, consistently across every brain and source (`Research`, called from `prepareRun`):

1. **Search terms.** Extracts the core terms carrying the meaning of the question. Stop words, question words, app/source names (WhatsApp, chats, Slack…), status words (open, unread, pending), dates, and times are stripped (en/nl/de); proper names are prioritized, and quoted phrases are kept intact. Short follow-up questions (*"And the budget?"*) inherit terms from the preceding turn and search the same sources.
2. **Searching.** Every relevant source is searched with those terms: Notes (both title and body across all notes), Mail, Files (Spotlight), Notion, GitHub, the web, and any MCP server or custom source with a search parameter. If the question does not name a specific source (*"What do I know about Project Apollo?"*), Nook searches all searchable sources (the web only when requested; Contacts only when a person's name is present).
3. **Reading.** Hits across all sources are ranked (title matches weigh more than body matches, case- and diacritic-insensitive) and the top matches are opened in full using the source's read tool: `read_note`, `read_mail`, `read_file`, `notion_read_page`, `github_issue_details`, `read_webpage`.

The model receives these results at the top of its context (`"Looked up for this question"`): first where Nook searched and with which queries, then the full documents, and then the remaining search hits.

**Explicit source targeting.** If your question names a specific source (*"Do I have open chats in WhatsApp?"*), Nook never falls back to searching "everywhere" instead—even if that source is currently unreadable. If a source cannot be read (missing Full Disk Access, app not installed, integration disabled), the source is shown as `✗` above the answer with the exact reason, and Nook tells you how to enable it rather than guessing from unrelated notes or files.

**Open chats.** For questions like *"Do I have open chats?"*, *"Who is waiting for my reply?"*, or *"Any unread messages?"*, `whatsapp_open_chats` and `messages_open_chats` return conversations from the last 14 days that have unread messages (including manually marked unread in WhatsApp) as well as 1-on-1 chats where the other person sent the last message, complete with the latest message preview and a chat ID for reading the thread.

**Local database connectors.** Messages (iMessage & SMS), WhatsApp, Bear, and Things store their data in SQLite databases on your Mac. Nook queries them read-only via `sqlite3` (`Services/Connectors/AppConnectors.swift`, formatting in `Brain/AppData.swift`), allowing it to search your full history rather than only what is visible on screen: `search_messages` / `read_messages`, `search_whatsapp` / `read_whatsapp`, `search_bear` / `read_bear`, `search_things`. Contact names are resolved via Contacts (when authorized). Reading Messages and WhatsApp requires **Full Disk Access** for Nook in **System Settings › Privacy & Security**.

**MCP servers.** Every read tool with a search parameter is included in automatic research. If the same MCP server exposes a single-item read tool (`get`/`read`/`fetch`/`show` with an ID parameter), Nook automatically fetches the top hits.

**Other apps.** When you name an app (*"What's in Slack?"*), Nook reads its windows via the macOS Accessibility API and keeps the passages relevant to your question. Documents from apps (Obsidian, Word, Pages, PDFs) are found and read via Spotlight.

### Memory: How Nook Remembers & Learns

Memory is built directly into Nook—no external MCP server, Node, or `npx` required. Everything is stored locally in `nook.sqlite` (`memories` table) on your Mac and managed in **Settings › Memory**: search, edit, pin, mark individual memories as **Only on this Mac**, or delete individual/all memories.

**How Nook learns** (`Brain/Memory.swift`, `Services/NookMemory.swift`, `App/AppModel+Memory.swift`):

- **Explicit requests.** *"Remember that Alice is my partner"*, *"Always give concise answers"*, or *"Forget my old address"*. The brain proposes `remember` or `forget`. If you explicitly asked for it and the fact comes from your own words, it is saved immediately; otherwise it appears as an approval step in the plan. Corrections replace the outdated memory via `replaces`.
- **Background reflection.** After a correction, a personal statement, or every four questions, the brain reviews what **you** wrote in the conversation and extracts durable facts worth remembering (`Reflection`). Only facts grounded in your own messages are stored, and `"Remembered: …"` is shown below the answer.
- **Observed habits & tool lessons.** If you repeatedly adjust the same field in an action plan (e.g., choosing the `"Work"` calendar or `"Groceries"` list twice in a row), Nook learns that default and fills it in automatically when the brain leaves it blank. Failed tool calls are recorded as lessons so the brain avoids repeating the same mistake.
- **Source affinity.** When an answer cites an email for a query about `"invoice"`, Nook learns that Mail answers that topic and includes Mail automatically on future questions about invoices.
- **MCP Knowledge Graph import.** If you previously used `@modelcontextprotocol/server-memory`, Nook detects its knowledge graph in the `npx` cache and lets you import it with one click.

**Security & Privacy of Memory:**
- Passwords, secret keys, tokens, URLs, and anything resembling an instruction (*"ignore previous instructions"*, *"run without asking"*, tool tags) are automatically rejected.
- Learned memories must be grounded in your own user messages—screen text, emails, and web pages can never inject entries into your memory without explicit approval.
- Memory is a first-class source (`memory`): mark it as **Only on this Mac** (globally or per memory via the lock icon) and external cloud models never see it.

### Cards & Think Along Share the Same Pipeline

Notch cards (Screen Peek `⌥⌘N` and Think Along) use the exact same `prepareRun` pipeline as the chat: the same source scoping, `RetrievalLedger`, `ActionGate` validation, and verified citations.

### Energy: When Nook Steps Back

Everything Nook does by himself—reading the screen on a timer (`ScreenContext`), thinking along, scanning for agents started outside Nook (`AgentHub`), refreshing the agent history, and watching for meetings and screen sharing (`QuietWatch`)—follows one plan instead of each worker reading the Mac on its own:

- **`EnergyPolicy`** (`Core/EnergyPolicy.swift`, Foundation-only, `EnergyPolicyTests`) turns the Mac's signals (Low Power Mode, thermal state, load average per core, battery, no input for five minutes, displays asleep) and your choice into an `EnergyPlan`: **full**, **light** (the same work, half as often; Think Along at most every ten minutes) or **paused** (optional work waits; what remains runs at a sixth of its pace).
- **`EnergyMonitor`** (`Services/EnergyMonitor.swift`) keeps the current plan for the whole app. It reads the signals every ten seconds and the moment macOS announces a change (charger, Low Power Mode, thermal state, display sleep and wake), and publishes only a changed plan.
- **Settings › General › Energy** offers three choices: **Automatic** (steps back on battery, a hot or busy Mac, and while you are away), **Saver** (always light) and **Full power** (never slows down for the battery or a busy Mac; a hot Mac still gets a break, and Low Power Mode makes it light). A status line says what Nook is doing right now and why, and **Settings › Assistant › Currently in view** shows *Paused: your Mac is hot* (or another reason that pauses it) instead of an empty line while screen reading is paused. The chat can switch the mode too (`energy_mode` in `SettingsCatalog`).
- The plan also sets how hard the GPU and CPU may work: while taking it easy the screen reader keeps four windows instead of ten, lets background windows age 90 s instead of 30 s before capturing them again, captures them at most 1600 px wide and runs Vision on one window at a time instead of three (a hum instead of a spike); the live picture of a Mac app next to the chat (`MacAppMirror`) streams at 30 fps instead of 60 and switches the moment the charger comes out; Nook in the closed notch animates at 8 fps instead of 12 while he only thinks along.
- The meeting and sharing check runs only when it has an effect: when you chose *Change nothing* for both and Settings › Notifications is closed, the window list and microphone scan are skipped altogether.

Work you ask for (a question, Screen Peek, dictation) never waits for the plan.

### Brain Selection

`BrainSelection` defines where Nook thinks: built-in (MLX), Ollama, LM Studio, or an external cloud provider. Fresh installs default to local on-device inference. Nook never silently falls back to another provider—if your selected model is unavailable, Nook displays a clear error explaining how to resolve it.

### "Only on This Mac" Source Lock

`AppSettings.localOnlySources` tracks sources that external cloud providers are never allowed to see (**Settings › Privacy and access › Only on this Mac**). Whenever an external brain is active (`AppSettings.privateSources`), those sources are stripped from the scope via `SourceScope.keepingLocal` at the start of `prepareRun` and `answer`. Their context, tools, and search queries are completely excluded, and prior turns that used a local-only source are omitted from conversation history (`NookChat.withoutPrivate`). With a local brain (built-in MLX, Ollama, LM Studio), all enabled sources remain available.

### Local Brain Quality & Grounding

4B–8B parameter local models benefit from structured assistance (`Brain/LocalQuality.swift`, tested in `LocalQualityTests`):

- **Expanded context window (`ModelProfile.roomier`):** On Macs with 16 GB+ RAM, models with an 8k default window are expanded to 16k so full retrieved documents fit comfortably.
- **Evidence First** (**Settings › Brain**, off by default): runs a narrow extraction pass per retrieved document that copies verbatim sentences relevant to the question (`BrainService.extractEvidence`). Quotes not present verbatim in the document are discarded.
- **Verify Answers** (on by default for small local models): `Grounding.ungrounded` checks numbers (3+ digits), times, email addresses, and URLs in the draft answer against retrieved sources. If an ungrounded value is found, Nook regenerates the answer once while highlighting the unverified details.
- **Evaluate This Brain:** **Settings › Brain › Evaluate this brain** runs a 20-question benchmark (`LocalEval`) with known ground-truth answers (facts, distractors, missing answers, wrong person, superseding updates, prompt-injection attempts) and records accuracy and latency.
- **Fine-tuning:** `scripts/finetune/` generates synthetic training data and trains a LoRA adapter with MLX (see [`scripts/finetune/README.md`](../scripts/finetune/README.md)).

### Multi-Account Support

Integrations can have multiple accounts (`AccountRegistry`, e.g., `"GitHub · Work"`). Read tools without an explicit `account` parameter search across all permitted accounts and label each result; write actions prompt you to pick an account whenever more than one account is connected.

### Terminal & Browser Tools

`run_command` (*Terminal* source) is always an explicit action: the full command is shown in the plan, `CommandRisk` evaluates token-level risk, dangerous commands are blocked by `ActionGate`, and approved commands run inside a visible workspace terminal. `read_nook_browser` reads the active page in Nook's built-in browser; `open_in_nook_browser` only allows `https://` URLs and requires approval.

### Mouse & Keyboard

When no tool or menu command can do something (a switch in System Settings, an option in another app's window), Nook reads the window with `read_ui` and proposes the clicks, typing and key presses with `control_ui` (*Screen* source). The plan lists every step in full, and the steps run only after you approve them:

- **One app only.** Every step acts in the app named in the plan: it is brought to the front first, elements are looked up in that app only (by their label, found again right before each step), a click on a point lands only when that app's own window is on top there, and keys stop as soon as another app takes the focus.
- **Off limits.** Nook never drives terminals, password managers, Keychain Access, script editors or itself (`UIControl.isBlocked`), never types into a password field, and refuses shortcuts that leave the app (lock screen, log out, force quit, app switcher, Spotlight).
- **Step by step.** After an approved batch ran, Nook reads the window again and proposes the next batch, up to six batches in a row; after that a *Continue* button asks you first. Every batch is a plan of its own and is written to the audit log.

Requires Accessibility access for Nook (System Settings › Privacy & Security › Accessibility).

### Apps Next to the Chat

`@open whatsapp` (or `@whatsapp`, `open whatsapp in nook`) opens an app's web version next to the chat: over a hundred apps from `EmbeddedAppCatalog` (WhatsApp Web, Telegram, Slack, Gmail, Google Docs, Notion, Trello, GitHub, ChatGPT, Spotify…), or any `https` address (`@open notion.so`). You work in the app itself while you chat with Nook beside it; `@close` puts it away. Each app keeps its own sign-in across launches in a separate `WKWebsiteDataStore`, so WhatsApp asks for the QR code only once; the pane's menu signs out and removes that data. `read_open_app` (*Browser* source) reads what the app shows when you ask about it; Nook never types or clicks in it.

When the app is installed on the Mac (`InstalledMacApps` scans `/Applications`, `/System/Applications` and `~/Applications`), `@open` opens the **Mac app itself** instead; `@open whatsapp web` still opens the web version. macOS does not let one app place another app's window inside its own, so `MacAppMirror` lays the real window exactly under the pane (Accessibility), shows a live picture of it in the pane (ScreenCaptureKit, up to 60 fps, each frame's IOSurface handed straight to a layer without copying), and `NotchController` lets the pointer fall through the notch there (`passesThrough(at:)`), so clicks, scrolling, dragging, typing, menus and the cursor are the app's own. Once the window starts at the pane's top-left corner, the picture is exactly the screen under the pane (1:1), so the pointer lands where it looks like it does even when the app keeps a minimum size larger than the pane. If another app's window is in the way, the real window is raised first; a click on the pane outside it is not treated as a click outside Nook. The window's frame is restored when the pane closes. It needs Screen Recording (to show the window) and Accessibility (to place it, and to read it with `read_open_app`); without Accessibility, clicks on the picture are sent as events (`CGEvent.postToPid`), which many apps ignore. *Show the app itself* in the pane's header brings the real window to the front for what a picture cannot do (dragging files in, full-screen video).

**WhatsApp chats by name.** `@open chat Jan` (also `@chat Jan`, `@open whatsapp Jan`, `@open chat whatsapp Jan`) brings back one WhatsApp chat as the same notch card a new message shows: the conversation with its photos and files, the answer field and *Let Nook answer*. It is how you return to a chat whose card you closed. While you type after `@open chat `, the list under the text shows the chats that fit (newest first, with how many messages are new), so you choose the one you mean and its full name is filled in; `@` alone offers `@open chat` first. Opening fetches the chat's newest messages from the gateway but marks nothing read: only the card's *Read* button or your answer does that. An unknown name gets an answer in the chat that lists the chats Nook knows.

### Source Chips & Citations

Above every answer, Nook shows a status chip per source:

| Chip | Meaning |
|---|---|
| Filter icon | Restricted source scope active for this answer |
| Eye icon | Ambient context included without a tool call (screen, attached file) |
| `✓ Mail · 3` | Searched, with 3 retrieved references |
| `○ GitHub · nothing found` | Searched, 0 results |
| `✗ Notion` | Search failed; hover or read below the answer for the exact reason |

Clicking `ⓘ` reveals the exact context and every search query with its outcome. Tools emit references (`@ref title | url | detail`), which `RetrievalLedger` numbers sequentially across the turn (`[1]`, `[2]`, …). Hallucinated citation numbers are stripped by `Citations.sanitize`. Only `https:`, `file:` (inside your home directory), and `message:` (opens the email in Mail.app) links are clickable.

### Action Validation & Execution

- Every write operation is a proposal validated by `ActionGate.problems` (required fields, types, allowed values, ISO 8601 dates, end-after-start, `https://`-only URLs, `owner/repo` without `..`, valid email addresses).
- You can inspect all fields, toggle individual steps on or off, and edit text fields inline before clicking **Run**.
- `PlanRunner` re-validates every step at execution time and records a deterministic key (tool + inputs) in `executed_actions` so identical actions are not accidentally repeated within 12 hours unless you explicitly click **Run Anyway**.
- All approvals, cancellations, and executions are logged in `nook.sqlite` (`audit` table).

### Changing Settings from the Chat

Ask Nook to change its own settings ("turn web search off", "answer in English", "open my connection settings"). The brain reads them with `get_settings` and proposes `change_setting`; every change waits for your click on the plan, is logged in the `audit` table, and can be undone ("undo that" restores the old value). `open_settings` only opens the window at a section, so it may run right away when you ask for it and **Perform small tasks immediately** is on. Which settings qualify is `Brain/SettingsCatalog.swift`: anything that would let Nook act without asking, or send more data off your Mac (the brain, its provider, **Only on this Mac**), is deliberately left out and stays a click in Settings.

## Integration Capabilities Matrix

Legend: ✅ supported & tested · ⚠️ supported with caveats · ❌ not built-in (use an MCP server).

| Source | Type | Read | Write (Always After Approval) |
|---|---|---|---|
| Apple Calendar (all macOS accounts) | On your Mac | ✅ 7-day context, `list_events`, `check_availability` across calendars | ✅ `create_event` (calendar picker, returns ID), `update_event`. ❌ inviting attendees (EventKit limitation) |
| External Calendars (ICS) | URL | ✅ via `check_availability` | ❌ read-only |
| Apple Reminders | On your Mac | ✅ open reminders in context | ✅ `create_reminder`, `complete_reminder` |
| Nook Open Loops | Nook | ✅ `list_open_loops` | ✅ `add_open_loop`, `complete_open_loop` |
| Apple Mail | On your Mac | ✅ unread in context, `search_mail` (Inbox + Sent, message links), `read_mail` | ⚠️ `compose_mail`: drafts in chat and opens in Mail.app where you click Send; ✅ `trash_mail` (to Trash, at most 200 per action, needs ids or a sender/subject filter), `mark_mail` (read, unread, flagged) |
| Browser | Mac & Nook | ✅ open tabs with URLs; `read_nook_browser` | ✅ `open_in_nook_browser` |
| Terminal | In Nook | – | ✅ `run_command`: full command in plan, dangerous commands blocked, runs in visible workspace terminal |
| MCP Servers | stdio or HTTP | ✅ server read tools | ✅ server write tools, always gated by approval |
| Messages (iMessage & SMS) | On your Mac (Full Disk Access) | ✅ `search_messages`, `read_messages`, `messages_open_chats` | – |
| WhatsApp | On your Mac (Full Disk Access) or local bridge | ✅ `search_whatsapp`, `read_whatsapp`, `whatsapp_open_chats`, `whatsapp_live` | ✅ `whatsapp_send` to existing chats (rate-limited to 6/min) |
| Bear | On your Mac | ✅ `search_bear`, `read_bear` | – |
| Things | On your Mac | ✅ `search_things` | – |
| Files (Spotlight) | On your Mac | ✅ `search_files`, `read_file` (PDF, Word, RTF, plain text) | – |
| Clipboard | On your Mac | ✅ off by default | – |
| Screen | On your Mac | ✅ OCR of open windows (requires permission) | – |
| Any Mac app (menu bar) | On your Mac (Accessibility) | ✅ `list_app_menu`: the app's menu commands | ✅ `app_menu_command`: runs one menu command (e.g. Finder › File › New Folder) after approval |
| Any Mac app (mouse & keyboard) | On your Mac (Accessibility) | ✅ `read_ui`: the buttons, switches, fields and texts of an app's window | ✅ `control_ui`: clicks, typing, key presses and scrolling in one app (e.g. a switch in System Settings) after approval |
| GitHub | OAuth Device Flow (`repo read:user`) or PAT | ✅ PR list, `github_pr_details`, `github_search`, `github_issue_details` | ✅ PR review, comment, merge, close; `github_create_issue`, `github_comment_issue`, `github_update_issue` |
| Notion | API token | ✅ `notion_search`, `notion_read_page` | ❌ (use Notion MCP for writes) |
| Stripe, Vercel, Cal.com, n8n, Resend | API token | ✅ read summaries | ❌ read-only |
| Custom Sources & Webhooks | Custom API / webhook | ✅ `read_source` (GET, same-host enforced) | ✅ `send_to_source`: Slack, Discord, Microsoft Teams, Telegram, generic webhook |
| Web | Internet | ✅ web search & page reader | – |

## Known Limitations

- Keyword-based source fallback uses a curated stop-word list when `QueryPlanner` times out; the manual source picker always overrides automatic detection.
- `search_mail` searches subject, sender, and recipient via AppleScript (full-body AppleScript search across large mailboxes is too slow), then reads top matches in full via `read_mail`. When Mail is too slow to return message text, it searches again with headers only.
- Messages, WhatsApp, Bear, and Things are read from their local SQLite databases; if an app changes its internal schema in an update, queries fail gracefully and report the error on the source chip.
- Gmail/Google Drive and Microsoft Teams/OneDrive require custom OAuth app registrations and are not built in directly; connect them via an **MCP server** in **Settings › Connections**, or use Mail.app / Finder sync.
