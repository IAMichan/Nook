# Nook

[![Build](https://github.com/IAMichan/nook/actions/workflows/build.yml/badge.svg)](https://github.com/IAMichan/nook/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-MLX-orange)
![Local-First](https://img.shields.io/badge/AI-Local--First-2ea44f)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Stars](https://img.shields.io/github/stars/IAMichan/nook?style=social)](https://github.com/IAMichan/nook/stargazers)

**Your personal AI assistant and coding-agent command center in the MacBook notch.**

Nook lives quietly in the notch of your Mac (or floats anywhere on any display). It keeps the text of every window across all displays updated locally via on-device OCR, so any question is answered immediately with what you are looking at—combined with your Calendar, Reminders, Mail, browser tabs, local files, and connected services (**GitHub, Notion, Linear, Stripe, Vercel, Sentry, Cal.com, n8n, Resend, WhatsApp**, custom APIs/webhooks, and **MCP servers**).

By default, Nook runs **100% locally on your Mac** (via built-in MLX models, Apple Foundation Models, Ollama, or LM Studio) at zero cost per query, or connects to external cloud models when you explicitly choose (**Claude, OpenAI, Google Gemini, Grok / xAI, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Claude Code**). It also monitors and orchestrates your **coding agents** (**Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp, Hermes**, or any custom agent), complete with live diffs, inline approvals, isolated Git worktrees, a built-in terminal and browser, system-wide inline autocomplete, push-to-talk dictation, call note-taking, and media controls.

**Nothing runs, sends, or modifies files without your explicit approval.**

[Quick Start](#quick-start) · [Highlights](#highlights) · [Documentation](#documentation) · [Contributing](#contributing) · [Report a bug](https://github.com/IAMichan/nook/issues/new/choose) · [Security](SECURITY.md)

## Why Nook?

- **Local-first and private.** The default brain runs on your Mac. Cloud models are opt-in, per source, and never get data you marked *Only on this Mac*.
- **Always has context.** Live on-device OCR plus Calendar, Mail, Reminders, browser tabs, files, and your connected services, so you don't have to paste anything.
- **One place for your coding agents.** See what every agent is doing, review diffs, and approve tool calls from the notch instead of hunting through terminals.
- **You stay in control.** Every side effect goes through an approval card and is written to a local audit log.
- **Open source (MIT).** Built to be read, hacked on, and translated.

> [!NOTE]
> **Project Status (`v0.1`):** Early open-source release. The app compiles and its core test suite passes in CI, but expect rough edges as real-world testing expands.
>
> **Languages:** The interface defaults to **English** and supports **Dutch, German, French, and Spanish** (`Settings › General › App language`).
>
> **Platform status:** macOS is the primary, most complete app. The iPhone companion and the Tauri app (Windows, Linux, Android) are in earlier stages.
>
> **Monorepo:** The macOS app lives in [`apps/macos`](apps/macos) and the iPhone companion app in [`apps/ios`](apps/ios). Nook for **Windows, Linux, and Android** is a single Tauri app in [`apps/tauri`](apps/tauri) (Rust core, Svelte UI); see [`docs/TAURI.md`](docs/TAURI.md) for what has been ported so far (its interface is Dutch-only for now). Shared protocol and core packages live in [`packages/`](packages) (see [`docs/MONOREPO.md`](docs/MONOREPO.md)).

---

## Table of Contents

- [Highlights](#highlights)
  - [Personal Assistant & Screen Context](#personal-assistant--screen-context)
  - [Coding Agents & Workspace](#coding-agents--workspace)
  - [Integrations & Connected Services](#integrations--connected-services)
  - [System-Wide Autocomplete, Dictation, Notes & Media](#system-wide-autocomplete-dictation-notes--media)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
  - [First Launch & Onboarding](#first-launch--onboarding)
  - [Navigating Nook](#navigating-nook)
- [Local Brain Quality & Evaluation](#local-brain-quality--evaluation)
- [Privacy & Security](#privacy--security)
- [Documentation](#documentation)
- [Architecture & Repository Layout](#architecture--repository-layout)
- [Known Limitations](#known-limitations)
- [Contributing](#contributing)
- [Community & Support](#community--support)
- [Acknowledgments & License](#acknowledgments--license)

---

## Highlights

### Personal Assistant & Screen Context

| Feature | How It Works |
|---|---|
| **Local-First Brain** | Runs on your Mac by default (built-in MLX models sized to your Mac's unified memory, Apple Foundation Models, Ollama, or LM Studio). Nothing leaves your computer and queries cost nothing. A model chip next to the input bar shows the active brain and opens a dropdown to switch between models on your Mac and every cloud provider you set up (**Claude** with native web search, **OpenAI, Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Claude Code**); add a provider's key in **Settings › Brain**. |
| **Chat Anywhere** | Press `⌥⌘Space` from any app, use the input bar in the **Nook** tab, or open the full window (`⌥⌘W`). Supports multi-turn follow-ups, streaming Markdown responses (headings, lists, tables, code), and context-aware starter prompts tailored to your active app, next calendar event, waiting agents, or time of day. |
| **Talk to Nook** | Press `⌥Space` (or click the mic button) for on-device speech recognition, or enable the local **"Hey Nook"** wake word and spoken answers in **Settings › Dictation and voice**. |
| **Parallel Threads ("Nooks")** | Every conversation is an independent **Nook** working on a single task. Start a new one with `⌘N` while previous Nooks keep working in the background. A sidebar shows each Nook's status (*working*, *waiting for approval*, or *done*). If a Nook finishes while you are elsewhere, it notifies you in the notch. History is stored locally in `nooks.json`. |
| **Live Multi-Display Screen Context** | Continuously indexes window text across all connected displays using local OCR so answers are ready immediately. Say *"schedule an appointment for this"* or press `⌥⌘N` (**Look Along**) to extract dates, times, locations, promises, or tasks from the frontmost window. Above each answer, Nook shows which windows and sources it consulted. |
| **Images, Screen Regions & Attachments** | Drag an image, screenshot, PDF, Word, RTF, or text file onto the chat/notch, or press `⌥⌘4` to select a screen region. Vision-capable brains receive the image directly; all brains receive the locally extracted OCR text. |
| **Grounded Sources & Citations** | Automatically selects relevant connectors per question. Above the response, you see which sources were searched, returned nothing, or failed; below the response, numbered citations (`[1]`, `[2]`) open directly in Mail, Finder, or your browser. Restrict sources per query via the source picker or in natural language (*"only my calendar and mail"*, *"not my screen"*). See [`docs/ASSISTANT.md`](docs/ASSISTANT.md). |
| **Multi-Step Action Plans** | Ask for compound tasks (*"create reminders for open items and draft an email to Lisa"*) and Nook builds a single interactive plan. Inspect parameters, toggle individual steps on or off, or edit text inline before clicking **Run**. If a step fails midway, Nook shows exactly what succeeded and lets you resume without duplicating completed actions. |
| **Inline Charts** | Ask for a chart (*"chart my meetings per day"*) and Nook renders native bar, line, area, pie, or scatter charts directly in chat from your calendar, services, or web data—automatically converting code, JSON, Mermaid, or Markdown tables into native charts if a smaller model outputs raw markup. |
| **Built-In Memory** | Zero setup required. Say *"remember that Lisa is my wife"* or *"always keep answers short"*—or *"forget…"* to remove it. Nook also learns automatically from your corrections, facts you share, preferred calendars/lists, and source usage. Everything stays in `nook.sqlite` on your Mac and can be inspected or deleted in **Settings › Memory** (including 1-click import from an MCP memory server). |
| **Proactive "Think Along"** | Optional (**Settings › Assistant**). When you focus on something for a while, Nook can quietly suggest help next to the notch (*"Shall I add this to your calendar?"*). Hover to **Run**, **Dismiss**, or **Mute for this app**. Missed suggestions stay available in **Today**. |
| **Follow-Ups & Open Loops** | Suggests one-click next steps below answers (*"Add to calendar"*, *"Draft a reply"*) and tracks promises and open tasks locally in the **Nook** tab. |

### Coding Agents & Workspace

| Feature | How It Works |
|---|---|
| **Live Agent Hub in the Notch** | Tracks **Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp, Hermes**, and any custom tool using `nook_agent` (see [`docs/AGENTS.md`](docs/AGENTS.md)). See who is working (with live `+`/`−` line diffs), who is waiting, and approve tool calls right from the notch (**Allow**, **Always**, **Deny**, or **In Terminal**). Answers in the terminal immediately clear the notch card. Even supports Claude Code multiple-choice questions (`AskUserQuestion`). |
| **Full Agent Workspace** | Open the **Agents** tab in the notch or the main window (`⌥⌘W`). Launch and supervise coding sessions (`claude -p` with `stream-json` and `codex exec --json`). Press `⌘N` (**New Session**) to pick a folder or clone a repo, enter a prompt, choose the agent, account, model, **Agent** or **Plan** mode, permissions, and whether to run in-place or in an **isolated Git worktree** on its own branch. Stop (`⌘.`), resume, and retry sessions across app restarts. |
| **Git, Diffs & Pull Requests** | Inspect changed files, diffs, branches, and worktrees alongside each session. **Commit**, **Push**, and create **Pull Requests** (GitHub, GitLab, Gitea, Forgejo, Bitbucket) right from the notch or workspace window—always after your explicit click. **Agents › Pull requests** opens any GitHub pull request in full (description, checks, a full timeline of reviews, comments, commits and events, and every file's diff) and merges it (merge, squash, or rebase) after you confirm. |
| **Built-In Terminal & Browser** | Under **Workspace**, use Nook's integrated terminal (**SwiftTerm**) and ephemeral browser (**WebKit**, zero persistent storage). Any command Nook proposes (`run_command`) is gated by `CommandRisk`, blocks destructive commands, and runs visibly in the terminal. |
| **MCP Workspace for Agents** | Coding agents can use Nook's terminal, browser, and PR flow through a local MCP server (`~/.nook/nook-mcp`): start dev servers (`terminal_run`, `terminal_read`), inspect pages with DOM text, console errors, and screenshots (`browser_open`, `browser_read`, `browser_screenshot`), and propose pull requests (`pull_request_create`). See [`docs/WERKRUIMTE-AGENTS.md`](docs/WERKRUIMTE-AGENTS.md). |
| **Multiple Accounts & Quotas** | Configure multiple accounts per agent (e.g., *Claude Personal* and *Claude Work* with isolated `CLAUDE_CONFIG_DIR` / `CODEX_HOME` directories) and per service (e.g., two GitHub accounts). Track live **5-hour and weekly subscription limits** (Claude Pro/Max & Codex) plus token and cost breakdowns in **Settings › Usage** and the Monday **Weekly Recap**. |
| **iPhone Companion App** | [`apps/ios`](apps/ios) contains **Nook Companion** for iPhone: view active sessions needing attention, approve low-risk actions, answer questions, send prompts, or stop agents over local Wi-Fi with end-to-end `ChaCha20-Poly1305` encryption and direct, serverless APNs push notifications. See [`docs/COMPANION.md`](docs/COMPANION.md). |

### Integrations & Connected Services

| Integration | Capabilities |
|---|---|
| **Unified Calendars** | Queries Apple Calendar (across all configured accounts), external ICS feeds (Google Calendar, Outlook, iCloud, work calendars under **Other Calendars**), and **Cal.com** simultaneously to find conflicts and free slots. |
| **Mail, Reminders & Contacts** | Search and summarize unread emails, draft replies in chat (and click **Send** or **Open in Mail**), create Apple Reminders, and resolve contact details locally. |
| **1-Click OAuth (MCP)** | Connect **Notion, Linear, Stripe, Vercel, and Sentry** with a single click (**Connect** uses OAuth + PKCE against their official MCP servers; tokens live in the macOS Keychain and refresh automatically). |
| **GitHub, Cal.com, n8n & Resend** | Review, approve, merge, and close GitHub PRs; manage bookings in Cal.com; trigger workflows in n8n; send transactional emails via Resend—all with multi-account support. |
| **WhatsApp Live** | Pair your phone via a local bridge on your Mac (**Settings › Accounts & Integrations › WhatsApp Live**, scan QR code). Reply to incoming messages from the notch or ask Nook to draft a WhatsApp message (sent only after clicking **Run**). |
| **Custom APIs, Webhooks & MCP** | Connect almost any HTTPS API or webhook under **Custom Sources** (auto-detects Slack, Discord, Teams, Telegram, Zapier, Make, n8n, Todoist, fetches service icons, and gates outgoing messages behind approval) or attach any **MCP server** (`stdio` or `HTTP`). |

### System-Wide Autocomplete, Dictation, Notes & Media

| Feature | How It Works |
|---|---|
| **Autocomplete Anywhere** | As you type in any macOS app, a local model suggests inline ghost-text completions at your cursor (`Tab` accepts a word, `⇧Tab` accepts all). Powered by your active brain or any local GGUF model via `llama.cpp` (`LlamaSwift`), aware of your screen and memory, with `:emoji` lookup, typo fixes, per-app/per-website instructions, style learning, and strict password-field exclusion (**Settings › Autocomplete**, [`docs/AUTOCOMPLETE.md`](docs/AUTOCOMPLETE.md)). |
| **Flow Dictation** | Hold a hotkey anywhere on your Mac, speak, and release to paste cleaned text right where you type (double-tap for hands-free, `Esc` to cancel, `⌃⌘V` to paste last dictation). Listens across your languages simultaneously on-device (`MultiDictation`) or offline via **Parakeet** on the Neural Engine (`FluidAudio`), applying your custom dictionary, replacements, and snippets. |
| **Call Notetaker** | Records microphone and system audio locally during calls (Zoom, Meet, Teams, browser), separates speakers with on-device diarization, and generates a timestamped transcript, summary, key points, and action items. |
| **Music & Instant Control** | Live Spotify and Apple Music artwork, audio-reactive equalizer, scrubbing, shuffle/repeat, and volume in the notch, plus synced lyrics (from Music or the open [LRCLIB](https://lrclib.net) database, can be turned off in Settings › Privacy), Up Next and playlists for Apple Music, and a Recent list for both players. Fast local intent recognition handles *"next track"*, *"volume 30"*, *"open Safari"*, Apple Shortcuts, and system toggles immediately without waiting for an LLM. |
| **The Nook Character** | An interactive 3D-shaded orb that follows your cursor, bounces when you send a message, nods when tasks complete, blushes on hover, and wears a live **task ring** showing everything Nook and your coding agents are doing (white = working, amber = waiting for you, coral = error, mint = done). |

---

## Requirements

- **macOS 15.0 (Sequoia)** or newer (a MacBook with a notch is ideal, or use Floating mode on any Mac / external display)
- **Apple Silicon Mac** (M1 or newer)
- **Xcode 26** or newer (required by the `mlx-swift-lm` packages for the built-in local model)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`)
- **No API key required:** Nook runs locally on your Mac out of the box. External cloud keys (e.g., [Anthropic](https://console.anthropic.com/), OpenAI, Gemini) are completely optional.

---

## Quick Start

```sh
brew install xcodegen
git clone https://github.com/IAMichan/nook.git
cd nook/apps/macos
xcodegen
open Nook.xcodeproj
```

Press **`⌘R`** in Xcode to build and run. Nook runs as a menu-bar and notch app (`LSUIElement`) without a Dock icon—look for Nook in your notch and the small Nook icon in the menu bar.

> [!TIP]
> **After every `git pull`:** Run `./update.sh` from the repository root. Because `Nook.xcodeproj` is generated from [`apps/macos/project.yml`](apps/macos/project.yml) and not tracked in Git, running `./update.sh` pulls the latest changes and regenerates both the macOS and iOS Xcode projects so new Swift files are always in scope.

You can also build and run the unit test suite from the command line:

```sh
cd apps/macos
xcodegen
xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:NookTests test
```

The fast Foundation-only core and localization tests also run on Linux:

```sh
./scripts/core-tests.sh
```

Not on a Mac? See [`apps/tauri`](apps/tauri) and [`docs/TAURI.md`](docs/TAURI.md) for the Windows, Linux, and Android app.

### First Launch & Onboarding

On first launch, Nook shows a welcome card. Clicking **Set up** opens an onboarding flow (every step can be skipped):

1. **Brain:** Nook recommends a local model matched to your Mac's unified memory (or detects models already running in Ollama or LM Studio) and installs it with one click. Prefer a cloud provider? Select it in **Settings › Brain**. Nook never switches to the cloud on its own.
2. **Permissions:** Screen Recording (for local window OCR) and Calendar; Reminders and Microphone are only requested when you first use them.
3. **Integrations (Optional):** Connect Mail, GitHub, Stripe, Notion, Linear, Vercel, Sentry, MCP servers, and more under **Settings › Accounts & Integrations**.
4. **Coding Agents (Optional):** In **Settings › Agents**, click **Connect…** next to Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp, or Hermes. Nook previews the exact hook configuration diff, creates a timestamped backup (`settings.json.nook-backup-…`), and writes only after your approval.

Want to explore Nook with sample data first? Enable **Demo data** in **Settings › General**.

### Navigating Nook

- **The Notch** has three main tabs (plus **Music** when audio is playing):
  - **Nook:** Chat, Today overview, and your parallel Nook threads.
  - **Agents:** Active coding sessions on the left, live transcript/diff/approvals on the right, and a `+` button to launch new sessions or Git worktrees.
  - **Workspace:** Integrated terminals, browser, and worktree manager.
- **No Notch / Multiple Displays:**
  - Prefer a floating widget? Go to **Settings › General › Notch › Placement** and choose **Floating on screen** to drag Nook anywhere on any display.
  - Using multiple monitors? Enable **Show notch on every display** so Nook opens on whichever screen your cursor is on.
- **Full Window:** Press **`⌥⌘W`** (or choose **Open in Window** from the menu bar) for the full desktop workspace, and **`⌘,`** for **Settings**.

---

## Local Brain Quality & Evaluation

Small local models benefit from structured grounding. Under **Settings › Brain › Local Brain Quality**, Nook includes:

- **Evidence First:** Extracts verbatim quotes from retrieved sources in a narrow first pass before drafting the final answer.
- **Verify Answers:** Cross-checks every number, time, email address, and URL in a draft answer against the retrieved sources and automatically regenerates the response if an ungrounded value is detected.
- **Evaluate This Brain:** Runs a built-in 20-question benchmark with known ground-truth answers right on your Mac, reporting accuracy and latency so you can compare models and settings objectively.

See [`docs/ASSISTANT.md`](docs/ASSISTANT.md) and [`scripts/finetune/README.md`](scripts/finetune/README.md) for details on fine-tuning local models for Nook's tool-calling and grounding workflow.

---

## Privacy & Security

Nook is designed around strict user control and local-first privacy:

- **Explicit Approval Gate:** Nothing is executed without clicking **Run** or **Allow**. Even if you enable the optional *Immediately perform minor actions* setting (for music, volume, opening apps, or reminders you explicitly asked for), emails, messages, webhooks, shell commands, calendar events, and proactive suggestions **always** require confirmation.
- **Local-First by Default:** With the built-in MLX model, Apple Foundation Models, Ollama, or LM Studio, no data ever leaves your Mac. When you choose an external AI provider, only your prompt, recognized window text (toggleable in **Settings › Assistant**), and relevant source snippets are sent upon request—raw screen pixels never leave your Mac.
- **"Only on This Mac" Source Lock:** In **Settings › Brain**, mark any source as **Only on this Mac**. External cloud providers are completely blocked from receiving context, tools, screen text, or prior answers derived from those sources—even if you ask for them in your prompt.
- **Prompt-Injection Defenses:** Screen text, calendar titles, emails, web pages, and tool outputs are wrapped as untrusted data with explicit system instructions never to follow commands found inside them. Self-learning memory only learns from your own messages—never from screen text, emails, or web pages.
- **Password & Secret Exclusion:** Password managers and secure input fields (`AXSecureTextField`) are never read by screen OCR or autocomplete. All API keys, bot tokens, and OAuth tokens managed by Nook are stored exclusively in the macOS **Keychain** (`SecretStore`); external coding-agent CLIs manage their own session state under their isolated profile directories.
- **Hardened Runtime & Socket Security:** The Unix domain socket for agent hooks enforces `0600` file permissions and peer UID verification. The Claude Code brain runs in an empty working directory without file or web tools, and `NetworkGuard` blocks private/loopback redirects (SSRF protection).
- **Full Audit Log & Safe Storage:** Every executed action is recorded in a local SQLite audit log (`nook.sqlite`, `audit` table, searchable in **Settings › Privacy & Security**, retained for 90 days). Unreadable user files are preserved alongside a `.unreadable-<date>.json` backup and never overwritten.

Found a security vulnerability? Please report it privately via [SECURITY.md](SECURITY.md).

---

## Documentation

| Topic | Document |
|---|---|
| Assistant, sources & citations | [`docs/ASSISTANT.md`](docs/ASSISTANT.md) |
| Coding-agent integration (`nook_agent`) | [`docs/AGENTS.md`](docs/AGENTS.md) |
| Terminal, browser & PR workspace for agents (MCP) | [`docs/WERKRUIMTE-AGENTS.md`](docs/WERKRUIMTE-AGENTS.md) |
| System-wide autocomplete | [`docs/AUTOCOMPLETE.md`](docs/AUTOCOMPLETE.md) |
| iPhone companion & protocol | [`docs/COMPANION.md`](docs/COMPANION.md) |
| Monorepo structure | [`docs/MONOREPO.md`](docs/MONOREPO.md) |
| Shared macOS UI components | [`docs/UI-COMPONENTS.md`](docs/UI-COMPONENTS.md) |
| Windows, Linux & Android (Tauri) | [`docs/TAURI.md`](docs/TAURI.md) |
| Fine-tuning local models | [`scripts/finetune/README.md`](scripts/finetune/README.md) |
| Third-party attributions | [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) |

---

## Architecture & Repository Layout

Nook is organized as a multi-platform monorepo (see [`docs/MONOREPO.md`](docs/MONOREPO.md)):

```text
nook/
├── apps/
│   ├── macos/               # Native macOS app (Swift, SwiftUI/AppKit, XcodeGen)
│   │   ├── App/             # Entry point, menu bar, AppModel (+ modular extensions), Settings UI
│   │   ├── NotchUI/         # Theme, Nook orb & task ring, cards, notch tabs, main window, workspace UI
│   │   ├── Services/        # Calendar, music, agent hub, approvals, quotas, workspace, MCP, Flow, Notes, Autocomplete
│   │   ├── Brain/           # Model runtimes, unified ToolLoop, source scoping, CommandRisk, grounding, ActionGate
│   │   ├── Core/            # Paths, AppSettings, Keychain (SecretStore), SQLite store, I18n (en/nl/de/fr/es)
│   │   ├── Demo/            # Sample data for previews and Demo Mode
│   │   └── Tests/           # Unit test suite (NookTests)
│   ├── ios/                 # Nook Companion for iPhone (SwiftUI, XcodeGen)
│   ├── tauri/               # Nook for Windows, Linux & Android (Tauri 2: Rust core, Svelte UI)
│   ├── android/             # Points to tauri/
│   ├── windows/             # Points to tauri/
│   └── linux/               # Points to tauri/
├── packages/
│   ├── protocol/            # Shared Companion protocol, ChaCha20-Poly1305 sealing & webhook security
│   └── core/                # Cross-platform Foundation-only Swift core package
├── docs/                    # Architecture & subsystem documentation
└── scripts/                 # Helper scripts (CI core tests, local model fine-tuning)
```

---

## Known Limitations

- **First Build Time & Hardware:** The built-in local model relies on `mlx-swift-lm`, `swift-huggingface`, and `swift-transformers`, which require **Xcode 26+** and an **Apple Silicon Mac**. The initial package resolution and build can take several minutes.
- **Code Signing:** When built from source without an Apple Developer ID certificate, `xcodegen` sets up a self-signed local signing identity once and every build is re-signed with it, so macOS keeps Accessibility/Screen Recording/Keychain permissions across rebuilds (see `apps/macos/Config/local-signing.sh`).
- **App Sandbox:** Nook uses the Hardened Runtime without the App Sandbox because AppleScript automation and managing local coding-agent processes are not permitted inside a sandbox.
- **System Notifications:** macOS does not provide a public API for third-party apps to read or filter notifications from other apps; however, all notifications from your connected coding agents route directly through Nook.

---

## Contributing

Bug reports, feature ideas, translations, and pull requests are very welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request to learn about the architecture, localization coverage tests (`I18nCoverageTests`), and safety guidelines.

The short version:

1. Fork the repo and create a branch (`git checkout -b fix/short-description`).
2. Make your change. Every user-facing string goes through `tr("key")` and needs all five languages (`en`, `nl`, `de`, `fr`, `es`).
3. Run `./scripts/core-tests.sh` before committing.
4. Open a pull request using the [PR template](.github/pull_request_template.md). Commits, branches, code, and docs are written in English.

New here? Look for issues labeled `good first issue`, or help by adding a translation or improving the docs. Coding agents working in this repo should follow [`AGENTS.md`](AGENTS.md). Please also read our [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Community & Support

- **Questions, bugs, and feature requests:** [open an issue](https://github.com/IAMichan/nook/issues/new/choose).
- **Security vulnerabilities:** report privately via [SECURITY.md](SECURITY.md), not in public issues.
- **Like Nook?** Give the repo a ⭐ and tell a friend.

---

## Acknowledgments & License

- Parts of Flow dictation, Call Notetaker, and Autocomplete adapt open-source MIT/Apache-2.0 components; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for full attributions.

Licensed under the [MIT License](LICENSE) © 2026 Michan van der Hoek.
