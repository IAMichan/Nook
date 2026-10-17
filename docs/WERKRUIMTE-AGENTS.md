# De werkruimte voor agents

> **English summary:** Coding agents (Claude Code, Codex) can now use Nook's own workspace: start long-running commands in a visible Nook terminal, open and check pages in Nook's browser (including console errors and screenshots), and propose pull requests that you approve in the notch. They reach it through a small local MCP server (`nook-mcp`) that forwards each request to Nook. Sessions Nook starts get it automatically; agents you start yourself can be linked with one click. Nook is the gatekeeper: reading runs directly, commands that are not clearly harmless and every pull request wait for your approval, dangerous commands are refused.

## Waarom

De tab Agents had al een terminal en een browser naast elke sessie, maar alleen **jij** kon ze gebruiken. De agent zelf draaide zijn commando's onzichtbaar in zijn eigen shell, kon geen pagina bekijken en kon geen pull request voorstellen. Daardoor bleef je heen en weer schakelen: de dev-server zelf starten, zelf in de browser kijken, zelf de PR openen.

Doel: de agent werkt in **dezelfde werkruimte als jij**, zichtbaar naast zijn sessie, en Nook blijft de poortwachter.

## Uitgangspunten

1. **Zichtbaar.** Wat een agent via Nook start of opent, staat naast zijn sessie in de tab Agents: zijn terminal (met zijn logo op het tabblad) en de browser ("Geopend door Claude Code"). Een stipje op het terminal- of browsericoon zegt dat er iets nieuws is.
2. **Nook beslist, niet de agent.** De rechten van de agent zelf verruimen Nooks tools nooit. Lezen gaat direct; een commando dat niet duidelijk onschuldig is en elk pull request wachten op jouw **Toestaan**; gevaarlijke commando's weigert Nook altijd (`CommandRisk`). Plan-modus mag alleen kijken.
3. **Eén goedkeuringsweg.** Een verzoek verschijnt als dezelfde kaart als elke andere agentvraag (`ApprovalCenter`, `ApprovalView`), in de notch en in de sessie zelf. Alles komt in het audit-logboek (`agent_terminal_run`, `agent_pull_request_create`, …).
4. **Lokaal en zonder extra software.** Net als het hook-script is de brug een Perl-script (Perl staat op elke Mac) dat via een Unix-socket praat die alleen jouw gebruiker kan openen. Draait Nook niet, dan is de brug een lege MCP-server en werkt de agent gewoon door.
5. **Geen tweede pad.** De brug gebruikt de bestaande onderdelen: `TerminalStore`, `BrowserStore`, `GitService`, `GitHubPullRequests`, `ApprovalCenter`.

## Hoe het werkt

```
Claude Code / Codex ──stdio (MCP)──▶ nook-mcp (Perl) ──bridge.sock──▶ WorkspaceBridge (Nook)
                                                                         │
                     ┌───────────────────────────────────────────────────┼──────────────────────────┐
                     ▼                         ▼                         ▼                          ▼
              BridgePolicy            TerminalStore              BrowserStore            GitService + GitHub
        (toestaan/vragen/weigeren)   (zichtbare terminal)   (pagina, console, screenshot)   (push + pull request)
                     │
                     ▼
              ApprovalCenter ──▶ kaart in de notch / in de sessie
```

| Onderdeel | Bestand | Rol |
|---|---|---|
| Protocol, regels, startargumenten | `Services/Workspace/WorkspaceBridgeProtocol.swift` | `BridgeTool` (de tools en hun schema), `BridgePolicy`, `BridgeURLPolicy`, `BridgeLaunch`, `BridgeRPC` (JSON-RPC). Alleen Foundation, volledig getest. |
| MCP-server | `Services/Workspace/WorkspaceBridgeScript.swift` | Het Perl-script `nook-mcp` (in `~/Library/Application Support/Nook/`, symlink `~/.nook/nook-mcp`). Draagt alleen berichten over. |
| Service | `Services/Workspace/WorkspaceBridge.swift` | Socket `bridge.sock`, herkent de sessie, past de regels toe, vraagt toestemming, voert de tools uit, houdt bij wat je nog niet zag. |
| Starten | `Services/Workspace/AgentProcess.swift` | Sessies die Nook start krijgen de brug op hun opdrachtregel (zie hieronder). |
| Weergave | `NotchUI/Pills/SessionTools.swift`, `TerminalSessions.swift`, `BrowserView.swift`, `AgentRunPanel.swift`, `AgentSessionDetail.swift` | Stipjes, agentlogo op terminaltabbladen, "Geopend door …" in de browser, goedkeuring in de sessie. |
| Instellingen | `App/Settings/SettingsBlocks.swift` | **Instellingen › Agents › Werkruimte › Werkruimte voor agents**. |

### Welke sessie belt?

1. `NOOK_RUN_ID` in de omgeving: een sessie die Nook zelf draait (Nook geeft hem expliciet mee, ook aan Codex, dat MCP-servers maar weinig variabelen doorgeeft).
2. Anders een lopende Nook-sessie in dezelfde map.
3. Anders een agent die je zelf in een terminal startte (herkend aan de map, met de naam uit de hooks als die bekend is).

### Sessies die Nook start

- **Claude Code:** `--mcp-config` met de server `nook` (naast je eigen MCP-servers) en `--allowedTools mcp__nook`: Claude vraagt niet nog eens, want Nook beslist per aanroep zelf. Een korte toelichting gaat achter je eigen instructies in `--append-system-prompt`.
- **Codex:** `-c mcp_servers.nook.command=…`, `args`, `env = { NOOK_RUN_ID = … }` en `tool_timeout_sec=900`, zodat wachten op jouw goedkeuring niet na een minuut afbreekt. De toelichting gaat voor de eerste opdracht.

### Agents die je zelf start

Bij **Instellingen › Agents › Werkruimte** koppel je de brug met één klik aan Claude Code of Codex. Nook draait dan zichtbaar in de terminal:

```sh
claude mcp add --scope user nook -- ~/.nook/nook-mcp --agent claude-code
codex mcp add nook -- ~/.nook/nook-mcp --agent codex
```

Start de agent daarna opnieuw.

## De tools

| Tool | Wat het doet | Regel |
|---|---|---|
| `workspace_info` | Map, branch, wijzigingen, terminals in deze map, de open pagina, of pull requests kunnen, en de regels. | direct |
| `terminal_run` | Start een commando in een nieuwe, zichtbare terminal van Nook (dev-server, watcher). Geeft een id (`t3`) en de eerste uitvoer. | duidelijk onschuldig: direct · anders: jouw OK · gevaarlijk: geweigerd · alle rechten: direct behalve gevaarlijk |
| `terminal_read` | De laatste regels van een terminal in de eigen map, met of hij nog loopt en de exitcode. | direct |
| `terminal_list` | De terminals in de eigen map, en wie ze startte. | direct |
| `terminal_stop` | Ctrl-C (en eventueel sluiten), alleen voor terminals die de agent zelf startte. | direct |
| `browser_open` | Opent een pagina in Nooks browser en wacht tot hij geladen is. Alleen https, en http op deze Mac (`localhost`, `127.0.0.1`, `*.localhost`). | direct |
| `browser_read` | Titel, adres, zichtbare tekst en console-fouten en -waarschuwingen sinds het laden. | direct |
| `browser_screenshot` | Een JPEG van de pagina, om layout te controleren. | direct |
| `pull_request_create` | Pusht de branch en opent het pull request met jouw GitHub-koppeling (of de pagina op github.com om af te ronden). | altijd jouw OK |

In **Plan-modus** werken alleen de leestools. Staat **Agents mogen de terminal, browser en pull requests van Nook gebruiken** uit, dan werkt geen enkele tool en krijgen nieuwe sessies de brug niet meer mee.

## Veiligheid

- De socket staat in Nooks map (alleen jouw gebruiker, `0700`), het bestand zelf is `0600` en elke verbinding wordt gecontroleerd op jouw gebruikers-id (`UnixSocketServer`).
- De kaart toont het **hele** commando of het hele pull request (repo, branch → base, titel, beschrijving), met de map en de waarschuwing van `CommandRisk`. Wat je toestaat, is wat je zag.
- Een terminal lezen kan alleen in de eigen map; stoppen alleen voor eigen terminals. Typen in een shell kan een agent niet: dat zou de controle per commando omzeilen.
- De browser bewaart niets tussen het openen van Nook door (geen cookies of opslag op schijf) en opent geen `file:`- of andere schema's.
- Stopt de agent terwijl een verzoek wacht, dan verdwijnt de kaart. Na tien minuten zonder antwoord hoort de agent "niet toegestaan".
- Pagina-inhoud en terminaluitvoer gaan alleen naar de agent die erom vraagt; Nook voert er zelf niets mee uit.

## Testen

- `WorkspaceBridgeTests`: de regels per tool, rechten en risico; welke adressen de browser opent; de startargumenten voor Claude Code en Codex; JSON-RPC (`initialize`, notificaties, `tools/list`, `tools/call` met afbeelding, fouten); tool-namen in de tijdlijn.
- `nook-mcp` is end-to-end getest tegen een nagebootste socket: doorsturen, notificaties zonder antwoord, grote antwoorden (screenshots) en het gedrag zonder Nook.
- Op een Mac: start een sessie met "Start de dev-server en controleer de homepage", keur `npm run dev` goed, en zie de terminal en de browser met een stipje naast de sessie verschijnen.

## Faseplan

| Fase | Inhoud | Stand |
|---|---|---|
| 1 | Protocol, regels en MCP-server; terminal, browser en pull requests als tools; automatisch voor sessies die Nook start (Claude Code, Codex) | ✅ |
| 2 | Zichtbaarheid in de tab Agents: stipjes, agentlogo op terminaltabbladen, "Geopend door …", goedkeuring in de sessie zelf; audit-log | ✅ |
| 3 | Koppelen aan agents buiten Nook (één klik in Instellingen), schakelaar om alles uit te zetten | ✅ |
| 4 | Vervolg: dezelfde brug voor Gemini CLI, Cursor en Copilot CLI (alle drie ondersteunen MCP); per project onthouden welke commando's altijd mogen; een melding in de notch als een agent een pagina opent terwijl je elders bent; de browser per sessie in plaats van één gedeelde | open |

## Bekende beperkingen

- `nook-mcp` handelt verzoeken na elkaar af: terwijl een pull request op jouw goedkeuring wacht, wacht een volgende aanroep van dezelfde agent ook.
- Er is één browser voor alle sessies; de laatste agent die iets opende staat erboven.
- Een screenshot lukt het best als de browser zichtbaar is (WebKit tekent een verborgen pagina niet altijd).
- Nook kan dit niet bouwen of draaien op Linux; de macOS-CI (build + `NookTests`) controleert elke wijziging.
