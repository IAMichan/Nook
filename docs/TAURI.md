# De Tauri-app: wat er van de Mac al geport is

`apps/tauri` brengt Nook naar Windows, Linux en Android. De macOS-app is de specificatie; deze lijst houdt bij wat er
al is. ✓ = geport en getest, ◐ = deels, ○ = nog niet, — = kan niet op dit platform.

## Kern

| Onderdeel (Mac) | Tauri | Waar |
|---|---|---|
| `AIProvider`, `BrainSelection` | ✓ | `core/src/provider.rs`, `core/src/settings.rs` |
| `ToolRunner` (tool-loop, herstel, cache, JSON in tekst) | ✓ | `core/src/brain/tool_loop.rs` |
| Anthropic, OpenAI-compatibel, Ollama (streamen, tools, plaatjes) | ✓ | `core/src/brain/conversations.rs` |
| `BrainService` (prompts, gating, vervolgvoorstellen) | ◐ | `core/src/brain/service.rs` |
| `NookStore` (open punten, logboek, geheugen-tabellen) | ✓ | `core/src/store.rs` |
| `NookChat` (Nooks, `nooks.json`, archief, zoeken) | ✓ | `core/src/nooks.rs` |
| `AppSettings` | ✓ | `core/src/settings.rs` |
| `SecretStore` | ✓ | `core/src/secrets.rs`, `src-tauri/src/platform/secrets.rs` |
| Plannen met Uitvoeren, nooit dubbel uitvoeren | ✓ | `src-tauri/src/commands/mod.rs` |

## Interface

| Onderdeel | Tauri |
|---|---|
| Balk bovenaan (notch) en zwevend | ✓ |
| Hoofdvenster met Nooks en chat | ✓ |
| Markdown, bronnen, vervolgknoppen, plankaart | ✓ |
| Instellingen: Algemeen, Brein, Geheugen, Privacy | ✓ |
| Systeemvak, globale sneltoetsen, één exemplaar | ✓ |
