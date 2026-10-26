# Nook for Windows, Linux, and Android

One app for three platforms, built with [Tauri 2](https://tauri.app). The same Nook as on the Mac: chat with your own
or an external AI, Nooks, memory, plans that only do something after you press **Run**, your coding agents, and your
connectors. The macOS app in [`apps/macos`](../macos) is the specification: names, behavior, and copy follow it.

> **Status:** early version. Everything from the Mac app has either been ported or is on the list in
> [docs/TAURI.md](../../docs/TAURI.md) with a reason. On Linux it has been tested in the app; Windows code compiles but
> has not yet been run on a real Windows PC, and Android builds only in CI.

> **Interface language:** the Tauri app's interface is Dutch-only for now. Menu paths below give the English name with
> the Dutch label you will see in the app in parentheses. Adding English and the other Mac languages is one of the
> most useful things you can contribute; see [CONTRIBUTING.md](../../CONTRIBUTING.md#windows-linux--android-tauri).

## Layout

```
apps/tauri/
  core/                nook-core: the core in Rust, without Tauri, with the tests
    src/brain/         brain, tool loop, intents, sources, research, memory, action gate
    src/connectors/    calendars, GitHub, GitLab, cloud services, custom sources, OAuth, MCP, WhatsApp
    src/services/      screen, Think Along, voice, Flow, Notetaker, weekly recap
    src/agents/        hub, hooks, IPC, linking, accounts
    src/workspace/     sessions, git, limits, MCP bridge
    src/companion/     companion protocol, server, and client
  src-tauri/           the app: windows, tray, hotkeys, commands, glue per area
    src/platform/      what differs per operating system (windows/, linux/, android.rs, desktop.rs, secrets.rs)
    src/tools/         the brain's registry of sources (one line per source in `sources()`)
    gen/android/       the Android project (custom MainActivity)
  src/                 the interface in Svelte 5 + TypeScript (bar, main window, settings, one folder per area)
```

- The core (`core/`) builds and tests without a window or webview: `cargo test -p nook-core`.
- What differs per platform sits behind a trait in `core/src/platform.rs` or `core/src/secrets.rs` and is filled in
  under `src-tauri/src/platform/`. A platform that can't do something says so (`Capabilities`); the interface hides it.
- The interface talks to Rust only through `src/lib/api.ts` (`invoke` and the events `nook-stream`, `nook-updated`).

## What each platform has

| | Windows | Linux | Android |
|---|---|---|---|
| Bar at the top of the screen (the "notch"), or floating | ✓ | ✓ | — (full screen) |
| Main window with Nooks, chat, and settings | ✓ | ✓ | ✓ |
| Tray and global hotkeys | ✓ | ✓ (X11; Wayland without global hotkeys) | — |
| Secrets | Credential Manager | Secret Service (GNOME Keyring, KWallet) | private app folder |
| Brains: Ollama, LM Studio, Claude, OpenAI, Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot | ✓ | ✓ | ✓ (local via a server on your network) |
| Claude Code as a brain, following and starting coding agents, terminals, git | ✓ | ✓ | — (approve via the companion) |
| Connectors: GitHub, GitLab, calendars (ICS), Cal.com, Notion, Stripe, Vercel, n8n, Resend, MCP, WhatsApp | ✓ | ✓ | ✓ (MCP via stdio —) |
| Reading the screen, Look Along, Think Along | ✓ (UI Automation, OCR) | ✓ (AT-SPI, tesseract) | — |
| Music | ✓ (Windows media controls) | ✓ (MPRIS) | — |
| Talking and reading aloud | ✓ | ✓ (whisper.cpp or a chosen service; espeak-ng) | — |
| "Hey Nook" | ✓ | — | — |
| Dictation everywhere (Flow) and the Notetaker | ✓ | ✓ (X11; system audio via PulseAudio/PipeWire) | — |
| Companion | server for the iPhone app | server for the iPhone app | phone side |

## Building

Requirements: [Rust](https://rustup.rs) (the version in `rust-toolchain.toml`; rustup installs it by itself),
[Node.js](https://nodejs.org) 22, and the [Tauri prerequisites](https://tauri.app/start/prerequisites/) for your
platform (Windows: WebView2 and the MSVC build tools; Linux: `libwebkit2gtk-4.1-dev` and friends; Android: Android
Studio, the NDK, and `JAVA_HOME`).

```sh
cd apps/tauri
npm ci
npm run tauri dev          # run with hot reload
npm run tauri build        # installer (Windows: .msi and .exe, Linux: .deb and .AppImage)
```

Android (`src-tauri/gen/android` is in the repo, with a custom `MainActivity`; requires the Android SDK, NDK 27, and
`NDK_HOME`). The CI job **Android** produces an unsigned APK.

```sh
npm run tauri android dev
npm run tauri android build -- --apk
```

Checks, as CI runs them:

```sh
npm run check && npm test && npm run build
cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

Launch options: `nook --window` opens the main window right away, `nook --settings` opens settings.

## Where to find what

- **The bar** at the top of the screen: at rest a pill with Nook (a dot per running or waiting Nook). Hover over it or
  press **Alt+Ctrl+Space** and it opens with the tabs **Nook** (chat and open items), **Agents**, and **Workspace**
  (*Werkruimte*). Prefer it floating? **Settings › General › Position** (*Instellingen › Algemeen › Plek*); drag it
  wherever you like and the position is remembered.
- **The main window** (**Alt+Ctrl+W** or the tray): all your Nooks on the left, the chat on the right, and settings.
- **Settings › Brain** (*Instellingen › Brein*): choose the brain. By default Nook thinks locally (Ollama, with model
  advice based on your memory and one-click install); an external AI or Claude Code is your own choice.
- **Settings › Accounts & connections** (*Accounts & koppelingen*): what is connected at the top, below it **Connect**
  (*Koppel* or *Verbinden*) for each service. **Settings › Agents**: link Claude Code, Codex, and the other agents
  (you see the diff first).
- **Agents** and **Workspace**: follow and start sessions, approve in the bar, terminals, the browser, and worktrees.
- **Hotkeys**: Alt+Space talk, Alt+Ctrl+Space chat, Alt+Ctrl+W main window, Alt+Ctrl+N Look Along, Alt+Ctrl+4 screen
  region, hold Control+Alt+D to dictate.
- **Companion**: on the PC under Settings › Companion (pair the iPhone app or Nook on Android with the QR code); on
  Android the Companion tab.

## Not yet

See [docs/TAURI.md](../../docs/TAURI.md) for what has been ported per part and what hasn't. Testing against fake
services is described there too.
