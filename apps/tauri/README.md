# Nook voor Windows, Linux en Android

Eén app voor drie platformen, gebouwd met [Tauri 2](https://tauri.app). Dezelfde Nook als op de Mac: chatten met je
eigen of een externe AI, Nooks, geheugen, plannen die pas na jouw **Uitvoeren** iets doen, je coding-agents en je
koppelingen. De macOS-app in [`apps/macos`](../macos) is de specificatie: namen, gedrag en teksten volgen die.

> **Status:** vroege versie. Alles uit de Mac-app is geport of staat met een reden op de lijst in
> [docs/TAURI.md](../../docs/TAURI.md). Op Linux is het in de app getest; Windows-code compileert maar is nog niet op een
> echte Windows-pc uitgevoerd, en Android bouwt alleen in de CI.

## Opbouw

```
apps/tauri/
  core/                nook-core: de kern in Rust, zonder Tauri, met de tests
    src/brain/         brein, tool-loop, intenties, bronnen, onderzoek, geheugen, actiepoort
    src/connectors/    agenda's, GitHub, GitLab, clouddiensten, eigen bronnen, OAuth, MCP, WhatsApp
    src/services/      scherm, meedenken, stem, Flow, Notetaker, weekoverzicht
    src/agents/        hub, hooks, IPC, koppelen, accounts
    src/workspace/     sessies, git, limieten, MCP-brug
    src/companion/     companion-protocol, server en client
  src-tauri/           de app: vensters, systeemvak, sneltoetsen, commando's, lijm per gebied
    src/platform/      wat per besturingssysteem verschilt (windows/, linux/, android.rs, desktop.rs, secrets.rs)
    src/tools/         het register van bronnen voor het brein (één regel per bron in `sources()`)
    gen/android/       het Android-project (eigen MainActivity)
  src/                 de interface in Svelte 5 + TypeScript (balk, hoofdvenster, instellingen, per gebied een map)
```

- De kern (`core/`) bouwt en test zonder venster of webview: `cargo test -p nook-core`.
- Wat per platform verschilt, staat achter een trait in `core/src/platform.rs` of `core/src/secrets.rs` en wordt in
  `src-tauri/src/platform/` ingevuld. Een platform dat iets niet kan, zegt dat (`Capabilities`); de interface verbergt het.
- De interface praat alleen via `src/lib/api.ts` met Rust (`invoke` en events `nook-stream`, `nook-updated`).

## Wat er per platform is

| | Windows | Linux | Android |
|---|---|---|---|
| Balk bovenaan het scherm (de "notch"), of zwevend | ✓ | ✓ | — (hele scherm) |
| Hoofdvenster met Nooks, chat en instellingen | ✓ | ✓ | ✓ |
| Systeemvak en globale sneltoetsen | ✓ | ✓ (X11; Wayland zonder globale toetsen) | — |
| Geheimen | Referentiebeheer | Secret Service (GNOME Keyring, KWallet) | afgeschermde app-map |
| Breinen: Ollama, LM Studio, Claude, OpenAI, Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot | ✓ | ✓ | ✓ (lokaal via een server op je netwerk) |
| Claude Code als brein, coding-agents volgen en starten, terminals, git | ✓ | ✓ | — (goedkeuren via de companion) |
| Koppelingen: GitHub, GitLab, agenda's (ICS), Cal.com, Notion, Stripe, Vercel, n8n, Resend, MCP, WhatsApp | ✓ | ✓ | ✓ (MCP via stdio —) |
| Scherm lezen, meekijken, meedenken | ✓ (UI Automation, OCR) | ✓ (AT-SPI, tesseract) | — |
| Muziek | ✓ (mediabediening van Windows) | ✓ (MPRIS) | — |
| Praten en voorlezen | ✓ | ✓ (whisper.cpp of een gekozen dienst; espeak-ng) | — |
| "Hé Nook" | ✓ | — | — |
| Overal dicteren (Flow) en de Notetaker | ✓ | ✓ (X11; systeemgeluid via PulseAudio/PipeWire) | — |
| Companion | server voor de iPhone-app | server voor de iPhone-app | telefoonkant |

## Bouwen

Vereisten: [Rust](https://rustup.rs) (the version in `rust-toolchain.toml`; rustup installs it by itself), [Node.js](https://nodejs.org) 22 en de
[Tauri-vereisten](https://tauri.app/start/prerequisites/) van je platform (Windows: WebView2 en de MSVC-buildtools;
Linux: `libwebkit2gtk-4.1-dev` en vrienden; Android: Android Studio, de NDK en `JAVA_HOME`).

```sh
cd apps/tauri
npm ci
npm run tauri dev          # starten met herladen
npm run tauri build        # installatiebestand (Windows: .msi en .exe, Linux: .deb en .AppImage)
```

Android (`src-tauri/gen/android` staat in de repo, met een eigen `MainActivity`; vereist de Android SDK, NDK 27 en
`NDK_HOME`). De CI-job **Android** levert een ongetekende APK.

```sh
npm run tauri android dev
npm run tauri android build -- --apk
```

Controles, zoals de CI ze draait:

```sh
npm run check && npm test && npm run build
cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

Start-opties: `nook --window` opent meteen het hoofdvenster, `nook --settings` de instellingen.

## Waar vind je wat

- **De balk** bovenaan het scherm: in rust een pil met Nook (een stipje per lopende of wachtende Nook). Wijs ernaar of
  druk **Alt+Ctrl+Spatie** en hij klapt open met de tabs **Nook** (chat en open punten), **Agents** en **Werkruimte**.
  Liever zwevend? **Instellingen › Algemeen › Plek**; sleep hem waarheen je wilt, de plek wordt onthouden.
- **Het hoofdvenster** (**Alt+Ctrl+W** of het systeemvak): al je Nooks links, de chat rechts, en de instellingen.
- **Instellingen › Brein**: kies het brein. Standaard denkt Nook lokaal (Ollama, met modeladvies op basis van je
  werkgeheugen en installeren met één klik); een externe AI of Claude Code kies je zelf.
- **Instellingen › Accounts & koppelingen**: bovenaan wat gekoppeld is, daaronder **Koppel** of **Verbinden** bij elke
  dienst. **Instellingen › Agents**: Claude Code, Codex en de andere agents koppelen (je ziet eerst de diff).
- **Agents** en **Werkruimte**: sessies volgen en starten, goedkeuren in de balk, terminals, de browser en worktrees.
- **Sneltoetsen**: Alt+Spatie praten, Alt+Ctrl+Spatie chatten, Alt+Ctrl+W hoofdvenster, Alt+Ctrl+N meekijken,
  Alt+Ctrl+4 schermdeel, Control+Alt+D vasthouden om te dicteren.
- **Companion**: op de pc bij Instellingen › Companion (koppel de iPhone-app of Nook op Android met de QR-code); op
  Android het tabblad Companion.

## Nog niet

Zie [docs/TAURI.md](../../docs/TAURI.md) voor wat per onderdeel geport is en wat nog niet. Testen tegen nep-diensten
staat daar ook beschreven.
