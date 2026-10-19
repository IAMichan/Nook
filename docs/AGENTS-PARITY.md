# Wat Nook leert

> **English summary:** A study of (octocat/hello-world, commit 13aa882c) and what Nook took from it for the Agents tab: folded turns, grouped tool calls, a live activity line, a message queue, steering (Codex and Claude Code), "done" markers, dev-server discovery, project scripts, long-lived connections to every agent (Claude Code over stdin, Codex `app-server`, ACP for Gemini, OpenCode, Cursor, Grok and Antigravity), checkpoints per turn, the agents' own model lists, automatic session titles, one smart git button, and resuming when a usage limit resets. The third round adds the agent's task list and subagents above the composer, a pull request watch that wakes the agent, comments on the diff, a turn minimap, HTML and Mermaid previews, Markdown export, any ACP agent (from the ACP registry or by hand), sessions on another machine over SSH (git included), changed files per turn, background work that wakes the session, MCP apps in the timeline, a browser search engine setting and an iOS Simulator page.

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
| Claude Code | Eén `claude -p --input-format stream-json` per sessie; na `result` blijft het proces wachten op het volgende bericht | Vervolg zonder herstart (cache blijft warm), **bijsturen tijdens een beurt** (een bericht met `priority: "now"`; een `result` met `terminal_reason` `aborted_streaming`/`aborted_tools` sluit dan een deel af, niet de beurt), AskUserQuestion als vraagpaneel (antwoorden als `updatedInput.answers`), ExitPlanMode als plankaart met **Voer plan uit**, live `rate_limit_event` | Nieuw proces met `--resume` bij ander model, andere modus of rechten |
| Gemini CLI | ACP: `gemini --acp` | Toestemming in Nook, gedachten, tool-aanroepen, context | Headless `--output-format stream-json` bij een oude versie |
| OpenCode | ACP: `opencode acp` | idem, plus kosten | — |
| Cursor | ACP: `cursor-agent acp` | idem | — |
| Grok | ACP: `grok agent stdio` (`--always-approve` bij volledige rechten) | idem | — |
| Antigravity | ACP: Google's `agy_acp_server` 1.3.0, door Nook geïnstalleerd (zie hieronder) | idem, plus Google-inloggen per account | — |

ACP in Nook: `initialize` (protocolversie 1, geen bestands- of terminaltoegang voor de agent), `session/new` of `session/load` (de herhaling van een geladen gesprek wordt overgeslagen, want Nook bewaart de tijdlijn zelf), `session/set_mode` voor Plan, `session/set_model`, `session/prompt`, `session/cancel`. Toestemmingsverzoeken (`session/request_permission`) gaan naar jou, of worden meteen toegestaan als de rechten van de sessie dat zeggen: lezen altijd, bewerken bij "bewerkingen toestaan", alles bij volledige rechten, en in Plan-modus alleen lezen. De werkruimte-brug gaat mee als MCP-server in `session/new` (ACP), `thread/start.config.mcp_servers` (Codex) en `--mcp-config` (Claude Code).

## Terugzetpunten per beurt

Voor sessies in een eigen worktree maakt Nook vóór de eerste beurt en na elke beurt een momentopname: een tijdelijke index (`read-tree HEAD`, `add -A`, `write-tree`, `commit-tree`, `update-ref refs/nook/checkpoints/<sessie>/<n>`). De branch, HEAD en je staging veranderen niet. Rechtsklik op een eigen bericht › **Bestanden terugzetten naar vóór dit bericht** zet de bestanden terug: gewijzigde en verwijderde bestanden komen terug, bestanden die later zijn toegevoegd verdwijnen, genegeerde bestanden blijven. Het gesprek blijft staan. Dat kan alleen als de sessie stilstaat en niemand anders in die map werkt.

## Modellenlijsten van de agent zelf

Codex: `model/list` over app-server, pagina voor pagina (`cursor`/`nextCursor`), verborgen modellen eruit, in Codex' eigen volgorde, met namen als "GPT-5.1-Codex" (`formatCodexModelName`). Grok: `_meta.modelState` uit `initialize`, zonder in te loggen of een sessie te openen. De andere ACP-agents: de config-optie met categorie `model` (groepen platgeslagen), anders `models.availableModels` uit `session/new`; het model gaat dan via `session/set_config_option`, anders `session/set_model`. Nook vraagt hooguit eens per vijf minuten en bewaart de lijsten (`workspace/agent-models.json`), zodat de menu's meteen kloppen.

## Automatische sessietitels

Na het eerste bericht schrijft een klein model een titel van 3 tot 8 woorden met prompt (plus: in de taal van je bericht). Dat is Claude Code met `haiku` (`-p --output-format json --json-schema`, zonder tools, slash-commands, MCP of hooks, in een lege map) of `codex exec` (read-only, `--ephemeral`, lage effort, `--output-schema`). Nook kiest de agent van de sessie als dat een van de twee is, anders de verbonden. De titel valt weg als je de sessie intussen hernoemde. Uit te zetten in Instellingen.

## Eén slimme git-knop

In het zijpaneel van een sessie, met keuze per stand van de branch:

| Stand | Knop |
|---|---|
| Wijzigingen, geen remote | Commit |
| Wijzigingen, open PR of standaardbranch | Commit & push |
| Wijzigingen | Commit, push & PR |
| Voor op de remote (of nooit gepusht met eigen commits), open PR of standaardbranch | Push |
| Idem zonder PR | Push & maak PR |
| Gepusht, eigen commits, geen PR | Maak PR |
| Achter | Pull (alleen fast-forward) |
| Uiteengelopen, detached, niets te doen | Uitleg waarom niet |

Het commitbericht en de pull request (titel en beschrijving met `## Summary` en `## Testing`, of volgens het PR-sjabloon van de repository) schrijft de agent met prompts; de context komt uit een tijdelijke index, dus je eigen staging blijft staan. Pushen naar de standaardbranch vraagt eerst. Met de GitHub-koppeling opent Nook de pull request zelf en ziet het of er al een open staat (**Bekijk PR**); zonder koppeling opent GitHub's vergelijkpagina met titel en beschrijving al ingevuld.

## Hervatten zodra een limiet vrij is

Claude Code: een `rate_limit_event` met status `rejected` zonder extra gebruik, met `resetsAt`; aan het eind een fout-`result` (of `terminal_reason: blocking_limit`, of `api_error_status: 429`). Codex: `codexErrorInfo` `usageLimitExceeded` of `rateLimitExceeded`, met de resettijd uit de laatste `account/rateLimits/updated` (het laatste reset-moment van de vensters op 100 %). Boven het invoerveld staat dan wanneer de limiet vrijkomt, met **Hervat bij reset**: twintig seconden na de reset gaat "Continue where you left off." naar de agent, na een laatste controle (nog gewenst, niets open, niet gearchiveerd). Een eigen bericht annuleert het. In Instellingen kan het de standaard worden (standaard uit, zoals bij).

## Antigravity via ACP

Nook installeert Google's ACP-server: de vastgepinde release 1.3.0 voor deze Mac van `dl.google.com`, gecontroleerd op grootte en SHA-256 voordat er iets wordt uitgepakt, precies twee bestanden (`agy_acp_server.par` en `localharness_external`) van precies de verwachte grootte, en een proefstart die als `antigravity-acp` met `oauth-personal` moet antwoorden. Pas dan wordt de release actief (`tools/antigravity-acp/<platform>/active.json`). Een sessie krijgt een eigen profielmap per Nook-account (`GEMINI_HOME`, tokens in een bestand), de harness, en geen andere Google-sleutels of -projecten uit je omgeving. Na `initialize` volgt `authenticate` met `oauth-personal`: met een bewaard token meteen, anders opent Google's inlogpagina (gecontroleerd: `accounts.google.com`, één `state`, terug naar een eigen loopback-poort) in je browser. De modus volgt de rechten: `yolo`, `auto_edit`, `default`, of `plan`. Gesprekken uit de Antigravity-app blijven via `agentapi` lopen; die kan de ACP-server niet laden.

## Tweede ronde: de orchestratie (v2)

De nieuwere (`apps/server/src/orchestration-v2`) is opnieuw bestudeerd. Wat Nook daaruit nu heeft, en waar de logica staat. Alles in `Services/Workspace` is alleen Foundation en getest (`AgentAttentionTests`, `DelegationTests`, `ContextHandoffTests`, `ComposerCoreTests`).

| | In Nook | Waar |
|---|---|---|
| Eén afgeleide status: goedkeuring > vraag > bezig > wachtend > limiet/mislukt > klaar | De lijst toont ook "wacht op je antwoord" en "gebruikslimiet", en sorteert op urgentie | `AgentAttention` |
| Snooze, die vanzelf eindigt of zodra er iets van je nodig is | Rechtsklik › Snooze (een uur, vanavond, morgenochtend) | `SnoozePolicy` |
| Meldingen één keer per run en toestand (`runId:status`) | `AttentionLedger` (de kern; de notch meldt nog via de bestaande kaarten) | `AgentAttention.swift` |
| "Continue where you left off." na een herstart, hooguit drie keer achter elkaar | Instelling (uit): een door herstart onderbroken sessie gaat één keer verder, alleen als het net gebeurde | `RestartContinuation` |
| `delegate_task`, `task_status`, `task_cancel`, `orchestrator_capabilities` | Vier nieuwe tools in de werkruimte-brug; nooit meer rechten dan de ouder; Stop op de ouder stopt zijn taken | `Delegation.swift`, `docs/WERKRUIMTE-AGENTS.md` |
| Fork en wissel van provider met een zichtbare overdracht | Vork maken en Wissel van agent in het menu van een sessie; de samenvatting staat uitklapbaar in de tijdlijn | `ContextHandoff.swift`, `WorkspaceManager+Handoff` |
| Een invoerveld met `/`, `@` en `#`, typed verwijzingen, queue/steer met een toets om te wisselen, ArrowUp, grote plakteksten als bijlage | Eén `SessionComposer` voor de chat en de agents; zie hieronder | `ComposerCore.swift`, `ComposerRich.swift` |
| Een andere sessie lezen via een verwijzing | `session_read` in de brug | `WorkspaceBridge` |

### Eén invoerveld

De chat en de agents gebruiken dezelfde `SessionComposer`, nu met gedrag: dezelfde rij (plus-menu, model, daarna modus en rechten of bronnen, microfoon, verzenden), dezelfde lijst onder het veld en dezelfde toetsen. Elk heeft een eigen kleur (`ComposerConfig.tint`): Nooks iris voor de chat, de kleur van de agent voor een sessie.

- `/` opent de commando's (alleen aan het begin van de tekst), `@` bestanden in de map en andere sessies, `#12` een pull request.
- Een verwijzing staat in de tekst als `[Login.swift](nook-context://v1/file/…)`. De agent krijgt een korte aanduiding in de tekst en één `<nook_context>`-blok met een record per verwijzing. Bestanden, sessies en pull requests worden alleen genoemd (de agent leest ze zelf); een uittreksel draagt zijn tekst mee, ingekort, met `<` en `&` onschadelijk gemaakt, zodat geplakte tekst nooit een record kan namaken. De tijdlijn en de wachtrij tonen alleen wat je schreef.
- Plakken van 32 KB of meer wordt een verwijzing "Pasted text (45 KB)" in plaats van tekst in het veld.
- Terwijl de agent werkt stuurt Return bij of zet in de wachtrij (Instellingen › Agents), ⌘Return doet het andere; kan de agent niet bijsturen, dan gaat het altijd naar de wachtrij.
- ArrowUp en ArrowDown lopen door wat je eerder stuurde, en je concept komt terug aan het eind; een tekst met meerdere regels houdt zijn pijltjes.

Verschillen die bewust blijven: de chat heeft geen modus of rechten (het brein voert niets uit; daar staan de bronnen), en zet geen verwijzingen in de vraag (die gaat als gewone tekst naar het brein). De microfoon van de chat stelt de vraag meteen en leest het antwoord voor; die van een sessie zet de woorden in het veld.

Nog niet: `#` zoekt geen pull requests (je typt het nummer), de inspanning-stapper, `/goal`, "Implement in a new thread" bij een plan en een eigen plek voor het contextvenster.

## Derde ronde

Aanvullingen op de tweede ronde, voor wat daar nog ontbrak:

| | In Nook | Waar |
|---|---|---|
| Takenlijst boven het invoerveld (ComposerTasksBadge) | **Taken · huidige stap · 3/7** met een streepje per stap, open te klappen. Uit Claude Code's `TodoWrite` (niet van subagents), Codex' `turn/plan/updated` en ACP's `plan`. Een lijst die af is verdwijnt bij de volgende beurt. | `RunTasks`, `TasksStrip` |
| Subagent-balk | Claude Code's `Task`/`Agent`-aanroepen en Codex' subagents (`collabAgentToolCall`) van de lopende beurt: soort, opdracht, status en antwoord | `Subagents`, `SubagentBar` |
| Gewijzigde bestanden per beurt | Onder elke afgeronde beurt **Gewijzigde bestanden: 3**; klik toont de bestanden met wat die beurt eraan deed (tussen de snapshots rond de beurt; Nook maakt die nu voor elke sessie in een repository, ook in je eigen map, zonder bestanden, index of branch aan te raken. Terugzetten blijft alleen voor sessies in een eigen worktree) | `TurnChanges`, `TurnChangesChip`, `WorkspaceManager.turnDiff` |
| Achtergrondwerk wekt de sessie | Werk dat de agent op de achtergrond startte en ná de beurt klaar is (Claude Code gaat vanuit zijn wachtende proces verder, Codex start zelf een beurt): de sessie wordt weer een live beurt met de melding *Werk op de achtergrond is klaar* | `wakeParkedClaude`, `wakeCodexServer` |
| PR volgen en wekken | ⋯ › **Volg pull request** (vanzelf voor een PR die Nook opende): CI, reviews, opmerkingen en de merge als nieuws in de tijdlijn; mislukte CI, een review of een opmerking gaat als bericht naar de agent. Hooguit eens per twee minuten; GitHub-pull requests en GitLab-merge requests (pipeline, goedkeuringen, opmerkingen). | `PullRequestNews`, `GitHubPullRequests.snapshot`, `GitLabMergeRequests.snapshot` |
| Opmerkingen bij de diff | In de wijzigingen: beweeg over een regel › opmerking. Alle opmerkingen gaan samen als `<review_comment>` naar de agent. | `ReviewComments`, `DiffText` |
| Citeren | Rechtsklik op een antwoord › **Citeer in je bericht** | `ReviewComments.quote` |
| Terminal-context | ⋯ › **Voeg terminaluitvoer toe**: de laatste regels als `<terminal_context>` | `AgentRunPanel` |
| Minimap | Een streepje per eigen bericht naast een lang gesprek; klik springt erheen | `TurnMinimap` |
| HTML en Mermaid | Codeblokken `html`, `svg` en `mermaid` met **Bekijk**: een webweergave zonder opslag, zonder JavaScript voor HTML van de agent en zonder navigatie | `CodeRenderView` |
| MCP-apps | Een toolresultaat met een `ui://`-resource (MCP-UI/MCP Apps) staat onder de toolregel als pagina in een afgeschermde webweergave (geen opslag, geen toegang tot Nook, links openen in je browser), of als knop bij een link | `McpUI`, `McpAppBlock` |
| Zoekmachine van de browser | Instellingen › Agents › Werkruimte › **Zoekmachine in de browser**: DuckDuckGo, Google, Bing, Brave, Kagi, Startpage of Ecosia | `BrowserSearchEngine` |
| Simulator-voorbeeld | Pagina **Simulator** onder de sessielijst: het scherm van een draaiende iOS-simulator (`xcrun simctl`), elke seconde ververst, te kopiëren of te bewaren | `Simulators`, `SimulatorView` |
| Delen | ⋯ › **Kopieer gesprek als Markdown** of **Bewaar als Markdown…** (lokaal, niets online) | `SessionExport` |
| Extra agents (ACP-register) | Instellingen › Agents › Accounts › **Andere agents (ACP)**: kies een agent uit het ACP-register (npx- en uvx-pakketten op een vaste versie ze controleert; of een download voor deze Mac: Nook haalt die over HTTPS op, controleert de SHA-256 uit het register vóór het uitpakken, pakt uit met `ditto`/`tar` in een eigen map in Application Support en verwijdert die map weer met de agent) of vul zijn opdracht zelf in. Elke agent wordt een account van de soort ACP ("ACP · Kiro"), dus sessies, accounts en het modelmenu werken als bij elke andere agent. Hij start via je login-shell, zodat npx, uvx, nvm en asdf werken zoals in Terminal. | `CustomAgents`, `AcpRegistry`, `AcpInstaller`, `AcpAgentsSection` |
| Andere machines | Instellingen › Agents › Werkruimte › **Machines (SSH)**: een alias uit `~/.ssh/config` of `gebruiker@host`, met een verbindingstest. Bij een nieuwe sessie kies je zo'n machine en typ je de map daar. De agent start daar via ssh en praat over die verbinding zoals lokaal (stream-json, app-server en ACP gaan allemaal over stdin en stdout). Git draait daar ook, via ssh met één gedeelde verbinding per machine: wijzigingen, diffs, wijzigingen per beurt, commit, push en de git-knop werken zoals lokaal. Worktrees, terugzetpunten en de werkruimte-brug blijven voor zo'n sessie uit; de kop toont de machine en opent een terminal daar. | `RemoteMachines`, `RemoteLaunch`, `WorkspaceManager+Remote` |

Bewust niet: de mobiele app (Nook heeft de iPhone-metgezel in `apps/ios`) en telemetrie.

## Bewust anders dan 

- **Sessietitels opnieuw laten schrijven** halverwege een gesprek zit er niet in; je kunt een sessie altijd zelf hernoemen.
- **Antigravity met een API-sleutel of Gemini Enterprise** (andere `authenticate`-methoden) zit er niet in; Nook gebruikt je persoonlijke Google-account.
