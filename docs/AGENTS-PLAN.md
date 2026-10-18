# Plan: de Agents-tab van Nook gelijk aan, daarna beter

> **English summary:** A step-by-step plan to bring Nook's Agents tab to functional (Nook's own look and feel), then past it, with a UI/UX track learned (section 4). It lists what exists, what is open, the order of work in eleven phases with deliverables, files, tests and acceptance criteria, the decisions that are yours, and where Nook can be better than (it already sees agents in terminals, reads your screen, calendar and mail, and lives in the notch).

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
| Gelezen-staat die meeverhuist | ➖ één Mac (iCloud-sync is een besluit, zie §7) | – |

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
| Remote (LAN, Tailscale, tunnel), web, mobiel | ➖/⬜ zie §7 | F9 |
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

Besluit nodig (zie §7): JSON-bestanden per sessie behouden, of naar SQLite met gebeurtenissen en projecties. Voor een tijdlijn van tienduizenden events en een lijst die niet mag haperen is SQLite (WAL, per-sessie-gepagineerd lezen, projecties voor de lijst) de aangewezen route. Dan ook: opgeschoonde start (herstel van een beschadigd bestand zonder gegevens te verliezen is er al via `SafeStorage`), en de prestatiebudgetten uit F0 als blijvende tests.

### F9 — Platform en gebruik

Configureerbare sneltoetsen (`keybindings.json` met `when`-voorwaarden), prompt-links (`nook://prompt?…`, opent een concept, voert nooit iets uit), projectinstellingen met overerving, eigen modelprijzen, en de keuze over een iPhone-metgezel (§7).

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

## 4. UI/UX-spoor

Bron: een tweede lezing web-UI (`apps/web/src`: zijbalk, chat, composer, instellingen, onboarding, designtokens). Dit spoor loopt naast de fasen uit §3; bij elke stap staat de fase waarmee hij meegaat. De vorm blijft Nook: de notch, `NookTheme` (iris, amber, coral, mint, smoke), de bestaande componenten, Nooks stem. De **gedragsregels** nemen we over; de **pixels** niet.

### 4.1 De tien regels die UX goed maken

1. **Alleen wat jou nodig heeft is luid.** Rijen die niets van je vragen (klaar en gezien, bezig, wachtend) worden gedempt: lichtere tekst, normaal gewicht, bezige rijen op 70 %. Wat op je wacht houdt volle contrast en gewicht. De lijst is stil tot er iets is.
2. **Eén status per sessie, één woord, één kleur, overal hetzelfde** (lijst, notch-ring, projectrij, melding). Gekozen via één prioriteitsfunctie (✅ `AgentAttention`).
3. **Het invoerveld is één voorwerp.** Banners hangen als lade aan de bovenrand; één actieknop verandert van betekenis (verzenden, stop, bijsturen, wachtrij, hervatten, opslaan).
4. **Terugdraaien boven bevestigen.** Vastzetten, afhandelen, snoozen, archiveren en weggooien van een concept gebeuren meteen met "Ongedaan maken" (⌘Z). Alleen definitief verwijderen vraagt bevestiging.
5. **Uitgeschakeld met reden, nooit falen.** Archiveren is grijs terwijl de agent werkt; elke uitgeschakelde knop zegt waarom in zijn tooltip en zijn VoiceOver-naam.
6. **Niets beweegt continu.** Geen typemachine-effect, geen rij-animaties, de "bezig"-stip pulseert in stappen en stopt als hij niet zichtbaar is; tikkende tijden schrijven in de tekst zelf, niet via state van de hele lijst. Respecteer "Beweging verminderen".
7. **Eén naam per actie.** Label, tooltip, menu en VoiceOver zeggen hetzelfde ("Sessie afhandelen", "Sessie heropenen", "Sessie wekken"). Een test bewaakt de woordenlijst.
8. **De tekst van de agent is het luidst; het werklog is stil.** Tool-rijen zijn 24 pt hoog, gedempt, per beurt tot één zin samengevat; mislukken is een zacht rood icoon, geen schreeuw.
9. **Gemakken aan de rand.** Scrollpositie per sessie onthouden, "Naar einde" zonder de focus te stelen, je eigen bericht bovenaan geankerd na het verzenden, elke handmatige scroll breekt het meelopen direct af.
10. **Wat kan, kan met het toetsenbord.** Cijfers 1–9 beantwoorden een vraag, ⌘K opent het palet, ⌘F zoekt in de sessie, ⌘1–9 springt naar een rij, ⌘↩ wisselt bijsturen en wachtrij.

### 4.2 Woordenlijst (nl; en/de volgen)

| Betekenis | Statuswoord | Korte rijvorm | Kleur en icoon |
|---|---|---|---|
| Wacht op jouw besluit | Wacht op goedkeuring | Goedkeuring | amber, schild |
| Wacht op jouw antwoord | Wacht op antwoord | Antwoord | amber, tekstballon met vraagteken |
| Fout | Mislukt | Mislukt | coral, uitroepteken |
| Gebruikslimiet | Limiet bereikt | Limiet | amber, klok |
| Bezig | Bezig | Bezig 3m | wit/iris, gestapte stip |
| Wacht op achtergrondwerk | Wacht | Wacht | gedempt, stippellijn |
| Plan voorgesteld | Plan klaar | Plan | iris, lijstje |
| Klaar, nog niet gezien | Klaar | Klaar | mint, vinkje |
| Snooze voorbij | Wakker | Wakker | amber, wekker |
| Gesnoozed | Gesnoozed tot 9:00 | – | blauwgrijs, klok |

Kleur is nooit het enige verschil (zwakte): elke status heeft een eigen icoon en woord, ook in de samengevatte projectrij en de notch-ring. Eén bron: een `AgentStatusStyle` die uit `AgentAttention` woord, kleur en symbool afleidt (testbaar). Het verschil tussen pil ("Pending Approval") en rij ("Approval") verdwijnt: Nook heeft per status één lange en één korte vorm, en gebruikt ze overal op dezelfde plek.

### 4.3 Per scherm

**Sessielijst (met F4)**
- Rij, drie regels: agentlogo met account · projectnaam; titel (14, medium, één regel); branch (midden ingekort), PR-badge, `+12 −3` in mono en tijd. Het rechterslot wisselt zonder verspringen tussen status/tijd en de hoveracties (Snoozen, Afhandelen).
- Secties: *Vastgezet* (zonder kop), *Actief*, *Bezig* (vouwbaar, standaard **aan**: verstopt dit achter een bètaschakelaar en het is hun beste idee), *Gesnoozed (n)* in blauwgrijs, *Afhandelen (n)* onderaan met "Toon er 10 meer". Kop: label, aantal, haarlijn, chevron.
- Slepen binnen een sectie herordent; slepen naar een andere sectie verandert de staat en de sleepkaart noemt de actie ("Vastzetten", "Afhandelen", "Wekken"). Niet neerzetten in Gesnoozed (tijd nodig): een korte hint in plaats van niets. Dubbelklik hernoemt; Esc annuleert.
- Rechtermuisknop: Nieuwe sessie op branch, Vastzetten, Afhandelen, Snoozen ▸ (een uur, vanavond, morgenochtend, Eigen tijd…), Hernoemen, Titel opnieuw schrijven, Markeren als ongelezen, Vork maken, Kopiëren ▸ (pad, branch, id), Archiveren (grijs als hij werkt), Verwijderen (rood, met bevestiging). Meerdere rijen geselecteerd: "Afhandelen (3)".
- **Ongedaan maken** staat in de lijst zelf én als regel boven het invoerveld ("3 sessies afgehandeld · ⌘Z"), 5 s, samengevoegd per soort. toont het alleen onderaan de zijbalk, waar het verdwijnt als de balk dicht is.
- ⌘ ingedrukt (200 ms) toont ⌘1–9 op de rijen. Zoeken in de lijst (titel en berichten vanaf twee tekens). Lege staten die richting geven ("Nog geen sessies. Begin er een met +.").
- In de notch zelf: de lijst is al links; op de ring en in de dichte notch telt alleen de hoogste prioriteit, met één woord op hover.

**Invoerveld (met F1–F3)**
- Eén glazen kaart; de rij eronder: plus-menu, agent/account/model, modus, rechten, contextring, microfoon, actieknop. Bij smalle breedte eerst de labels weg (alleen icoon), daarna één "Meer"-menu; verborgen blokken blijven gemeten.
- **Actieknop** (rond, 30 pt): pijl omhoog = verzenden; rood vierkant = stop; bij werkende agent met tekst: bijsturen of wachtrij, en het icoon wisselt live als je ⌘ indrukt; play = hervatten (gelimiteerd, onderbroken, vastgehouden wachtrij); vinkje = wijziging aan een wachtrijbericht opslaan. Tooltip en VoiceOver noemen altijd de reden bij uitgeschakeld ("Agent niet verbonden", "Worktree wordt klaargezet").
- Na bijsturen of in de wachtrij zetten een korte bevestiging in het veld ("Bijgestuurd" / "In de wachtrij"); laat dat alleen aan het icoon over.
- **Placeholders per toestand**, kort, met de toetsen als chips eronder in plaats van in de tekst (lange placeholder wordt afgekapt): normaal "Vraag iets of typ / voor commando's", goedkeuring "Los dit verzoek op om door te gaan", vraag met opties "Kies een optie hierboven", vraag met tekst "Typ je eigen antwoord, of laat leeg om de gekozen optie te gebruiken", plan klaar "Geef feedback om het plan aan te scherpen, of laat leeg om het uit te voeren".
- **Banners als lade** aan de bovenrand: volgorde activiteit (synchroniseren, taken, achtergrondwerk) → dringend/fout/waarschuwing → meldingen; de rest als smalle rand eronder, hover of klik klapt open, Esc klapt in. Lange tekst wordt afgekapt met een infoknop, de lay-out verspringt nooit. Voorbeelden: "Gebruikslimiet bereikt · reset 14:30 · Hervat bij reset · Snooze tot reset", "Branch veranderd — was `x`", "Agent is niet ingelogd · Inloggen".
- **Wachtrij** boven het veld: kop "In de wachtrij (n)", inklapbaar; per rij een sleepgreep, tekst, bewerken (Alt+↑ voor de laatste), "Nu bijsturen", verwijderen; je concept komt na het bewerken terug.
- **Contextring** (20 pt, begint bovenaan, coral boven 90 %); hover: "Contextvenster 42 % · 84k/200k", kosten, en een knop "Samenvatten (/compact)" die zegt waarom hij uit staat. Een chip "Eerst samenvatten (120k)" links van verzenden, amber als hij aan staat.
- Een rustende vorm van het veld (één regel terwijl je door de geschiedenis leest, uitklappen bij focus of tekst) is voor het venster; in de notch niet, want daar is de ruimte al klein.

**Goedkeuren, vragen, geheimen (met F2, F5)**
- Een verzoek vervangt de actiekant van het invoerveld. Kop in amber: "Opdracht goedkeuren" / "Bestandswijziging goedkeuren" / "Bestand lezen" / "Rechten voor app", app of agent, `1/3`, het hele detail in mono (scrollbaar, focusbaar). Knoppen: **Weigeren** en **Toestaan**; "…" bevat Annuleren en "Toestaan voor deze sessie"; opties met risico krijgen een driehoek en uitleg. Altijd een weigerroute die de agent eerlijk accepteert.
- **Beter dan **: bij meerdere verzoeken kun je de rij doorlopen (‹ ›) en "Alles in deze beurt toestaan" kiezen, met de volledige lijst eerst zichtbaar. Verzoek van een subagent toont zijn herkomst.
- "Agentproces is weg — onderbreek of herstart de sessie om te antwoorden" in plaats van een dode knop.
- **Vragen**: kaart met kop, `i/N`, inklapbaar (dan kun je het veld gebruiken), vraag in Markdown, opties als volle rijen met cijfer 1–9 rechts; één keuze gaat na 200 ms door naar de volgende; meerkeuze wacht op Volgende; typen geeft een eigen antwoord en wint van de keuze; een leeg antwoord gebruikt de gekozen optie. Bijlagen bij een antwoord. Een zichtbare regel: cijfers werken niet terwijl het veld focus heeft.
- **Geheimverzoek** (nieuw voor Nook): de agent vraagt een sleutel; een kaart met een afgeschermd veld en "Veilig bewaren", opgeslagen in `SecretStore` (Sleutelhanger), nooit aan de agent getoond, "Weigeren" ernaast; daarna één regel "GitHub-token · bewaard".

**Tijdlijn (met F5)**
- Eigen bericht: rechts, ronde bubbel, max. 80 %, lange berichten ingeklapt met "Toon alles"; hover toont tijd, kopiëren, "Bewerken vanaf hier". Agent: geen bubbel, gewone Markdown over de volle breedte, daaronder Kopiëren en Vork maken vanaf dit antwoord.
- **Werkgroepen**: kop met één zin ("3 commando's uitgevoerd en 2 bestanden gewijzigd"), hooguit twee categorieën, daarna "en 2 andere acties"; alleen denken is "Gedacht (×3)". Uitgeklapt: 24 pt-rijen met icoon, gedempt label, chevron; daaronder mono-paneel met opdracht, argumenten en uitvoer, `exit 1` in rood, "Geen uitvoer." Mislukken: zacht rood icoon; **beter dan **: de kop krijgt een knop "Ga naar fout" zodat een mislukking midden in een groep niet gemist wordt.
- **Live regel**: de eerste zin van de laatste gedachte van het model met een lichte glans, niet een generieke spinner. Daaronder "Bezig · 42 s"; **beter**: na 60 s zonder nieuw bericht "Laatste activiteit 1m geleden" (stilstandhint). Speciale vormen: "Worktree klaarzetten…", "Samenvatten…".
- **Beurten vouwen**: "Gewerkt 1m 12s", "Je stopte na 12s", en een eerder, bijgestuurd poging als kaart "Vervangen poging · afgebroken door bijsturen". Contextsamenvatting als scheidingslijn "Context samengevat 120k → 38k".
- **Scrollmodel met drie standen**: *volgen* (vastgepind aan het einde), *verankeren* (na verzenden staat je bericht 24 pt onder de bovenrand en groeit het antwoord eronder), *vrij* (elke handmatige scroll, zoekopdracht of sprong breekt het volgen direct af, ook uitgestelde scrolls). Per sessie onthouden. Pil "↓ Naar einde" verschijnt na 150 ms, verdwijnt direct, steelt geen focus.
- **Zoeken** (⌘F): pil rechtsboven, "3/12", Enter/Shift+Enter, Esc; zoekt de hele sessie (ook ingeklapte plannen en groepen, die zich openen); nul resultaten kleurt het aantal rood; "Zoeken mislukt · Opnieuw". Minimap (venster, niet notch): dunne streepjes per eigen bericht met een voorbeeld op hover.
- **Wijzigingenkaart** na het antwoord: "4 gewijzigde bestanden +120 −8", boom met geaggregeerde cijfers, klik opent de diff op dat bestand; **diffpaneel** met bereik (Laatste beurt / Beurt n / Niet vastgelegd), naast elkaar of onder elkaar, per bestand laden.
- **Plankaart**: badge "Plan", titel, voorbeeld van 10 regels met "Plan uitklappen", menu Kopiëren / Downloaden / Bewaren in de werkmap; daaronder "Uitvoeren" met pijl voor "In een nieuwe sessie uitvoeren", en met tekst wordt de knop "Aanscherpen".
- **Subagentbalk** (alleen-lezen kindsessie vervangt het veld): agent, model, inspanning, tikkende tijd, "Draait zelfstandig", "Open ouder".

**Navigatie en starten (met F9)**
- **Palet (⌘K)**: placeholder "Zoek opdrachten, projecten en sessies…", beginweergave *Acties* en *Recente sessies*; typen toont ook Projecten, Instellingen (zoekbare rijen) en Sessies; `>` toont alleen acties (en de placeholder zegt dat, anders dan); rijen met icoon, titel, uitleg en sneltoets; voetregel met toetshints.
- **Nieuwe sessie** heeft de kop-als-bediening al ("Wat zullen we bouwen in *map*?"). Erbij: starten op de achtergrond (⌘↩ start en opent meteen een nieuw concept met dezelfde werkwijze en basisbranch), meerdere modellen met Shift-klik uitwaaieren naar parallelle sessies, een sessie zonder project in een gedateerde krabbelmap, en toetsen voor werkwijze (⇧⌘X) en branch (⇧⌘G).
- **Instellingen**: zin bovenaan "Instellingen voor [Alle projecten ▾]" met de woorden als inline-keuzes; per rij herkomst ("Overgenomen van het project", "Overschreven voor dit project"), een terugzetknop, en uitgeschakeld-met-reden; zoeken in instellingen scrolt naar de rij en laat een ring tweemaal pulseren (bij verminderde beweging alleen de focusrand). De zin verdwijnt op pagina's zonder bereik **niet stilzwijgend**: er staat dan "Alleen op dit apparaat".
- **Welkomstflow** voor agents (Nook heeft er al een): stappen Verbinden · Agents · Sessies overnemen; "Klaar om te coderen." of een knop die een terminal opent met het installatiecommando **ingetypt maar niet uitgevoerd** ("Controleer het commando en druk op Return"); bij overnemen vooraf geselecteerd wat in 30 dagen actief was met minstens 3 gesprekken, "3 van 8 geselecteerd", en naast de hoofdknop een stille "Niets overnemen".

**Meldingen en de notch (met F1, F10)**
- Een melding verschijnt in de app alleen als Nook zichtbaar is én je niet in die sessie bent; anders een systeemmelding, gemerkt per sessie (wordt bijgewerkt, niet gestapeld), met een badge die verdwijnt bij focus. Twee geluiden: klaar en aandacht. Tekst: wat er is ("Goedkeuring nodig", "Klaar", "Limiet bereikt", "Mislukt", "Antwoord nodig") plus de sessietitel en één knop "Openen". Eén `AttentionLedger` per sessie en toestand zodat het niet dubbel gaat.
- **Beter dan (notch)**: een hover op een rij in de notch toont een kaartje met precies wat nodig is: de opdracht met Weigeren/Toestaan, of de vraag met opties, zonder het paneel te openen. ⌥⌘A opent het oudste verzoek (nooit zelf toestaan).

**Gebruik en limieten (met F9)**
Gebundelde limietbalk per agent en venster: één balk met een segment per account in vaste volgorde, een gearceerd stuk voor wat de volgende reset teruggeeft, en een tempolijn ("Zo zou gelijkmatig besteden eruitzien"; Voor / Op schema / Achter). Een zelfde account op meerdere plekken telt één keer. De eigen bedragen en een filter per agent erbij.

### 4.4 Ontwerptaal

- **Dichtheid**: knoppen en pillen 26 pt (pil), 30 pt (ronde actie), 24 pt (klein), rijen 24 pt (tool) en 36 pt (smal), lijstrij ongeveer 64 pt; tussenruimte 1–2 pt in lijsten. Maximumbreedte van de gespreksbaan 46 em.
- **Tekst**: Nooks bestaande schaal; geen tekst kleiner dan 11 pt, gedempte tekst minstens 4,5: 1 op zijn ondergrond (een audit-test op de tokens), cijfers `monospacedDigit`.
- **Gewicht draagt betekenis**: aandacht en ongelezen medium, gedempte rijen normaal.
- **Kleur per betekenis, niet vol**: badges en pillen als lichte tint (8 % licht, 16 % donker) met eigen voorgrondtint, alleen verzenden en Toestaan zijn effen. Donkere modus kalm, niet neon.
- **Straalvormen**: veld 20, kaart 14, pil 7, badge 4; menu's en lijsten volgen de bestaande `NookTheme`.
- **Beweging**: alleen transform en opacity; chevron 150 ms; lijstherordening 150 ms; banners 150–220 ms; contextring 500 ms; "bezig" pulseert in stappen (6 stappen over 2 s) en een animatie pauzeert als hij niet zichtbaar is of als de notch dicht is. Geen aparte animatie bij het openen van een sessie.
- **Iconen**: SF Symbols, 11–14 pt, altijd met woord of tooltip; het projecticoon of de agentlogo is het herkenningsteken van een rij.
- **Stem**: kort, tegenwoordige tijd, geen uitroeptekens. Werkwoorden noemen het voorwerp. Aantallen tussen haakjes. `…` (het teken) voor "gaat verder" of laden. Fouten: "Kon <werkwoord> <voorwerp> niet" met de reden en, als die er is, de volgende stap. Beschrijvingen leggen gevolgen uit, geen werking.

### 4.5 Stappen van het UX-spoor

| Stap | Inhoud | Met | Klaar als |
|---|---|---|---|
| U0 | `AgentStatusStyle` (woord, kleur, symbool uit `AgentAttention`), `NookBadge` (getinte badge), `SteppedPulse` en `VisibleAnimation` (pauzeert buiten beeld), woordenlijst in `I18n+Agents` met een test op gelijke woorden per actie, contrast-audit op de tokens | F0–F1 | één bron voor status; geen losse statuskleuren meer in views |
| U1 | Actieslot dat verandert, placeholders per toestand, bevestiging na bijsturen/wachtrij, tooltips met reden | F1 | alle zeven standen van de knop bestaan, elk met uitleg |
| U2 | Banners als lade met prioriteit, wachtrijstrook (slepen, bewerken, bijsturen), contextring en samenvatten-chip | F1, F3 | geen banner verschuift het veld |
| U3 | Goedkeurings-, vraag- en geheimpanelen, doorlopen van meerdere verzoeken, "Agentproces is weg" | F2, F5 | één beslissing tegelijk; cijfers 1–9; geheim nooit zichtbaar voor de agent |
| U4 | Lijstrij-anatomie, secties, slepen met actiekaart, contextmenu, ongedaan maken (⌘Z) in lijst en veld, ⌘1–9, zoeken, lege staten | F4 | elke omkeerbare actie heeft ongedaan maken |
| U5 | Tijdlijn: werkgroepzin, live regel, vouwen, scrollmodel met drie standen, "Ga naar fout", stilstandhint, zoeken, wijzigingenkaart, diff, plankaart, subagentbalk | F5 | scrollpositie onthouden; zoeken vindt ook oude beurten |
| U6 | Palet, starten op de achtergrond, uitwaaieren, krabbelsessie, instellingen met bereikzin en herkomst, welkomststappen | F9 | alles ook met het toetsenbord |
| U7 | Meldingen (app of systeem, per sessie, badge, twee geluiden), hover-kaartje in de notch, gebundelde limietbalk | F1, F10 | geen dubbele melding; goedkeuren zonder het paneel te openen |
| U8 | Toegankelijkheid en prestaties: labels op elk icoon, live regions, VoiceOver-volgorde, verminderde beweging, frame- en geheugenbudget | doorlopend | zie de checklist |

**UX-checklist per scherm** (afvinken voor een stap klaar is): elk icoon heeft een naam · elke uitgeschakelde knop zegt waarom · elke omkeerbare actie heeft ongedaan maken · geen animatie loopt buiten beeld of bij "Beweging verminderen" · tekst ≥ 11 pt en contrast ≥ 4,5 : 1 · alles bereikbaar zonder muis · woorden volgens §4.2 · nl/en/de · lege, laad- en foutstaat ontworpen.

**Meetbaar "beter dan "**: van "wacht op jou" naar beslissing in ≤ 2 acties vanuit elke staat van Nook; toetsaanslag tot zichtbare letter < 16 ms in een sessie van 5.000 events; geen dropped frames tijdens streamen met 10 lopende sessies; nul gemiste goedkeuringen in een gesimuleerde reeks van 20 verzoeken.

## 5. Per stap werken

Voor elke stap hierboven, in deze volgorde:

1. Het gedrag lezen (bestand en regel noteren in de commit).
2. De pure kern schrijven met tests (Foundation, `core-tests.sh`).
3. `WorkspaceManager`-koppeling en de view.
4. Per agent beslissen: werkt, of zichtbaar niet beschikbaar (capability).
5. nl/en/de, docs (`docs/AGENTS-PARITY.md` bijwerken), en de `I18nCoverageTests`.
6. CI groen, dan pas de volgende stap.

## 6. Risico's

- **Niet gecompileerd op macOS**: de UI-code van deze branch is alleen op syntaxis gecontroleerd. F0 gaat daarvoor.
- **Agents veranderen** (Claude Code, Codex, ACP): daarom replay-fixtures met de versie erbij, en een duidelijke foutmelding bij een onbekend bericht.
- **Omvang van `WorkspaceManager`** (al ruim 1.400 regels): nieuwe logica gaat in extensies en pure types, niet in dat bestand.
- **Veiligheid van het MCP-eindpunt (F7)**: standaard alleen lezen, geen rechten boven het plafond, intrekbaar, en in het audit-logboek.

## 7. Besluiten die van jou zijn

1. **Opslag (F8)**: JSON houden of naar SQLite? Aanbeveling: SQLite zodra F5 (tool-uitvoer als handvat) klaar is.
2. **Remote en mobiel**: heeft web, desktop en mobiel via een server. Nook is een Mac-app. Een iPhone-metgezel (meldingen, goedkeuren, antwoorden) is een eigen project; aanbeveling: pas na F7, begonnen met alleen goedkeuren en antwoorden.
3. **Welke bronnen na GitHub (F6)**: GitLab eerst?
4. **Prioriteit F10 versus F4–F7**: aanbeveling is eerst F0–F3 (betrouwbaarheid), dan F10.1 en F10.2 omdat ze Nook het meest onderscheiden, en F4–F7 daarna.
5. **Een build van deze branch**: een pull request openen (of mij laten openen) zodat de CI draait.
6. **UX-spoor**: eerst U0–U2 (status, actieknop, banners) omdat ze in elke latere stap terugkomen, of eerst het werk aan de lijst (U4)? Aanbeveling: U0–U3 bij F1–F2.
