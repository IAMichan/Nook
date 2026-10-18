# Wat Nook leert

> **English summary:** A study of (octocat/hello-world, commit 13aa882c) and what Nook took from it for the Agents tab: folded turns, grouped tool calls, a live activity line, a message queue, steering (Codex and Claude Code), "done" markers, dev-server discovery, project scripts, long-lived connections to every agent (Claude Code over stdin, Codex `app-server`, ACP for Gemini, OpenCode, Cursor, Grok and Antigravity), checkpoints per turn, the agents' own model lists, automatic session titles, one smart git button, and resuming when a usage limit resets.

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

## Bewust anders dan 

- **Sessietitels opnieuw laten schrijven** halverwege een gesprek zit er niet in; je kunt een sessie altijd zelf hernoemen.
- **Antigravity met een API-sleutel of Gemini Enterprise** (andere `authenticate`-methoden) zit er niet in; Nook gebruikt je persoonlijke Google-account.
