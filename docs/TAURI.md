# De Tauri-app: wat er van de Mac al geport is

`apps/tauri` brengt Nook naar Windows, Linux en Android. De macOS-app is de specificatie; deze lijst houdt bij wat er
al is.

✓ = geport en in de app getest · ◐ = deels, of alleen gecompileerd en niet echt uitgevoerd · ○ = nog niet · — = kan niet op dit platform

> Windows-code compileert in de CI en lokaal met `cargo check -p nook --target x86_64-pc-windows-gnu`, maar is (nog)
> niet op een echte Windows-pc uitgevoerd. Android bouwt alleen in de CI (job **Android**); de Android SDK was lokaal
> niet te downloaden.

## Kern en chat

| Onderdeel (Mac) | Tauri | Waar |
|---|---|---|
| `AIProvider`, `BrainSelection`, `AppSettings` | ✓ | `core/src/provider.rs`, `core/src/settings.rs` |
| `ToolRunner` (tool-loop, herstel, cache, JSON in tekst) | ✓ | `core/src/brain/tool_loop.rs` |
| Anthropic, OpenAI-compatibel, Ollama (streamen, tools, plaatjes) | ✓ | `core/src/brain/conversations.rs` |
| `BrainService` (prompts, prioriteren, `use_source`, contextbudget) | ✓ | `core/src/brain/service.rs` |
| `ModelProfile`, `ModelAdvisor`, `ModelDownload` (Ollama installeren met één klik) | ✓ | `core/src/brain/profile.rs`, `model_download.rs` |
| `ChatIntent`, `LocalIntent`, `QueryPlan`, `SourceScope`, `Fuzzy`, `NookDates`, `FollowUps` | ✓ | `core/src/brain/` |
| `Research`, `Retrieval` (zelf zoeken, genummerde bronnen) | ✓ | `core/src/brain/research.rs`, `retrieval.rs` |
| `ActionGate`, `CommandRisk`, `Undo`, `NetworkGuard`, `LocalQuality` | ✓ | `core/src/brain/` |
| Geheugen (`Memory`, `NookMemory`, Instellingen › Geheugen) | ✓ (MCP-geheugen importeren ◐) | `core/src/brain/memory.rs`, `tools/memory.rs` |
| Web, weer, grafieken, mailconcepten | ✓ (mail via `mailto:`) | `tools/{web,charts,mail}.rs` |
| `ClaudeCodeBrain` | ◐ (geen echte `claude` getest) | `core/src/brain/claude_code.rs` |
| `NookStore`, `NookChat` (Nooks, `nooks.json`, archief, zoeken) | ✓ | `core/src/store.rs`, `core/src/nooks.rs` |
| `SecretStore` | ✓ | Referentiebeheer, Secret Service, afgeschermde app-map op Android |
| Plannen met Uitvoeren, nooit dubbel uitvoeren, Maak ongedaan | ✓ | `src-tauri/src/commands/plans.rs` |
| Onboarding (welkomstkaart, drie stappen) | ✓ | `src/views/` |
| `AppleIntelligence`, `EmbeddedModel` (MLX), `MacReport` | — | Alleen Apple; lokaal denken gaat via Ollama of LM Studio |

## Koppelingen

| Onderdeel (Mac) | Tauri | Waar |
|---|---|---|
| Raamwerk (Connector, Hub, catalogus, merken) | ✓ | `core/src/connectors/` |
| Agenda's: ICS ("Andere agenda's"), Cal.com, `check_availability` | ✓ | `ics.rs`, `agenda.rs`, `feeds.rs` |
| Systeemagenda's (Apple Agenda) | — | Geen API in deze port |
| GitHub (lezen; beoordelen, samenvoegen, sluiten als actie) | ✓ | `github.rs` |
| Inloggen met GitHub | ◐ | Token plakken of `gh auth token`; device flow wacht op een client-ID |
| Tweede account per dienst, account per chat | ✓ | `accounts.rs`, `ChatAccounts.svelte` |
| GitLab, Vercel, Stripe, Notion, Cal.com, n8n, Resend | ✓ | `gitlab.rs`, `cloud.rs` |
| Eigen bronnen (web-API's, webhooks) | ✓ | `custom.rs` |
| Verbinden met OAuth (Notion, Linear, Stripe, Vercel, Sentry) | ◐ (niet tegen de echte diensten getest) · — Android | `oauth.rs` |
| MCP-client (stdio, HTTP) | ✓ (stdio alleen desktop) | `core/src/connectors/mcp/` |
| WhatsApp live (GOWA) | ◐ (gateway zelf starten; installer ○) | `core/src/connectors/whatsapp/` |
| Portfolio | ○ | |
| Apple Notes, Herinneringen, Mail.app, Berichten, Bear, Things | — | Mac-apps |

## Platformdiensten

| Onderdeel (Mac) | Tauri | Waar |
|---|---|---|
| Scherm lezen (`ScreenReader`, `ScreenContext`, `AppTextReader`) | ✓ Linux (AT-SPI, X11, tesseract) · ◐ Windows (UI Automation, OCR) · — Android | `core/src/services/screen.rs`, `platform/` |
| Schermdeel | ✓ (zonder annoteren) | `services/part.rs` |
| Meekijken, Meedenken | ✓ | `core/src/services/think_along.rs` |
| Muziek (`NowPlayingService`, Muziek-tab) | ✓ MPRIS · ◐ Windows-mediabediening | `platform/linux/mpris.rs`, `platform/windows/media.rs` |
| Systeem: apps, volume, klembord, bestanden, meldingen | ✓ Linux · ◐ Windows | `platform/*`, `tools/{system,files,clipboard}.rs` |
| Stem: voorlezen, spraak naar tekst (whisper.cpp of een gekozen dienst) | ◐ (voorlezen getest; opnemen niet, geen microfoon) | `core/src/services/`, `services/voice.rs` |
| "Hé Nook" | ◐ Windows · — Linux en Android | `platform/windows/speech.rs` |
| Overal aanvullen (`AutocompleteController`, `CompletionSuggestion`, `CompletionPrivacy`, `CompletionEmoji`, Instellingen › Aanvullen) | ◐ Windows (gecompileerd, niet op een echte pc uitgevoerd; Testen-tab ook op Linux) · — Linux en Android | `core/src/services/autocomplete/`, `src-tauri/src/services/autocomplete.rs`, `platform/windows/autocomplete.rs` |
| Flow-dicteren | ◐ (logica met tests; niet met een microfoon getest) | `core/src/services/flow.rs` |
| Notetaker | ◐ (geen sprekerherkenning) | `core/src/services/notes.rs` |
| Vandaag, weekoverzicht (met agentcijfers per project) | ✓ | `core/src/services/recap.rs`, `views/Today.svelte` |
| Nook zelf (bol, ring, geluiden) | ✓ | `components/Orb.svelte`, `lib/sounds.ts` |

## Agents en werkruimte

| Onderdeel (Mac) | Tauri | Waar |
|---|---|---|
| Hub via hooks (Claude Code, Codex, Gemini CLI, Cursor, …) | ✓ | `core/src/agents/`, `nook --hook` / `~/.nook/nook-hook` |
| Vastgelopen sessies afronden (`SessionLiveness`: transcript, het eigen proces van de sessie via de hook) | ◐ (met tests; niet met een echte `claude`) | `core/src/agents/liveness.rs` |
| Meldingen van agents: uitgebreid of compact (Instellingen › Stem en geluid › Meldingen), Oké met aftelring | ◐ (gecompileerd; niet in de app getest) | `views/Bar.svelte`, `views/agents/AgentAlerts.svelte` |
| Leesbare MCP-toolnamen (`McpToolName`) in goedkeuringen, tijdlijn en MCP-koppelingen | ✓ | `core/src/agents/mcp_name.rs` |
| Koppelen met diff en backup (`AgentConfigInstaller`) | ✓ | `core/src/agents/` |
| Goedkeuren in de balk, meerkeuzevragen (een open paneel blijft staan en vraagt in een smalle balk) | ✓ | `views/agents/` |
| Agents-tab, nieuwe sessie (met denkniveau; keuzes onthouden zodra je ze maakt), tijdlijn | ✓ | `views/agents/` |
| Diff met regelnummers en gemarkeerde woorden (`UnifiedDiff`) | ✓ | `lib/workspace/unifiedDiff.ts`, `views/agents/UnifiedDiffView.svelte` |
| Werkruimte-sessies: Claude Code, Codex `exec`, Gemini CLI, wachtrij, hervatten | ✓ (met een nep-`claude` getest) | `core/src/workspace/manager.rs` |
| Codex app-server, ACP-agents, Antigravity | ○ | |
| Delegeren, overdragen, geplande taken, webhooks, automatische titels | ○ | |
| Git: wijzigingen, commit, push, pull request (alle GitHub-accounts, eigenaar eerst), worktrees | ✓ | `core/src/workspace/` |
| Terminals (portable-pty + xterm.js), browser, dev-servers | ✓ (geen schermafbeelding van de browser) | `src-tauri/src/workspace/` |
| Werkruimte voor agents (MCP-brug `nook --mcp`) | ✓ | `src-tauri/src/workspace/` |
| Gebruik en limieten | ◐ | `views/workspace/` |

## Companion en Android

| Onderdeel (Mac) | Tauri | Waar |
|---|---|---|
| Companion-protocol (`CompanionModels`, `CompanionSeal`, `CompanionPush`) | ✓ (testvectoren) | `core/src/companion/` |
| Companion-server op Windows en Linux (iPhone-app koppelen): alle werkruimte- en hook-sessies; goedkeuren, antwoorden, sturen, stoppen | ✓ (sessies uit een terminal: alleen goedkeuren en antwoorden) | `core/src/companion/`, `src-tauri/src/companion/backend.rs` |
| Pushmeldingen via APNs | ◐ (niet tegen Apple getest) | `core/src/companion/apns.rs` |
| Android als companion (zoals de iPhone-app) | ✓ (meldingen alleen terwijl de app draait; geen FCM) | `src/views/companion/` |
| Android-project, telefoonindeling, Delen met Nook, terugknop | ◐ (APK alleen via de CI) | `src-tauri/gen/android` |
| Geheimen in de Android Keystore | ○ (afgeschermde app-map zonder back-up) | `platform/secrets.rs` |

## Nog te doen

- De interface is alleen Nederlands; de Mac heeft ook Engels en Duits.
- Echt testen op Windows en op een Android-toestel.
- Wat hierboven ○ staat.

## Testen tegen nep-diensten

- Nep-brein: start een eigen server en zet `OLLAMA_HOST=http://127.0.0.1:<poort>`.
- Nep-API's, alleen in debug-builds: `NOOK_GITHUB_API_URL` en `NOOK_<DIENST>_API_URL`. ICS-feeds accepteren `http://` alleen voor 127.0.0.1 en localhost.
- Nep-agent: een script `claude` in `PATH` dat stream-json uitspuugt.
