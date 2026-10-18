# Wat Nook leert

> **English summary:** A study of (octocat/hello-world, commit 13aa882c) and what Nook took from it for the Agents tab: folded turns, grouped tool calls, a live activity line, a message queue, "done" markers, dev-server discovery, project scripts, richer Codex reasoning and clearer worktree errors. The second half is the roadmap for the larger change points to: talking to every agent over a long-lived protocol (Claude Code over stdin, Codex `app-server`, ACP for Gemini/Antigravity/others) instead of one process per turn.

 is een desktop-app voor coding-agents die veel dingen goed doet. We hebben de broncode grondig bestudeerd: de tijdlijn, het invoerveld, goedkeuringen, git, de werkruimte, en vooral hoe het per agent het gesprek ophaalt, berichten verstuurt en gebruik meet. Dit document zegt wat Nook al heeft overgenomen en wat de volgende stap is.

## Overgenomen

| | In Nook | Waar |
|---|---|---|
| Een afgeronde beurt klapt in tot "Worked for 2m 13s" | "Gewerkt 2m 13s" tussen vraag en antwoord; een lopende beurt of een beurt met een fout blijft open | `TimelinePresentation`, `TimelineBlocks.swift` |
| Opeenvolgende tool-aanroepen als één zin | "3 commando's uitgevoerd en 2 bestanden gewijzigd"; bewerkingen tellen bestanden, fouten kleuren de regel | idem |
| Eén live regel met de kop van de laatste gedachte | Huidige actie, kop van de laatste denkstap, timer | `LiveActivityRow` |
| Berichten in de wachtrij terwijl de agent werkt | Wachtrij boven het invoerveld, weg te halen, gaat na een goede beurt | `WorkspaceManager.enqueue`, `QueuedMessagesStrip` |
| "Completed" alleen zolang ongezien | "klaar" in groen in de lijst tot je de sessie opent | `SessionVisits` |
| Dev-servers vinden met `lsof` | Servers die in de map van de sessie luisteren als knopjes boven de browser; ook in `workspace_info` voor de agent | `DevServerScanner`, `DevServerStrip` |
| Projectscripts in `legacy-scripts.json` | `nook.json` of `legacy-scripts.json` (zelfde schema): scripts met één klik vanuit de terminal, `runOnWorktreeCreate` na een nieuwe worktree, `previewUrl` en `autoOpenPreview` | `ProjectScripts`, `SessionTerminalsView` |
| Codex `summary: "detailed"` | `-c model_reasoning_summary="detailed"`: Codex laat zien hoe hij denkt | `AgentCommand` |
| "Checked out elsewhere"-herkenning | Duidelijke melding als een branch al in een andere worktree staat | `GitService.friendlyWorktreeError` |
| Eén MCP-server voor de agent (browser, PR's) | Werkruimte-brug, mét `terminal_run` (die niet heeft) | `docs/WERKRUIMTE-AGENTS.md` |

Al eerder aanwezig of al gelijk: gebruik van Claude via `api/oauth/usage` met dezelfde headers, tokens uit Claude-transcripts ontdubbeld op bericht en request, een eigen account-map per account (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).

## Hoe Nook nu met elke agent praat

Nook start niet langer per beurt een nieuw proces. Per sessie draait één verbinding die tussen beurten blijft bestaan, net als bij. De berichtvormen komen uit de schema's die Codex en ACP zelf genereren.

| Agent | Route | Wat dat oplevert | Terugval |
|---|---|---|---|
| Codex | `codex app-server`, JSON-RPC per regel: `initialize`, `thread/start`/`thread/resume`, `turn/start` (met `summary: "detailed"`), `turn/steer`, `turn/interrupt` | Goedkeuringen (`acceptForSession` = Altijd), vragen (`requestUserInput`), **bijsturen tijdens een beurt**, live antwoord, denkstappen en commando-uitvoer, tokens per beurt en contextvenster, live limieten | `codex exec --json` als deze Codex geen bruikbare app-server heeft |
| Claude Code | Eén `claude -p --input-format stream-json` per sessie; na `result` blijft het proces wachten op het volgende bericht | Vervolg zonder herstart (cache blijft warm), AskUserQuestion als vraagpaneel (antwoorden als `updatedInput.answers`), ExitPlanMode als plankaart met **Voer plan uit**, live `rate_limit_event` | Nieuw proces met `--resume` bij ander model, andere modus of rechten |
| Gemini CLI | ACP: `gemini --acp` | Toestemming in Nook, gedachten, tool-aanroepen, context | Headless `--output-format stream-json` bij een oude versie |
| OpenCode | ACP: `opencode acp` | idem, plus kosten | — |
| Cursor | ACP: `cursor-agent acp` | idem | — |
| Grok | ACP: `grok agent stdio` (`--always-approve` bij volledige rechten) | idem | — |

ACP in Nook: `initialize` (protocolversie 1, geen bestands- of terminaltoegang voor de agent), `session/new` of `session/load` (de herhaling van een geladen gesprek wordt overgeslagen, want Nook bewaart de tijdlijn zelf), `session/set_mode` voor Plan, `session/set_model`, `session/prompt`, `session/cancel`. Toestemmingsverzoeken (`session/request_permission`) gaan naar jou, of worden meteen toegestaan als de rechten van de sessie dat zeggen: lezen altijd, bewerken bij "bewerkingen toestaan", alles bij volledige rechten, en in Plan-modus alleen lezen. De werkruimte-brug gaat mee als MCP-server in `session/new` (ACP), `thread/start.config.mcp_servers` (Codex) en `--mcp-config` (Claude Code).

## Terugzetpunten per beurt

Voor sessies in een eigen worktree maakt Nook vóór de eerste beurt en na elke beurt een momentopname: een tijdelijke index (`read-tree HEAD`, `add -A`, `write-tree`, `commit-tree`, `update-ref refs/nook/checkpoints/<sessie>/<n>`). De branch, HEAD en je staging veranderen niet. Rechtsklik op een eigen bericht › **Bestanden terugzetten naar vóór dit bericht** zet de bestanden terug: gewijzigde en verwijderde bestanden komen terug, bestanden die later zijn toegevoegd verdwijnen, genegeerde bestanden blijven. Het gesprek blijft staan. Dat kan alleen als de sessie stilstaat en niemand anders in die map werkt.

## Nog niet gebouwd

- **Antigravity via ACP.** Daarvoor is Google's `agy_acp_server` nodig (een download van ± 280 MB) met een eigen inlogstroom (`authenticate` met `oauth-personal` en een autorisatie-URL in de uitvoer). Tot dan leest Nook Antigravity uit zijn transcript en stuurt het berichten via `agentapi`.
- **Bijsturen bij Claude Code** (`"priority": "now"`): niet publiek gedocumenteerd, dus Nook zet berichten voor Claude in de wachtrij tot de beurt klaar is. Codex stuurt Nook wel echt bij.
- **Modellenlijsten van de agent zelf** (`model/list` bij Codex, `availableModels` bij ACP) in plaats van de bekende plus recent gebruikte modellen.
- Automatische sessietitels, één slimme git-knop (commit, push en pull request), hervatten zodra een limiet vrij is.
