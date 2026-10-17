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

## Volgende stap: een langlopend protocol per agent

Het grootste verschil met zit niet in de weergave maar in hoe Nook met agents praat. Nook start nu per beurt een nieuw proces (`claude -p … --resume`, `codex exec --json … resume`, `gemini --output-format stream-json --resume`). houdt per sessie één verbinding open. Daardoor kan het tijdens een beurt bijsturen, krijgt het denkstappen en limieten live binnen, en hoeft het na een herstart niets uit bestanden te raden.

Dit is bewust nog niet gebouwd: het raakt het hart van elke sessie en moet tegen de echte agents worden getest, wat in deze omgeving (Linux, geen Xcode) niet kan. Hieronder staat per agent precies wat er moet gebeuren.

### Claude Code: één proces per sessie

- Laat stdin open na `result` in plaats van het te sluiten; stuur een vervolg als nieuwe regel `{"type":"user","message":{"role":"user","content":…}}`. Sluit pas na een tijd zonder activiteit.
- Bijsturen tijdens een beurt: dezelfde regel met `"priority":"now"`.
- Model en rechten tussen beurten wijzigen zonder herstart: `control_request` met `subtype` `set_model` of `set_permission_mode`; stoppen met `interrupt` (dat laatste doet Nook al).
- Goedkeuringen (`can_use_tool`) beantwoordt Nook al. Toevoegen: `AskUserQuestion` beantwoorden met `{"behavior":"allow","updatedInput":{"questions":…,"answers":{"<vraag>":"<antwoord>"}}}` en `ExitPlanMode` weigeren met het plan als kaart ("Plan klaar → Uitvoeren").
- Live limieten uit `rate_limit_event` (`rate_limit_info.rateLimitType` `five_hour`/`seven_day`, `utilization` 0–1, `resetsAt` in seconden).
- Denkstappen tijdens het streamen: `stream_event` → `content_block_delta` met `thinking_delta`. zet daarbij `--thinking-display summarized`; die vlag vraagt een recente Claude Code (≥ 2.1.x) en moet dus alleen worden meegegeven als de versie het ondersteunt.

### Codex: `codex app-server` in plaats van `codex exec`

Eén proces per sessie, JSON-RPC per regel over stdin/stdout (Nook gebruikt `app-server` al om limieten te lezen in `CodexUsage`).

| Doel | Bericht |
|---|---|
| Starten | `initialize {clientInfo, capabilities:{experimentalApi:true}}`, daarna de notificatie `initialized` |
| Gesprek | `thread/start {cwd, model, config}` of `thread/resume {threadId, excludeTurns:true, cwd}` |
| Beurt | `turn/start {threadId, input:[{type:"text",text}], cwd, model, effort, summary:"detailed", approvalPolicy, sandboxPolicy}` |
| Bijsturen | `turn/steer {threadId, expectedTurnId, input}` |
| Stoppen | `turn/interrupt {threadId, turnId}` |
| Geschiedenis | `thread/read {threadId, includeTurns:true}` (bij `historyMode:"paginated"`: `thread/turns/list`) |
| Goedkeuren | verzoeken `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` → `{decision:"accept"\|"acceptForSession"\|"decline"\|"cancel"}` |
| Vragen | `item/tool/requestUserInput` → `{answers:{<id>:{answers:[…]}}}` |
| Live | `item/agentMessage/delta`, `item/reasoning/summaryTextDelta`, `item/commandExecution/outputDelta`, `turn/completed`, `thread/tokenUsage/updated` (met `modelContextWindow`), `account/rateLimits/updated` |
| Modellen en account | `model/list`, `account/read`, `account/rateLimits/read` |

Rechten ze vertaalt: vragen = `untrusted` + `readOnly`; bewerkingen toestaan = `on-request` + `workspaceWrite`; alles = `never` + `dangerFullAccess`. Dit geeft Codex in één keer goedkeuringen, vragen, bijsturen, live denkstappen en het contextvenster.

### Gemini CLI, Antigravity en anderen: één ACP-client

ACP (Agent Client Protocol) is JSON-RPC over stdio dat Gemini CLI, Antigravity (`agy_acp_server`), Grok, Copilot en andere agents spreken.

- `initialize {protocolVersion, clientCapabilities}`, eventueel `authenticate {methodId}`.
- `session/new {cwd, mcpServers}`, of `session/load` (speelt het hele gesprek opnieuw af als `session/update`) en `session/resume`; `session/list` om bestaande gesprekken te tonen.
- `session/prompt {sessionId, prompt:[…]}`, `session/cancel`, `session/set_mode`, `session/set_model`.
- `session/update` met `agent_message_chunk`, `agent_thought_chunk` (denkstappen), `tool_call`/`tool_call_update` (met `kind`: read, edit, execute, search, fetch…), `plan`, `usage_update` (context en kosten).
- Goedkeuren: `session/request_permission` beantwoorden met de `optionId` van soort `allow_once`, `allow_always` of `reject_once`.
- De werkruimte-brug gaat mee in `session/new.mcpServers`.

Hiermee wordt Antigravity een volwaardige agent (starten, antwoorden met denkstappen, goedkeuren) in plaats van alleen berichten sturen via `agentapi`, en komen Copilot CLI en andere ACP-agents er met weinig extra werk bij.

### Gebruik

- Claude: naast `api/oauth/usage` ook de live `rate_limit_event`s; contextvenster uit een modeltabel.
- Codex: `account/rateLimits/read` en de live updates; terugval op `GET https://chatgpt.com/backend-api/wham/usage`.
- ACP: `usage_update {used, size, cost}`.

### Volgorde

1. Codex naar `app-server` (de infrastructuur bestaat al, grootste winst: goedkeuringen en bijsturen).
2. Claude één proces per sessie met bijsturen en plan-kaart.
3. ACP-client, eerst voor Gemini CLI en Antigravity.
4. Terugzetpunten per beurt (verborgen git-refs `refs/nook/checkpoints/<sessie>/<beurt>`) en "Terug naar hier".
