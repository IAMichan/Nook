# Nook voor Windows, Linux en Android

Eén app voor drie platformen, gebouwd met [Tauri 2](https://tauri.app). Dezelfde Nook als op de Mac: chatten met je
eigen of een externe AI, Nooks, geheugen, plannen die pas na jouw **Uitvoeren** iets doen, je coding-agents en je
koppelingen. De macOS-app in [`apps/macos`](../macos) is de specificatie: namen, gedrag en teksten volgen die.

> **Status:** vroege versie. Wat er nu werkt staat hieronder; wat nog komt staat onder **Nog niet**.

## Opbouw

```
apps/tauri/
  core/          nook-core: de kern in Rust, zonder Tauri (brein, tool-loop, opslag, Nooks, instellingen, geheimen)
  src-tauri/     de app: vensters, systeemvak, sneltoetsen, commando's voor de interface, platformlaag
    src/platform/  wat per besturingssysteem verschilt (geheimen, balk, systeemvak, …)
  src/           de interface in Svelte 5 + TypeScript (balk bovenaan, hoofdvenster, instellingen)
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

## Bouwen

Vereisten: [Rust](https://rustup.rs) (stable), [Node.js](https://nodejs.org) 22 en de
[Tauri-vereisten](https://tauri.app/start/prerequisites/) van je platform (Windows: WebView2 en de MSVC-buildtools;
Linux: `libwebkit2gtk-4.1-dev` en vrienden; Android: Android Studio, de NDK en `JAVA_HOME`).

```sh
cd apps/tauri
npm ci
npm run tauri dev          # starten met herladen
npm run tauri build        # installatiebestand (Windows: .msi en .exe, Linux: .deb en .AppImage)
```

Android:

```sh
npm run tauri android init   # eenmalig, maakt src-tauri/gen/android
npm run tauri android dev
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
- **Instellingen › Brein**: kies het brein. Standaard denkt Nook lokaal (Ollama); een externe AI kies je zelf.

## Nog niet

Zie de takenlijst in [docs/TAURI.md](../../docs/TAURI.md).
