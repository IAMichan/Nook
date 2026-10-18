# Plan: de Agents-tab van Nook gelijk aan, daarna beter

> **English summary:** A step-by-step plan to bring Nook's Agents tab to functional (Nook's own look and feel), then past it. It lists what exists, what is open, the order of work in eleven phases with deliverables, files, tests and acceptance criteria, the decisions that are yours, and where Nook can be better than (it already sees agents in terminals, reads your screen, calendar and mail, and lives in the notch).

Bron van de vergelijking: `octocat/hello-world` (orchestration v2, docs en code gelezen op 2026-10-18) en `docs/AGENTS-PARITY.md` (wat Nook al eerder overnam).

## 1. Uitgangspunten

1. **Eerst gelijk, dan beter.** Functies één-op-één; de vorm is Nooks eigen (notch, `NookTheme`, de bestaande componenten). Een functie is pas "gelijk" als hij op alle agents een eerlijk antwoord heeft (werkt, of is zichtbaar niet beschikbaar).
2. **Eén kern, dunne schil.** Beslislogica staat in Foundation-bestanden in `Services/Workspace` (testbaar zonder Xcode, op Linux). Views en `WorkspaceManager` voeren alleen uit. Dit is "orchestration is puur, de UI is dom".
3. **Capabilities, nooit agentnamen.** Elke agent meldt wat hij kan (`ProviderCapabilities`); de rest van de app leest dat. Een capability die aan staat en toch faalt is een bug.
4. **Elke functie klaar =** alle agents beslist, de omgekeerde weg erbij (snooze ↔ wakker, sluiten ↔ heropenen), nl/en/de, tests, docs, en geen continu animerende of zware weergave (prestatie-regel).
5. **Veilig zoals Nook al is.** Wat namens jou iets uitvoert gaat via een kaart die jij bevestigt, en komt in het audit-logboek; tekst van buiten is data, geen instructie.
6. **Klein en gecontroleerd.** Een fase is een reeks kleine commits met tests; de macOS-CI (build + `NookTests`) moet na elke fase groen zijn.

## 2. Stand van zaken

Legenda: ✅ gebouwd en getest in de Foundation-kern (UI nog niet op macOS gebouwd) · 🟡 deels · ⬜ open · ➖ niet nodig voor Nook (met reden).

### Agents en sessies

| | Nook | Stap |
|---|---|---|
| Adapter per agent met capabilities | 🟡 `ProviderCapabilities` (nu ook steering, nativeFork); nog geen capability voor fork-vanaf-beurt, rollback van het gesprek, subagents, achtergrondwerk | F2 |
| Instance = agent + account | ✅ `ProviderInstance`, `SelectionTransition`, één menu voor agent, account en model (`AgentPickerMenu`) | F1 |
| Inspanning (effort) per beurt | ⬜ | F1 |
| Eén proces per sessie, sessies hervatten | ✅ (eerdere ronde) | – |
| Fork, wissel van agent, handoff met budget | ✅ `ContextHandoff`; ⬜ merge-back, fork vanaf een gekozen beurt | F3 |
| Subagents van de agent zelf als knopen in de tijdlijn | ⬜ (Claude `Task`, Codex `collabAgentToolCall`) | F5 |
| Achtergrondwerk blijft na de beurt (monitor, commando's) en wekt de ouder | ⬜ | F2 |
| Gebruikslimiet met reset en automatisch hervatten | ✅ (eerdere ronde) | – |

### Beurt, wachtrij en herstel

| | Nook | Stap |
|---|---|---|
| Run → attempts → knopen; `waiting` als afrondfase vóór `completed` | ⬜ (nu één status per sessie) | F3 |
| Wachtrij: bewerken, herordenen, "stuur nu bij", ⌘Return wisselt steer/queue | 🟡 wachtrij en wisselen zijn er; bewerken en herordenen niet | F3 |
| Steering die tools onderbreekt: eerst voorgrond-subagents naar de achtergrond | ⬜ | F2 |
| Interrupt-race: wacht op "gesloten", daarna afsluiten van alles wat open staat | 🟡 afsluiten bij exit is er; geen time-out en geen eigen tool-afronding bij Stop | F2 |
| Start-herstel: verlopen verzoeken, geannuleerde runs, "Continue where you left off." | ✅ voortzetten (aan/uit, max. 3, max. 30 min); ⬜ verzoeken laten verlopen met reden | F3 |
| Idempotente commando's (ontvangstbewijs), effecten in een outbox | ➖ Nook draait in één proces zonder netwerk; wel nodig: idempotente sleutels voor delegatie (✅ `client_request_id`) en scheduled tasks | F8 |

### Inbox en organisatie

| | Nook | Stap |
|---|---|---|
| Eén afgeleide status (goedkeuring > vraag > bezig > wachtend > limiet > klaar) | ✅ `AgentAttention` in de lijst; ⬜ in de notch-ring en menubalk | F1 |
| Meldingen één keer per `runId:status`, geluid per soort | 🟡 `AttentionLedger` gebouwd, niet aangesloten | F1 |
| Afhandelen, snooze, vastzetten, slepen, vouwen van werkende sessies | 🟡 afhandelen (nu "klaar") en snooze; ⬜ vastzetten, volgorde, vouwen | F4 |
| Automatisch afhandelen bij PR-merge of inactiviteit, nooit met open werk | ⬜ | F4 |
| Gelezen-staat die meeverhuist | ➖ één Mac (iCloud-sync is een besluit, zie §6) | – |

### Invoerveld

| | Nook | Stap |
|---|---|---|
| `/`, `@`, `#`, typed verwijzingen, veilige projectie | ✅ `ComposerCore`, `ComposerRich`; 🟡 `#` zoekt geen PR's | F1 |
| Skills (`$`) en agent-commando's (`/compact`, `/goal`) | ⬜ `/compact` is er; `/goal` en `$` niet | F1 |
| Queue/steer, ArrowUp, grote plakteksten als bijlage | ✅ | – |
| Concept per sessie bewaren, prompt-stash | ⬜ | F1 |
| Meter voor het contextvenster | 🟡 alleen boven 60 % in de kop | F1 |
| Goedkeuringen en vragen vervangen het invoerveld; vragen met bijlagen | 🟡 vervangen is er; bijlagen bij een antwoord niet | F5 |
| Plan klaar → "Implement" of "in een nieuwe thread" | 🟡 eerste is er | F1 |
| Sneltoetsen configureerbaar | ⬜ | F9 |
| Prompt-links (`nook://prompt?…`, opent een concept, voert niets uit) | ⬜ | F9 |
| SnapShot (venster als bijlage met toegankelijkheidsdata) | 🟡 Nook leest al alle vensters; als bijlage in het veld ontbreekt | F10 |

### Tijdlijn, diff, review

| | Nook | Stap |
|---|---|---|
| Beurten vouwen, tool-aanroepen groeperen, live regel | ✅ (eerdere ronde) | – |
| Per beurt: wijzigingenboom, diff op aanvraag, hele-thread-diff | 🟡 wijzigingen per sessie; ⬜ per beurt | F5 |
| Zoeken in de thread, minimap, naar een rij springen | ⬜ | F5 |
| Tool-uitvoer niet in het gesprek maar op aanvraag; live uitvoer begrensd | ⬜ nu volledig in `events` (16 kB per tool) | F5 |
| Visuele antwoorden (HTML in een sandbox) en MCP-apps | ⬜ | F5 |
| Citaten en verwijzingen terug naar de tijdlijn | ⬜ | F5 |
| Virtualisatie en bounded history ("Laad eerdere beurten") | 🟡 `LazyVStack`; de hele tijdlijn staat in het geheugen | F5, F8 |

### Git, checkpoints en bronnen

| | Nook | Stap |
|---|---|---|
| Checkpoint per beurt, terugzetten, "edit from here" | ✅ (eerdere ronde); ⬜ het gesprek van de agent mee terugdraaien | F3 |
| PR-koppeling: meerdere, stapels, zoeken vanuit een branch, wekken bij activiteit | 🟡 één PR vanuit de git-knop; ⬜ de rest | F6 |
| GitHub, GitLab, Bitbucket, Forgejo/Gitea, Azure DevOps | 🟡 alleen GitHub | F6 |
| Worktree-namen, locatie, "hou de standaardbranch bij" | 🟡 worktrees ja; ⬜ regels | F6 |
| Projectinstellingen met overerving | ⬜ | F9 |

### Orkestratie en automatisering

| | Nook | Stap |
|---|---|---|
| `delegate_task`, `task_status`, `task_cancel`, capabilities | ✅ met rechtenplafond | – |
| `thread_*`: lijst, lees, stuur (auto/queue/steer/restart), wacht, onderbreek, hernoem | 🟡 `session_read`; ⬜ de rest | F7 |
| `create_threads`, `thread_launch` (worktree, scratch) | ⬜ | F7 |
| Scheduled tasks (interval, vaste tijd, webhook met HMAC) | ⬜ | F7 |
| Uitkomst van een kind wekt de ouder; vraag van een kind bereikt de ouder | ✅ resultaat; ⬜ vragen van een kind doorzetten | F7 |
| Outside agents: Nooks MCP-eindpunt voor agents die Nook niet startte (OAuth, rechtenplafond) | 🟡 de brug werkt per socket voor agents met de brug gekoppeld; ⬜ eindpunt met inloggen | F7 |

### Platform

| | Nook | Stap |
|---|---|---|
| Server als achtergronddienst | ➖ Nook is al een menubalk-app die blijft draaien | – |
| Remote (LAN, Tailscale, tunnel), web, mobiel | ➖/⬜ zie §6 | F9 |
| Gebruik en limieten, eigen prijzen, CLIProxy | 🟡 gebruik en limieten ja; ⬜ eigen prijzen | F9 |
| Welkomstflow, browserimport, terminal, projectscripts | ✅ (Nook heeft eigen versies) | – |

## 3. De fasen

Elke fase eindigt met: macOS-CI groen, tests voor de kern, docs, en een korte demo-route.

### F0 — Verifiëren en het testfundament (eerst)

Doel: zeker weten dat wat er staat bouwt en werkt, en later sneller kunnen bouwen.

1. De build laten draaien op deze branch (PR openen of `workflow_dispatch`; de koppeling van deze omgeving mag dat niet) en compilatiefouten herstellen in de UI-bestanden die hier alleen op syntaxis zijn gecontroleerd (`SessionComposer`, `ComposerRich`, `AgentPickerMenu`, `AgentRunPanel`, `NookTab`, `NewSessionComposer`).
2. `scripts/core-tests.sh`: een Swift-pakket dat de Foundation-bestanden uit `project.yml` compileert en `swift test` draait op Linux (nu losse opzet in de werkmap). Zo blijft de kern ook zonder Mac testbaar.
3. **Replay-fixtures** (belangrijkste testidee): opgenomen transcripten van Claude (`stream-json`), Codex (`app-server`) en ACP, afgespeeld door de echte parsers en `WorkspaceManager`-logica met een nepproces. Scenario's: `simple`, `multi_turn`, `queued_turn`, `turn_interrupt`, `message_steering`, `resume`, goedkeuring, vraag, gebruikslimiet. Opnamescripts per agent in `scripts/`.
4. Een deterministische klok en `UUID`-bron in de manager (injecteerbaar), zodat tests nooit hoeven te slapen.
5. **Prestatiebudgetten als test**: maximale grootte van een sessie-JSON, tijd om een tijdlijn van 5.000 events te laden, aantal view-updates bij streamen.

Klaar als: CI groen; `core-tests.sh` draait lokaal en in CI; minstens de scenario's `simple`, `turn_interrupt` en `message_steering` draaien als replay voor Claude en Codex.

### F1 — Wat al begonnen is afmaken (klein, snel)

1. **`#`-zoeken**: `GitHubPullRequests.searchOpen(repo:query:)` (zoals `openPullRequest`), gefilterd door een pure `PullRequestMatch` (nummer-prefix of titel), tests.
2. **Inspanning**: `ProviderCapabilities.effortLevels` (Codex: `low/medium/high`, via `effort` in `turn/start`); `WorkspaceRun.effort`; een pil in de rij. Een niet-aangeboden stand is "overgeslagen", geen fout. Claude pas als de vlag gecontroleerd is.
3. **`/goal` en `$`-skills**: `/goal` doorsturen voor Claude en Codex (de agent houdt de staat; Nook toont hem pas in F2); `$` toont de skills uit `~/.claude/skills` en de projectmap (alleen noemen, niet lezen).
4. **Concept per sessie** bewaren (UserDefaults, `SafeStorage` voor lange tekst) en een prompt-stash.
5. **Contextmeter** als vaste kleine ring in het invoerveld, met tooltip; boven 85 % wordt hij coral, en `/compact` is één klik.
6. **Plan → "in een nieuwe sessie"**: vork met de volledige plantekst in het eerste bericht (de samenvatting kapt berichten af).
7. **Meldingen**: `AttentionLedger` aan de notch-kaarten voor "klaar" en "mislukt" hangen, de ring en de menubalk dezelfde `AgentAttention` laten lezen.
8. `AgentSessionDetail` (sessies die Nook alleen volgt) op dezelfde invoer: `.rich`, plus-menu, projectie van verwijzingen in `app.reply`.

Klaar als: dezelfde rij en toetsen overal, behalve waar de agent de functie mist (dan zichtbaar uitgeschakeld met uitleg).

### F2 — Betrouwbaarheid per agent (valkuilenlijst)

Doel: geen hangende spinners, geen dubbele beurten, geen verloren achtergrondwerk.

1. **Capabilities uitbreiden**: `forkFromTurn`, `rollbackConversation`, `subagents`, `backgroundWork`, `queuedMessages`; de UI leest alleen die.
2. **Stop afronden**: Stop wacht op "gesloten" (10 s), sluit daarna af en markeert elke open tool, goedkeuring en vraag als beëindigd; test per eindpad (klaar, Stop, fout, procesexit).
3. **Steering**: Claude's steer annuleert tools; eerst voorgrond-subagents naar de achtergrond (`backgroundTasks`), daarna opnieuw controleren of de beurt nog loopt; het "aborted"-resultaat van de gestuurde beurt telt niet als einde.
4. **Prompt-echo**: Claude's lange proces kan frames van andere beurten sturen (wake-beurten, achtergrondtaken); per prompt een uuid en frames vasthouden tot de echo.
5. **Achtergrondwerk**: `hasPendingBackgroundWork` per sessie; een sessie met lopend werk wordt niet als "klaar" gemeld en niet gesloten als stil; een wake-beurt van de agent zelf wordt een beurt met `creationSource: provider`.
6. **Foutclassificatie in lagen** (resultaat, streamgebeurtenis, tekst) met `resetAt`; `/compact` die op een limiet stuit blijft mislukt.
7. **Codex**: achterblijvende `commandExecution`-items afsluiten; "voor deze sessie goedkeuren" zelf bijhouden per modus; `thread/unsubscribe` bij sluiten.
8. **MCP-time-outs**: de brug-tools mogen langer duren dan 60 s; een brug die niet bereikbaar is mag de beurt nooit breken (nu al zo; testen).

Klaar als: voor Claude en Codex bestaat een replay per eindpad en per valkuil hierboven.

### F3 — Beurtmodel, wachtrij, terugdraaien

1. **Run, attempt, `waiting`**: `RunStatus` krijgt `finishing` (afronden: streams sluiten, subagents beëindigen, checkpoint) vóór `completed`; een late checkpoint verlengt de duur niet (`providerDuration` apart van `finalization`).
2. **Wachtrij als gegevens**: bewerken (Alt+↑), herordenen, "nu bijsturen", `queue.resume` na herstart; nu `[String]`, straks struct met id.
3. **Restart-steer**: voor agents zonder echte steering: onderbreken en opnieuw starten met het bericht (`supportsSteeringByInterruptRestart`).
4. **Terugdraaien van het gesprek**: Claude via `resume` + `resumeSessionAt`, Codex `thread/rollback`; een agent die dat niet kan weigert vóór de bestanden veranderen.
5. **Fork vanaf een gekozen beurt** en **merge-back** (het verschil sinds het splitspunt naar de ouder).
6. **Start-herstel**: openstaande verzoeken verlopen met een reden; "niet hervatbaar" in plaats van een dode knop.

Klaar als: elke bewerking op een lopende of afgeronde beurt heeft een test voor "agent kan het niet".

### F4 — Inbox en organisatie

Vastzetten en volgorde (slepen, onthouden), vouwen van werkende sessies, afhandelen automatisch bij PR-merge of na inactiviteit (nooit met open verzoek, lopend of wachtend werk, wachtrij, vastgezet of snooze), een zichtbare "Afgehandeld"- en "Gesnoozed"-sectie, en zoeken in de lijst. De regels zijn pure functies zoals `AgentAttention`.

### F5 — Tijdlijn, diff en visuele antwoorden

1. Per beurt de wijzigingenboom en een diff op aanvraag; hele-sessie-diff.
2. **Handvatten in plaats van inhoud**: `RunEvent.output` naar bestand, in het gesprek alleen een verwijzing en een staat; live uitvoer van een uitgeklapt commando als aparte, begrensde stroom.
3. Zoeken in de sessie (⌘F), een minimap, springen naar een rij.
4. Subagent-kaarten (naam, model, laatste tool, voortgang) en stoppen per subagent.
5. Visuele antwoorden: HTML in een `WKWebView` zonder netwerk en zonder toegang tot Nook; MCP-apps als tweede stap.
6. Vragen met bijlagen; citaten die naar de tijdlijn springen.

### F6 — Git, pull requests en bronnen

Meerdere PR's per sessie en stapels, PR volgen vanuit de branch ook als de app dicht was, een PR-wake (de agent krijgt een bericht bij activiteit), automatisch afhandelen bij merge; GitLab, Bitbucket en Forgejo/Gitea achter één `SourceControlProvider`-protocol (clone, publiceren, PR maken, PR zoeken) met capabilities; regels voor worktree-namen en "hou de standaardbranch bij".

### F7 — Orkestratie voltooien

1. **Thread-tools** in de brug: `session_list`, `session_send` (auto/queue/steer/restart met hetzelfde rechtenplafond), `session_wait`, `session_interrupt`, `session_update` (hernoemen, PR koppelen).
2. `create_sessions` (1–20) en `session_launch` (worktree, scratch).
3. **Scheduled tasks**: interval, vaste tijd (gemiste runs ouder dan 10 min overslaan), webhook (HMAC, constant-time vergelijken, wachtrij van 20); idempotente sleutel per afvuring; herstel van "running" na een herstart; tools `schedule_task` e.d.
4. Vragen van een kind bereiken de ouder; een wachtende oproep wordt bij herstart een wake.
5. **Nooks MCP-eindpunt** voor agents buiten Nook (HTTP, OAuth/PKCE, standaard alleen lezen, rechtenplafond, intrekbaar, 30 dagen) naast de bestaande socket-brug.

### F8 — Duurzaamheid en prestaties

Besluit nodig (zie §6): JSON-bestanden per sessie behouden, of naar SQLite met gebeurtenissen en projecties. Voor een tijdlijn van tienduizenden events en een lijst die niet mag haperen is SQLite (WAL, per-sessie-gepagineerd lezen, projecties voor de lijst) de aangewezen route. Dan ook: opgeschoonde start (herstel van een beschadigd bestand zonder gegevens te verliezen is er al via `SafeStorage`), en de prestatiebudgetten uit F0 als blijvende tests.

### F9 — Platform en gebruik

Configureerbare sneltoetsen (`keybindings.json` met `when`-voorwaarden), prompt-links (`nook://prompt?…`, opent een concept, voert nooit iets uit), projectinstellingen met overerving, eigen modelprijzen, en de keuze over een iPhone-metgezel (§6).

### F10 — Beter dan 

Dit is wat niet kan, omdat het alleen zijn eigen sessies kent:

1. **Alle agents, ook die in een terminal draaien** (Nook ziet ze al via hooks en `AgentHub`): één inbox, goedkeuringen vanuit de notch, en dezelfde handoff/fork ernaartoe ("Open in Nook" bestaat al).
2. **Scherm als verwijzing**: `@scherm` en `@venster` zetten de OCR-tekst of een SnapShot van het voorste venster in het bericht, met jouw bevestiging; Nook leest al alle vensters lokaal.
3. **Agenda, mail en taken bepalen wanneer**: scheduled tasks die rekening houden met je agenda ("niet tijdens mijn afspraken"), en een ochtendoverzicht van wat je agents deden.
4. **Het lokale model doet het kleine werk**: titels, handoff-samenvattingen en "wat deed deze sessie" zonder cloud of limieten.
5. **Limiet- en kostenbewust kiezen**: bij een bijna volle limiet stelt Nook een andere agent of account voor, met de handoff uit F3.
6. **Meedenken over je agents**: een stille suggestie als een sessie vastloopt, op een vraag wacht terwijl jij weg bent, of een PR al dagen openstaat.
7. **De notch als instrument**: status, goedkeuren, antwoorden en bijsturen zonder een venster te openen.

Meetbaar "beter": tijd tot goedkeuren, tijd tot hervatten na een limiet, geheugen en CPU met 10 lopende sessies, aantal gemiste "wacht op jou"-momenten.

## 4. Per stap werken

Voor elke stap hierboven, in deze volgorde:

1. Het gedrag lezen (bestand en regel noteren in de commit).
2. De pure kern schrijven met tests (Foundation, `core-tests.sh`).
3. `WorkspaceManager`-koppeling en de view.
4. Per agent beslissen: werkt, of zichtbaar niet beschikbaar (capability).
5. nl/en/de, docs (`docs/AGENTS-PARITY.md` bijwerken), en de `I18nCoverageTests`.
6. CI groen, dan pas de volgende stap.

## 5. Risico's

- **Niet gecompileerd op macOS**: de UI-code van deze branch is alleen op syntaxis gecontroleerd. F0 gaat daarvoor.
- **Agents veranderen** (Claude Code, Codex, ACP): daarom replay-fixtures met de versie erbij, en een duidelijke foutmelding bij een onbekend bericht.
- **Omvang van `WorkspaceManager`** (al ruim 1.400 regels): nieuwe logica gaat in extensies en pure types, niet in dat bestand.
- **Veiligheid van het MCP-eindpunt (F7)**: standaard alleen lezen, geen rechten boven het plafond, intrekbaar, en in het audit-logboek.

## 6. Besluiten die van jou zijn

1. **Opslag (F8)**: JSON houden of naar SQLite? Aanbeveling: SQLite zodra F5 (tool-uitvoer als handvat) klaar is.
2. **Remote en mobiel**: heeft web, desktop en mobiel via een server. Nook is een Mac-app. Een iPhone-metgezel (meldingen, goedkeuren, antwoorden) is een eigen project; aanbeveling: pas na F7, begonnen met alleen goedkeuren en antwoorden.
3. **Welke bronnen na GitHub (F6)**: GitLab eerst?
4. **Prioriteit F10 versus F4–F7**: aanbeveling is eerst F0–F3 (betrouwbaarheid), dan F10.1 en F10.2 omdat ze Nook het meest onderscheiden, en F4–F7 daarna.
5. **Een build van deze branch**: een pull request openen (of mij laten openen) zodat de CI draait.
