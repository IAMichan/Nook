# Nook herontwerp: audit en plan

> Status: **akkoord, in uitvoering.** Besluiten op de open vragen (onderaan): V1 Instellingen blijft een eigen venster · V2 Nook stelt per gebruiker zelf het beste lokale model voor (op basis van chip, geheugen en wat er al geïnstalleerd is) · V3 SwiftTerm mag · V4 eerst MCP, en de koppelingsarchitectuur zo dat nieuwe koppelingen met weinig werk toe te voegen zijn · V5 Koppelingen- en Shelf-tab mogen uit de notch · V6 fase 0 direct.
>
> Oorspronkelijke status bij oplevering: voorstel. Er was toen nog geen code gewijzigd. Dit document is gebaseerd op het lezen van de volledige repository op commit `1a9169a` (41.000 regels Swift, 142 bestanden). Bouwen en draaien kon in deze omgeving niet (Linux, geen Xcode); elke implementatiestap wordt daarom als eigen pull request door de macOS-CI (build + `NookTests`) gecontroleerd.
>
> Legenda bij problemen: **[code]** = vraagt een codewijziging in logica of data · **[UI]** = vooral op te lossen met een beter ontwerp of een andere plek · **[beide]**.

---

## 1. Huidige structuur en de belangrijkste problemen

### 1.1 Hoe Nook nu in elkaar zit

| Laag | Wat er staat | Opvallend |
|---|---|---|
| `App/` | `AppModel` (2.291 regels + 2 extensies), instellingen, chatmodel `NookChat`, suggesties | `AppModel` doet bijna alles: chat, plannen, kaarten, agents, accounts, stem, meedenken, onboarding, weekoverzicht. Het stuurt wijzigingen van 9 diensten door, waardoor elke OCR-ronde (7 s) of muziekpoll (2 s) alle views opnieuw laat tekenen. |
| `Brain/` | Aanbieders, 4 tool-loops, tools, bronkeuze, grootboek, actiecontrole | Goed getest fundament (`ActionGate`, `Retrieval`, `SourceScope`), maar 4 kopieën van dezelfde tool-loop en ~10 losse regex-classificaties. |
| `Core/` | Paden, instellingen + Keychain, SQLite, vertalingen | Geen migraties, geen versies op bestanden. |
| `Services/` | Koppelingen, agent-hub, werkruimte, scherm, stem, muziek | Werkruimte is netjes gescheiden; agent-informatie komt uit 4 bronnen met 4 sessiemodellen. |
| `NotchUI/` | Notch, 6 tabs, chat, kaarten, werkruimte-venster | `AgentsTab.swift` (2.254 regels) is een complete tweede werkruimte in de notch. |
| `Demo/` | Voorbeelddata | Bevat ook echte modeltypes (`AgentSession`, `AgentStatus`, `TodayItem`). |

### 1.2 De oppervlakken die er nu zijn

| Oppervlak | Bestand | Opent via |
|---|---|---|
| Notch (of zwevend), 6 tabs: Nook, Chat, Agents, Koppelingen, Muziek, Shelf | `NotchUI/Pills/*`, `NotchRootView.swift` | hover, klik, ⌥⌘spatie, ⌥spatie |
| Kaarten in de notch (welkom, antwoord, plan, goedkeuring, meedenken, weekoverzicht, fout) | `NotchUI/Cards/*`, kaartfabrieken in `AppModel.swift:2154-2290` | automatisch |
| Instellingen-venster, 7 secties | `App/SettingsView.swift` + `SettingsAccounts`, `ConnectorSettingsSection`, `PortfolioSettings` | ⌘, menubalk, ~10 deeplinks |
| Werkruimte-venster: Sessies, Worktrees, Gebruik | `NotchUI/Workspace/*`, `AppModel+Workspace.swift:24` | ⌥⌘W, knop in Agents-tab, Instellingen |
| Menubalk-menu (incl. "Demo-scènes") | `App/AppDelegate.swift:29-73` | menubalk |

Er is **geen chatvenster**: chat bestaat alleen in de notch. Er is **geen ingebouwde browser of terminal**.

### 1.3 De tien belangrijkste problemen

1. **Er is geen hoofdvenster als centrale plek; de notch draagt te veel.** **[UI]** Chat, agentbeheer, accountbeheer en sessie-instellingen zitten allemaal in een paneel van ~860×420 pt. Het werkruimte-venster is los daarvan gegroeid en doet deels hetzelfde.
2. **Dezelfde functies staan op meerdere plekken** (zie §3). **[beide]**
   - Accountbeheer: 4 plekken.
   - Gebruik en limieten: 5 plekken.
   - Goedkeuringen: 4 plekken.
   - Nieuwe sessie starten: 3 plekken.
   - Koppelingstatus: 3 plekken.
3. **Lokale AI is niet de standaard en bestaat in twee losse systemen.** **[code]**
   - Standaard is Claude in de cloud: `AppSettings.swift:265` valt terug op `.claude`, en `useLocal` staat standaard uit.
   - Het ingebouwde MLX-model is een losse schakelaar. Ollama en LM Studio zijn "aanbieders" naast de cloud.
   - Alle aanpassingen voor kleine modellen hangen aan `useLocal`. Ollama en LM Studio krijgen daarom alle ~58 tools (~6.000 tokens), de volledige cloudprompt en tot 12.000 tekens schermtekst, zonder `num_ctx`.
4. **Er zijn vier tool-loops.** **[code]** Ze staan in `BrainService.swift:111`, `AIProvider.swift:174`, `ClaudeCodeBrain.swift:55` en `EmbeddedModel.swift:193`. Elk heeft eigen limieten, eigen foutafhandeling en een eigen redding voor JSON in tekst; die redding ontbreekt bij Ollama.
5. **Er is geen tool discovery.** **[code]** Per vraag gaan alle tools van alle toegestane bronnen mee. Kiezen gebeurt met regexen, niet door het model. De lokale systeemprompt belooft tools die in de chat juist worden weggehaald (`AppModel.swift:603`).
6. **Accounts zijn versnipperd over vier systemen, en twee accounts per dienst kan niet.** **[code]**
   - AI-sleutels: `AppSettings`.
   - Agent-accounts: `AgentProfiles`, het enige systeem met meerdere accounts.
   - Koppelingssleutels: vaste Keychain-namen `connector.<id>.<veld>`.
   - Portfolio: eigen logica.
   - Twee GitHub-accounts zijn daardoor onmogelijk.
7. **Agents hebben vier sessiemodellen voor hetzelfde.** **[code]**
   - `AgentSession`, gevoed door hooks en processcan.
   - `PastSession`, uit transcripten.
   - `WorkspaceRun`, voor sessies die Nook zelf draait.
   - `AgentHub.Record`.

   Eén gesprek kan zo twee keer in de lijst staan (`AgentsTab.swift:50`, `:272`). Twee processen in dezelfde map vallen samen (`AgentHub.swift:148`).
8. **Er zijn twee chatpijplijnen.** **[code]**
   - De chat gebruikt bronkeuze, het grootboek, bronverwijzingen en controle per veld.
   - Notch-kaarten en Meedenken gebruiken het oude pad `runBrain` (`AppModel.swift:1057-1232`). Daar gaan alle tools mee, zonder bronkeuze, zonder grootboek en zonder bewerkbare controle.
9. **Gebruikersdata kan verloren gaan.** **[code]**
   - `nooks.json`, `runs.json` en `agentProfiles` worden met `try?` gelezen. Mislukt dat, dan wordt de lege toestand bij de volgende opslag over het bestand heen geschreven (`NookChat.swift:431`, `RunStore.swift:43`, `AgentProfiles.swift:127`).
   - Geen van deze bestanden heeft een versienummer.
   - SQLite heeft geen migraties.
10. **Er zijn beveiligingsgaten die de "niets zonder jouw klik"-belofte ondermijnen** (zie §11). **[code]** Het meest ernstig: het Claude Code-brein mag zonder controle `WebFetch` gebruiken en bestanden in de Nook-map lezen.

---

## 2. Inventaris van bestaande functionaliteit

**Werkt**: code nagelopen en logisch compleet. **Deels**: werkt met duidelijke gaten. **Demo**: alleen voorbeeld. **Ontbreekt**: niet gebouwd.

### Chat en brein

| Functie | Staat | Waar | Opmerking |
|---|---|---|---|
| Chat met meerdere gesprekken (Nooks), streaming, markdown | Werkt | `NookTab.swift:142-612`, `NookChat.swift` | Maximaal 40 gesprekken; geen zoeken, hernoemen of archiveren |
| Bronkeuze uit de vraag + bronkiezer per Nook | Werkt | `SourceScope.swift` | Trefwoorden (nl/en/de), geen taalbegrip |
| Grootboek, bronchips, genummerde verwijzingen | Werkt | `Retrieval.swift` | Getest |
| Plannen met controle per stap, geen dubbel uitvoeren, audit | Werkt | `ActionGate.swift`, `AppModel.swift:784-908` | Geen status "goedgekeurd" of "gecontroleerd" |
| Grafieken, mail opstellen, vervolgvoorstellen | Werkt | `ChartRescue.swift`, `MailDraftView.swift`, `FollowUps.swift` | |
| Snelle opdrachten zonder brein | Werkt | `LocalIntent.swift` | Alleen nl/en |
| Claude API (streaming, caching, web search) | Werkt | `BrainService.swift:92-181` | Web search negeert "zonder web" |
| OpenAI-compatibel (OpenAI, Gemini, Grok …) | Deels | `AIProvider.swift:152-243` | Geen streaming, geen redding voor JSON in tekst |
| Claude Code als brein | Deels | `ClaudeCodeBrain.swift` | Tekstprotocol, ~120 s risico, beveiligingsgat |
| Ingebouwd MLX-model | Deels | `EmbeddedModel.swift` | 3 modellen, KV 4.096, max 450 tokens uit, geen contextbudget |
| Ollama / LM Studio | Deels | `AIProvider.swift` | Krijgt de cloudbehandeling: alle tools, geen `num_ctx` |
| Tool discovery / gefaseerde tools | Ontbreekt | | |
| Gebruik en kosten van Nooks eigen brein | Ontbreekt | | |

### Bronnen en koppelingen

| Functie | Staat | Opmerking |
|---|---|---|
| Agenda, herinneringen, Mail, browsertabs, bestanden, klembord, Notities | Werkt | Notities heeft geen schakelaar in Instellingen (`SettingsView.swift:617`) |
| Andere agenda's (ICS), Cal.com, beschikbaarheid over alle agenda's | Werkt | |
| GitHub (lezen + PR/issue-acties) | Werkt | Inloggen via device flow staat uit (`GitHubSignIn.swift:16`, lege `clientID`); werkt met token |
| Vercel, Stripe, Notion, n8n, Resend, crypto-portfolio | Werkt | Alleen lezen; n8n accepteert ook http |
| Eigen bronnen (API/webhook, Slack/Discord/Teams/Telegram sturen) | Werkt | Alle headers in één Keychain-item |
| Meerdere accounts per dienst | Ontbreekt | |
| OAuth (anders dan GitHub-stub), MCP | Ontbreekt | |
| Slack/Teams lezen, Gmail/Google Drive/OneDrive direct, Linear/Jira | Ontbreekt | Staat eerlijk in "Nog niet ingebouwd" |

### Agents en werkruimte

| Functie | Staat | Opmerking |
|---|---|---|
| Hooks voor 11 agents, voortgang in de notch | Werkt | Hooks niet getest met de huidige agentversies |
| Goedkeuren en vragen beantwoorden vanuit de notch | Werkt | Alleen Claude Code en Codex; het Codex-antwoordformaat is niet geverifieerd |
| Processen herkennen, geschiedenis uit transcripten | Werkt | Dubbele vermelding, wrong-conversation-risico (`AppModel+Agents.swift:25`) |
| Meerdere accounts per agent (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) | Werkt | Inloggen via Terminal-venster; Gemini maar één account |
| Nook draait zelf Claude Code / Codex (stream-json), hervatten, forken, stoppen | Werkt | Codex zonder goedkeuringen; alleen sandbox |
| Worktrees, commit, push, PR | Werkt | Getest; branches worden nooit opgeruimd |
| Gebruik per sessie (tokens/kosten), limieten Claude/Codex | Deels | Codex-limiet alleen voor het standaardaccount; Claude-limiet alleen uit interactieve sessies |
| Weekoverzicht | Deels | Telt sessies die Nook zelf draaide niet mee (`AgentHub.swift:300`) |
| Taakmodel (taken los van sessies) | Ontbreekt | |

### Overig

| Functie | Staat | Opmerking |
|---|---|---|
| Scherm-OCR van alle vensters, meekijken | Werkt | Uitsluitlijst voor wachtwoordmanagers is kort |
| Meedenken (proactieve hulp) | Werkt | Uit voor lokaal model; gebruikt het oude pad |
| Muziek (Spotify/Muziek) | Werkt | Bediening op 3 plekken geïmplementeerd |
| Stem, wekwoord, voorlezen | Werkt | Hard op nl-NL |
| Shelf | Deels | Bestanden verdwijnen bij tabwissel (`ShelfTab.swift:8` + `.id(tab)`) |
| Browser (ingebouwd) | Ontbreekt | Alleen tabbladen lezen via AppleScript en `WebTools` |
| Terminal (ingebouwd) | Ontbreekt | Alleen `.command`-bestanden openen in Terminal.app |
| Demo-scènes, voorbeelddata | Demo | Zit in productie-builds in het menubalk-menu; knoppen tonen nep-bevestigingen |
| Dode code | Opruimen | `AppModel.swift:1774-2002` (oude Terminal-flows), `lastAutoRun`, `streamedLines`, `lookAtScreen(manual:false)` |

---

## 3. Dubbele en verkeerd geplaatste onderdelen

Per onderdeel: wat het is, waar het hoort, wat leidend wordt, en wat weg kan.

| # | Wat dubbel is | Nu op | Hoort thuis in | Leidende implementatie | Wat weg kan | Soort |
|---|---|---|---|---|---|---|
| D1 | Accountbeheer (agents) | AgentsTab Accounts-modus (`AgentsTab.swift:1091-1440`), standaardaccount-wisselaars in de Agents-header (`:141`), Instellingen › Agents (`SettingsAccounts.swift`), werkruimte-toolbar (`WorkspaceView.swift:142`) | **Instellingen › Accounts** | `SettingsAccounts.swift` + `AgentProfileStore` | Accounts-modus en wisselaars in de notch. In het venster blijft één accountkeuze per sessie (in "Nieuwe sessie"). | beide |
| D2 | Gebruik en limieten | AgentsTab-strip (`:299`), accountdetail (`:1145`), Instellingen › Abonnementen (`SettingsView.swift:691`), werkruimte Gebruik (`UsageView.swift`), `RunInspector` | **Instellingen › Gebruik** (volledig). Per sessie alleen de eigen tokens in het detail. | `UsageReport` (`RunStore.swift:107`) + één `QuotaService` (nieuw, samengevoegd uit `AgentsTab.limits` en `UsageView.quota`) | 3 van de 5 weergaven, en de dubbele quotalogica | beide |
| D3 | Goedkeuringen | notch-kaart, AgentsTab live-detail, `AgentRunPanel.approval`, werkruimte `EventRow` + `ApprovalBar` | **Eén `ApprovalCenter`-model, één `ApprovalView`-component.** Getoond als kaart in de notch en inline in het sessiedetail. | `PendingPermission` + `ApprovalRequest` samenvoegen tot `AgentApproval` | Aparte UI's; dubbele weergave in `RunDetailView` (`EventRow` én `ApprovalBar`) | code |
| D4 | Een gestarte sessie volledig bedienen | `AgentRunPanel` (notch, 364 r.) én `RunDetailView` + `RunInspector` (venster, ~900 r.) | **Venster › Agents.** De notch toont een compacte samenvatting: status, laatste stap, goedkeuring, antwoordveld en "Open". | `RunDetailView` + `RunInspector` | Het menu in `AgentRunPanel` voor modus, rechten en model. Dat menu verhuist naar het venster, dat het nu mist (`configure(` heeft daar geen aanroeper). | beide |
| D5 | Nieuwe sessie | AgentsTab "+ Nieuw" en compose (`:935-1028`), `NewSessionSheet` (564 r.), knop bij "niets actief" | **Eén `NewSessionSheet`**, ook te openen vanuit de notch | `NewSessionSheet` | De compose-weergave in AgentsTab (~100 r.) | beide |
| D6 | Koppelingen | Koppelingen-tab (alleen status), Instellingen › Koppelingen (instellen), "awareness"-regel op Home | **Instellingen › Accounts & koppelingen.** Status zie je in de chat via de bronchips. | `ConnectorSettingsSection` | De **Koppelingen-tab** (314 r.). Gebruikersstromen die blijven: status per bron en handmatig verversen (verhuizen naar Instellingen) en voorbeeldvragen per bron (komen in het lege-chatscherm). | UI |
| D7 | Home vs Chat | Home-tab (begroeting, Vandaag, suggesties, invoer die naar Chat springt) en Chat-tab (lege staat, suggesties, invoer) | **Eén tab "Nook"**: een lege chat toont Vandaag en suggesties; een lopende chat toont het gesprek. | `NookChatView` | `NookHomeTab` als aparte tab; de dubbele suggestierijen (4 sets → 1, uit `SmartSuggestions`) | UI |
| D8 | Onboarding | welkomstkaart, checklist in Algemeen, setup-kaart, rijen in Privacy | **Eén eerste-keer-flow** in het hoofdvenster (3 stappen). Algemeen houdt een kleine statusregel "Klaar voor gebruik". | checklistlogica uit `SettingsView.swift:165-180` | Welkomstkaart; de setup-kaart wordt een knop naar de flow | beide |
| D9 | Weekoverzicht | menubalk, knoppen in Instellingen › Agents, Vandaag op maandag | **Vandaag** (in de lege chat) en de menubalk | `RecapStore` | Knoppen in Instellingen | UI |
| D10 | Twee chatpijplijnen | `answer()` vs `runBrain()` / `thinkAlongRun()` | **Eén `ChatController`-pijplijn**, met een "kaartweergave" als presentatievorm | `answer()` | `runBrain`, `showStreaming`, `recentExchanges` (~175 r.) | code |
| D11 | Vier tool-loops | zie §1.3 punt 4 | **Eén `ToolLoop`** met een adapter per runtime | nieuwe kleine kern, getest | De loopcode in de 4 brein-bestanden | code |
| D12 | Bronmetadata | in de connector én in `SourceCatalog`, `exactTools`, `aliases`, `SourceCapabilities.phrases`, `SourceRouter.intents` | **In de connector zelf** (`ConnectorDescriptor`) | — | De handmatige tabellen in `SourceScope.swift:38-326` worden afgeleid | code |
| D13 | Muziekbediening | `NowPlayingService.control`, tool `media_control`, Spotify via `ScreenReader` | `NowPlayingService` | `NowPlayingService` | De dubbele AppleScript in `NookTools.swift:289-313` | code |
| D14 | Kleine UI-componenten | `StatusDot`/`PulseDot`/`StatusBadge`; 2× `Chip`; `SectionHeader`/`WSSectionTitle`; 3 helpers voor relatieve tijd; 2 paletten (`NookTheme`, `WS`) | `NotchUI/Components` + `NookTheme` | — | De kopieën | UI |
| D15 | Taalinstelling | `AppSettings.appLanguage` en `I18n.language` schrijven dezelfde sleutel | `I18n` | — | Het veld in `AppSettings` | code |

**Verkeerd geplaatst (los van dubbel):**

| Wat | Nu | Naar | Soort |
|---|---|---|---|
| Modeltypes `AgentSession`, `AgentStatus`, `AgentStep`, `TodayItem` | `Demo/DemoContent.swift` | `Services/AgentModels.swift`, `App/Today.swift` | code |
| Standaardinstellingen voor werkruimte-sessies | Instellingen › Agents | Instellingen › Agents (blijft), maar alleen de *standaarden*; per sessie in "Nieuwe sessie" | UI |
| Demo-scènes en de schakelaar "Voorbeelddata" | menubalk-menu (productie) | alleen in debug-builds (`#if DEBUG`); voorbeelddata blijft in Instellingen › Algemeen | code |
| Knop "Instellingen" bij een chatfout | `NookTab.swift:384` | een herstelactie die bij de fout past ("Start Ollama", "Kies model", "Opnieuw verbinden") | beide |
| Shelf als eigen tab | `ShelfTab.swift` | slepen op de notch of de chat = bijlage; de lijst met recente bijlagen staat bij het invoerveld | UI |
| `SmallGhostButton` | `Chat/MailDraftView.swift:151` | `Components/NookButtons.swift` | code |

---

## 4. Voorgestelde navigatie en paginastructuur

Nook krijgt **drie oppervlakken** met elk een duidelijke taak. Er komt geen vijfde of zesde los venster bij. Het bestaande werkruimte-venster groeit uit tot het hoofdvenster.

```
┌ Notch (compact, altijd bij de hand) ───────────────────────────────────┐
│  In rust:  Nook-figuur · stipje per actieve agent · muziek-equalizer   │
│  Kaarten:  goedkeuringen · vragen van agents · meedenken · klaar-meldingen │
│  Paneel:   [Nook]  [Agents]  (+ [Muziek] alleen als er iets speelt)    │
└────────────────────────────────────────────────────────────────────────┘
┌ Hoofdvenster "Nook" (⌥⌘W, of "Open in venster" vanuit de notch) ───────┐
│  Zijbalk:   Chat  ·  Agents  ·  Werkruimte                             │
└────────────────────────────────────────────────────────────────────────┘
┌ Instellingen (⌘,) — de enige plek voor configuratie ───────────────────┐
│  Algemeen · Brein · Accounts & koppelingen · Assistent · Agents ·      │
│  Gebruik · Privacy & beveiliging · Stem & geluid                       │
└────────────────────────────────────────────────────────────────────────┘
```

**Waarom Instellingen een eigen venster blijft:** dat is de macOS-conventie (⌘,). Het venster is er al en werkt goed (`NavigationSplitView`), en zo blijft het hoofdvenster rustig. Wil je het liever als vierde onderdeel in de zijbalk van het hoofdvenster, dan is dat een kleine wijziging (open vraag V1).

### 4.1 Notch

| Tab | Inhoud | Herkomst |
|---|---|---|
| **Nook** | Lege chat: begroeting, *Vandaag* (agents die wachten, volgende afspraak, open punten, gemiste voorstellen, weekoverzicht op maandag), 3–4 suggesties en het invoerveld. Lopende chat: het gesprek, compact, met "Open in venster". Een smalle lijst met recente Nooks is in te klappen. | samenvoeging van `NookHomeTab` + `NookChatTab` |
| **Agents** | Eén lijst "Nu actief + wacht op jou" (alle bronnen samengevoegd, zie §8). Per sessie de compacte samenvatting met goedkeuring/vraag, een antwoordveld en de knoppen "Open" (venster) en "Stop". Bovenaan "+ Nieuwe sessie" (opent de sheet). | ingekorte `AgentsTab` + `AgentRunPanel` |
| **Muziek** | Huidige bediening. De tab verschijnt alleen als Spotify of Muziek draait; anders is muziek bereikbaar via de muziekstatus in rust. | `MusicTab` (ongewijzigd) |

De **Koppelingen-tab en de Shelf-tab verdwijnen** (zie D6 en de tabel hierboven). Hun functies blijven bestaan op de nieuwe plek.

### 4.2 Hoofdvenster "Nook"

| Onderdeel | Pagina's en functies | Herkomst |
|---|---|---|
| **Chat** | Zijbalk met alle Nooks: zoeken, hernoemen, vastzetten, archiveren, status. Het gesprek op volle breedte, met de bron- en accountkiezer bij het invoerveld, bijlagen (slepen), bronchips, plannen. "Nieuwe chat" (⌘N) met optionele beperking van bronnen en accounts (§7). | `NookChatView` (verplaatst naar `NotchUI/Chat/`), hergebruikt in notch en venster |
| **Agents** | Zijbalk: *Wacht op jou* · *Actief* · *In Nook* (sessies die Nook draait) · *Eerder* (transcripten), met filters op agent, account, project en status. Detail: tijdlijn, goedkeuringen, antwoorden, modus, rechten en model per beurt, stop, hervat, opnieuw. Inspector: map, branch, wijzigingen, commit/push/PR, gebruik van deze sessie. | `WorkspaceSidebar`, `RunDetailView`, `RunInspector`, aangevuld met hook- en eerdere sessies uit `AgentsTab` |
| **Werkruimte** | *Terminals* (sessies die Nook en agents gebruiken), *Browser* (één ingebouwde browser met tabbladen), *Worktrees en projecten*. | `WorktreesView` + nieuw (§9) |

### 4.3 Instellingen

| Sectie | Inhoud | Herkomst |
|---|---|---|
| Algemeen | Taal, notch (plek, schermen, hover), sneltoetsen, de statusregel "Klaar voor gebruik", voorbeelddata | Algemeen, zonder de checklist |
| **Brein** | **Lokaal (standaard)**: actief model, geïnstalleerde modellen (MLX, Ollama, LM Studio in één lijst), downloaden, geheugen, test. **Extern (bewuste keuze)**: aanbieder, account, model. Verder de antwoordtaal en "Web gebruiken". | Brein, geherstructureerd |
| **Accounts & koppelingen** | Eén lijst gegroepeerd per dienst: *AI-aanbieders*, *Agents* (Claude Code, Codex, Gemini), *Diensten* (GitHub, Notion …), *Op je Mac* (Agenda, Mail …), *Eigen bronnen*. Per account: identiteit, status, rechten en acties, gebruik, fouten, opnieuw verbinden/wijzigen/verwijderen. "+ Account toevoegen" ook voor een tweede account van dezelfde dienst. | samenvoeging van Koppelingen + Accounts (Agents) + sleutels in Brein + Portfolio |
| Assistent | Scherm meelezen, scherm bij elke vraag, meedenken, kleine dingen meteen doen | ongewijzigd |
| Agents | Agents koppelen (hooks, met diff-voorbeeld), standaarden voor nieuwe sessies (isolatie, kloonmap, editor, terminal, auto-archief) | Agents, zonder accounts en abonnementen |
| **Gebruik** | Limieten per account (Claude 5 uur/week, Codex), tokens en kosten per agent, model en project (alleen zoals gemeld), gebruik van Nooks eigen brein (nieuw: tokens per aanbieder, lokaal = €0) | `UsageView` + Abonnementen |
| **Privacy & beveiliging** | Machtigingen, wat je Mac verlaat, **logboek** (nieuw: weergave van de `audit`-tabel met filter en bewaartermijn), schermtekst vergeten, uitgesloten apps | Privacy + nieuw logboek |
| Stem & geluid | ongewijzigd | |

### 4.4 Eén hoofdlocatie per functie

| Functie | Hoofdlocatie | Ook bereikbaar (contextueel) |
|---|---|---|
| Vraag stellen / chatten | Venster › Chat | Notch › Nook, ⌥⌘spatie, stem |
| Chatgeschiedenis | Venster › Chat (zijbalk) | Notch › recente Nooks |
| Actie goedkeuren (chatplan) | in het gesprek (PlanReview) | — |
| Agent-goedkeuring of -vraag | Venster › Agents › sessie | Notch-kaart, Notch › Agents |
| Agentsessie volgen en bijsturen | Venster › Agents | Notch › Agents (compact) |
| Nieuwe agentsessie | `NewSessionSheet` | knop in Notch › Agents en Venster › Agents |
| Accounts (alle soorten) | Instellingen › Accounts & koppelingen | Deeplink vanuit een fout ("Opnieuw verbinden") |
| Koppeling toevoegen | Instellingen › Accounts & koppelingen | Deeplink vanuit de chat ("Koppel Slack") |
| Brein en model kiezen | Instellingen › Brein | Modelchip in de chat (wisselen tussen geïnstalleerde lokale modellen) |
| Gebruik en limieten | Instellingen › Gebruik | Per sessie in de Agents-inspector |
| Logboek van acties | Instellingen › Privacy & beveiliging | — |
| Terminal / browser | Venster › Werkruimte | Vanuit een chat of agentsessie "Open in werkruimte" |
| Muziek | Notch (rust-status + tab) | Chat via `media_control` |
| Bestand als bijlage | invoerveld (chat) | Slepen op de notch |

---

## 5. De rol van de notch

**Wel in de notch** (snel, contextueel, alles binnen 1–2 klikken af te handelen):
- **Status in rust:** het Nook-figuur, stipjes voor actieve agents, de muziek-equalizer, een amber badge als iets op je wacht.
- **Meldingen die een beslissing vragen:** goedkeuringen en vragen van agents, voorstellen van meedenken, "klaar"-meldingen met een korte samenvatting.
- **Snel vragen:** typen of spreken, het antwoord direct zien, doorgaan in hetzelfde gesprek of "Open in venster".
- **Vandaag:** wat er nu toe doet.
- **Agents compact:** zien wat loopt, goedkeuren, kort antwoorden, stoppen, openen.
- **Muziek.**

**Niet meer in de notch:**
- accounts toevoegen, hernoemen, inloggen of als standaard zetten;
- koppelingen instellen of hun status beheren;
- modus, rechten en model per beurt van een agentsessie;
- worktrees en git;
- uitgebreide gebruiksstatistieken.

Deze onderdelen worden **vervangen door een knop die naar de juiste plek springt**, zodat geen stroom verloren gaat.

**Samenwerking zonder dubbele implementatie:**
- Notch en venster tonen dezelfde `ChatController`, `AgentSessionStore` en `ApprovalCenter`; alleen de weergave verschilt (compact of volledig).
- Een goedkeuring die in het venster is afgehandeld, verdwijnt meteen uit de notch, en omgekeerd.
- Staat het venster met precies die sessie voorop, dan toont de notch geen dubbele kaart. Dat bestaat al voor werkruimte-sessies (`AppModel+Workspace.swift:96`) en wordt uitgebreid naar alle sessies.

Gevolg: `AgentsTab.swift` gaat van ~2.250 naar naar schatting ~600 regels.

---

## 6. Lokale AI als standaard en intelligente bronselectie

### 6.1 Eén model-architectuur

Nu staan `useLocal` + `localModel` (MLX) en `provider` (cloud + Ollama/LM Studio) los van elkaar. Voorstel:

```
BrainSelection { runtime: .mlx | .ollama | .lmstudio | .external(AIProvider) ; model: String ; accountID: String? }

ModelClient (protocol)                    // één ronde: berichten + tools in → tekst + tool calls uit
  ├─ MLXClient            (EmbeddedModel.swift, ingekort tot runtime/geheugen/download)
  ├─ LocalServerClient    (Ollama /api/chat met num_ctx; LM Studio /v1) — ook model-lijst en "draait niet"-status
  ├─ AnthropicClient      (bestaande streaming/caching uit BrainService.swift)
  ├─ OpenAICompatibleClient (AIProvider.swift)
  └─ ClaudeCodeClient     (ClaudeCodeBrain.swift, dichtgezet — §11)

ToolLoop (één implementatie, getest met een MockClient)
```

- **`ModelProfile` per model**: contextvenster, maximale uitvoer, native tool calling (ja/nee), maximaal aantal tools per ronde, of compacte beschrijvingen nodig zijn. De bestaande aanpassingen voor kleine modellen hangen dan aan het **profiel**, niet aan `useLocal`. Daarmee krijgen Ollama en LM Studio meteen dezelfde behandeling als MLX.
- **Standaard voor nieuwe installaties: lokaal.** De eerste-keer-flow kiest op basis van het geheugen (`EmbeddedModel.fits`) een MLX-model:
  - 8–16 GB: een klein instructiemodel (~3–4B, 4-bit, ~2 GB);
  - 24 GB+: een ~7–8B-model (4-bit, ~4,5 GB).
  - De modellijst in `EmbeddedModel.swift:28-35` wordt herzien op **betrouwbare tool calling**, niet alleen op grootte. Een kleine evaluatieset (§12, fase 2) bepaalt welke modellen erin komen.
  - Draait Ollama of LM Studio al, dan biedt Nook die modellen in dezelfde lijst aan.
- **Bestaande gebruikers houden hun keuze.** Migratie: is er een API-sleutel en `provider` ≠ leeg, dan wordt dat `.external(provider)`. Is `useLocal` aan, dan wordt het `.mlx`. Er wordt niets ongevraagd omgezet.
- **Altijd zichtbaar welk model actief is:** een modelchip bij het invoerveld met "Lokaal · Qwen 7B" of "Extern · Claude", met een kleur voor lokaal of extern. Klikken = wisselen tussen geïnstalleerde lokale modellen; extern kies je bewust in Instellingen.
- **Nooit ongemerkt naar de cloud.** Er is nu al geen runtime-fallback; dat wordt een expliciete regel met een test.
  - Is het lokale model niet beschikbaar (niet gedownload, Ollama draait niet, te weinig geheugen), dan toont de chat een duidelijke foutstaat met een herstelknop ("Start Ollama", "Download model", "Kies ander model"). Er gaat geen stille wissel naar een andere aanbieder.
  - **Web** wordt een aparte bron met een eigen schakelaar. Ook de native `web_search` van Claude en `WebFetch` in Claude Code volgen die schakelaar en de bronkeuze. Dat lost de bug op waarbij "zonder web" werd genegeerd (`BrainService.swift:102`).
- **Geheugen:**
  - Het bestaande gedrag blijft: ontladen bij geheugendruk en na 90 s rust, en één vraag tegelijk.
  - Nieuw is een **contextbudget**: systeemprompt, tools, context en prefetch worden vóór de aanroep geteld en ingekort tot het venster van het modelprofiel. Nu kan de KV-cache van 4.096 tokens stil overlopen.
  - Bij Ollama wordt `num_ctx` gezet op het budget.

### 6.2 De agentloop (één `ToolLoop` voor alle modellen)

| Stap | Wat er gebeurt | Bestaand onderdeel |
|---|---|---|
| 1. Begrijpen | Snelle opdrachten eerst (`LocalIntent`); anders de vraag + geschiedenis + bronkeuze uit de vraag | `LocalIntent`, `SourceScope.parse` |
| 2. Tools ontdekken | **Gefaseerd** (zie 6.3) | `SourceRouter.relevant`, `ConnectorHub.contextLines` |
| 3. Accounts en rechten | Alleen bronnen en accounts die de chat toestaat; `ToolRegistry` filtert, en controleert opnieuw bij uitvoeren | `scopedTools`, `PlanRunner` |
| 4. Bronnen kiezen | Het model kiest uit een korte catalogus; de router geeft een startset | `Prefetch` (blijft als versneller) |
| 5. Tools aanroepen | Lees-tools direct via het grootboek (time-out, cache, dedupe) | `RetrievalLedger` |
| 6. Aanvullen | Het model mag een volgende ronde doen met nieuwe tools; maximaal *N* rondes per profiel | — |
| 7. Acties voorbereiden | Actie-tools worden **nooit** in de loop uitgevoerd → `PlannedAction` → `ActionGate.normalized/problems`. Bij een fout krijgt het model één reparatieronde ("veld `start` is geen ISO-datum"). | `ActionGate` |
| 8. Toestemming en uitvoering | PlanReview → `PlanRunner`; nieuw: statussen *voorgesteld → goedgekeurd → uitgevoerd → gecontroleerd* | `PlanRunner`, §11 |
| 9. Rapporteren | Antwoord met `[n]`-verwijzingen (`Citations.sanitize`), bronchips, uitkomst per stap; "mogelijk onvolledig" als een bron faalde | bestaat |

**Robuustheid voor kleine modellen**, centraal in de `ToolLoop` en dus voor alle runtimes:
- Een JSON-tool-call in de tekst wordt gered. De bestaande `EmbeddedModel.extractToolCalls` verhuist naar de loop.
- Argumenten worden vóór uitvoering tegen het schema gecontroleerd; bij een fout volgt één reparatieronde met de foutmelding.
- Een onbekende toolnaam krijgt een vriendelijke fout plus de geldige namen.
- Een herhaalde identieke aanroep geeft het eerdere resultaat terug (dat doet het grootboek al).
- Een harde limiet op rondes en aanroepen, en daarna een eerlijk antwoord met wat er wél gevonden is. Dat gebeurt nu al als `digest(fetched)` in `AppModel.swift:678`.
- Alle tool-beschrijvingen in één taal (Engels) voor het model; de UI blijft vertaald.

### 6.3 Tool discovery: niet standaard 58 tools

Drie lagen, gekozen omdat ze werken zonder dat het model alles hoeft te lezen.

1. **Catalogus in de prompt.** Het model krijgt één regel per toegestane bron, bijvoorbeeld "GitHub (2 accounts): PR's, issues zoeken en wijzigen". Die regel wordt afgeleid uit de nieuwe `ConnectorDescriptor`. Dat kost ~15 tokens per bron in plaats van ~100 per tool.
2. **Startset.**
   - Altijd mee: de tools van de bronnen die de router relevant vindt (de bestaande `SourceRouter`) plus een paar kerntools (agenda, open punten).
   - Voor lokale modellen: maximaal ~8 tools; voor cloudmodellen meer.
3. **Meta-tool `use_source(source)`.** Het model kan in een volgende ronde de tools van een andere bron laden. Daarmee kan het zelf besluiten om ook Slack of Notion te raadplegen, zonder dat al die tools vooraf meegaan.

Zo kan Nook elke toegestane bron gebruiken, maar raadpleegt het alleen wat relevant is. De regex-router blijft als goedkope eerste gok en wordt geen tweede bronkeuzesysteem. Het voorbeeld uit de opdracht ("laatste ontwikkelingen rond mijn project … plan een overleg") verloopt dan zo:
- router: mail, bestanden, agenda, GitHub/Slack via `use_source`;
- lees-rondes;
- het model vergelijkt en noemt tegenstrijdigheden (de synthese-instructie vraagt daar expliciet om, met verwijzingen per bewering);
- `check_availability`;
- het plan `create_event` met de deelnemers ter goedkeuring.

**Eerlijke beperking:** een 3B-model blijft zwak in meerstaps-redeneren over 5+ bronnen. De loop vangt fouten op, maar de kwaliteit van de synthese hangt af van het model. Daarom:
- komt er een evaluatieset met vaste vragen en verwachte bronnen en tools, die meet welke modellen goed genoeg zijn;
- toont de UI bij complexe opdrachten op een klein model een korte hint: "Dit gaat beter met een groter model".

---

## 7. Accounts en integraties

### 7.1 Eén accountlaag, zonder alles om te bouwen

De opslag blijft waar hij is (Keychain + UserDefaults), maar er komt één register:

```swift
struct ServiceAccount: Codable, Identifiable {
    let id: String              // "github", "github.werk", "claude-code.persoonlijk", "anthropic"
    let service: String         // descriptor-id: "github", "claude-code", "anthropic", "notion" …
    var label: String           // "Werk"
    var identity: String?       // "@michan-werk", "michan@…" — opgehaald, niet ingevuld
    var isDefault: Bool
    var credentialKeys: [String] // Keychain-accounts, géén geheimen
}
```

- **Migratie zonder kopiëren.**
  - Bestaande sleutels worden het account `"<dienst>"` (standaard), met dezelfde Keychain-naam (`connector.github.token` blijft bestaan).
  - Een tweede account krijgt `connector.github.werk.token`.
  - `AgentProfiles` wordt niet vervangen: elk `AgentProfile` verschijnt als `ServiceAccount` (adapter), want dat systeem werkt al goed met meerdere accounts.
  - AI-sleutels (`<provider>-api-key`) worden ook accounts, zodat meerdere accounts per AI-aanbieder mogelijk zijn.
- **Connectors per account.** `CloudConnectors.makeAll()` maakt één instantie per account, bijvoorbeeld `GitHubConnector(account:)`. De rest van de app (hub, tools, router) ziet gewoon twee bronnen van hetzelfde type.
- **Status per account:** `ConnectorStatus` krijgt een gestructureerde foutsoort (`.auth`, `.network`, `.rateLimited`, `.config`) in plaats van alleen tekst. Zo kan de UI "Opnieuw verbinden" tonen bij `.auth` en "Opnieuw proberen" bij `.network`.
- **Eén schrijfpad naar de Keychain** (`SecretStore`), dat ook het trimmen en valideren regelt. Dat vervangt 4 varianten. Daarbij:
  - `kSecUseDataProtectionKeychain` en `kSecAttrAccessibleAfterFirstUnlock` (met migratie van bestaande items);
  - atomisch bijwerken met `SecItemUpdate` in plaats van verwijderen + toevoegen.

### 7.2 Uitbreidbare connectorarchitectuur

Nu raakt een nieuwe dienst 4–6 bestanden. Voorstel: elke connector beschrijft zichzelf.

```swift
struct ConnectorDescriptor {
    let id, title, symbol, iconDomain: String
    let auth: AuthKind            // .none, .permission(.calendar), .apiKey(fields), .oauthDevice(...), .oauthPKCE(...), .mcp(...)
    let aliases: [String]          // "github", "gh", "pull request" — nu in SourceScope.swift:92
    let intents: [String]          // trefwoorden voor de router — nu in SourceScope.swift:290
    let capabilities: String       // één regel voor de catalogus — nu in SourceCapabilities.phrases
    let multiAccount: Bool
    let limitations: [String]      // getoond in Instellingen
}
```

- `SourceCatalog`, `exactTools`, `aliases` en `SourceCapabilities` worden **afgeleid** uit de geregistreerde descriptors. Tools krijgen hun bron via de connector die ze levert, niet via een tabel.
- Een nieuwe dienst = **één bestand** + één regel registratie + vertalingen.
- **Protocollen per situatie:**
  - **Officiële REST API met sleutel** voor wat nu werkt.
  - **OAuth device flow** voor GitHub: een `clientID` instellen; de code is er al.
  - **OAuth met PKCE en loopback** voor Google en Microsoft. Nodig voor Gmail, Drive, Agenda, Teams en OneDrive; vraagt een app-registratie per aanbieder. Dit is een open vraag (V4).
  - **MCP-client** (stdio en HTTP) als generiek connectortype. Elke MCP-server levert dan zijn tools via dezelfde `ToolRegistry`, met dezelfde scheiding tussen lezen en acties en dezelfde goedkeuring. Dit geeft in één keer toegang tot Slack, Linear, Jira, Notion en andere diensten zonder eigen code per dienst. Voorstel: fase 4b, na de accountlaag.

### 7.3 Drie toestanden, duidelijk gescheiden

| Toestand | Betekenis | Waar zichtbaar |
|---|---|---|
| **Gekoppeld** | Er is een account met geldige gegevens | Instellingen › Accounts (status) |
| **Beschikbaar in deze chat** | Het account valt binnen de bron- en accountkeuze van deze Nook | Bron- en accountkiezer bij het invoerveld; catalogus voor het model |
| **Gebruikt / uitgevoerd** | Er is echt mee gelezen, of een actie is uitgevoerd en gecontroleerd | Bronchips boven het antwoord; stapstatus in het plan; logboek |

### 7.4 Accountkeuze bij het starten van een chat

- **De bronkiezer wordt de bron- en accountkiezer.** Het is dezelfde component (`ChatSourcesView` / `ScopeMenu`) en hetzelfde opslagveld (`NookChat.Conversation.scope`, uitgebreid met `accounts`). Er komt geen tweede systeem.
  - Standaard staat alles aan ("Automatisch").
  - Bij een dienst met meerdere accounts kun je per chat bijvoorbeeld alleen "GitHub · Werk" toestaan.
- **"Nieuwe chat" met een keuze:** ⌘N start een automatische chat; ⌥⌘N of het pijltje opent een klein menu met bewaarde profielen, zoals "Werk" (zakelijke accounts) of "Privé". De profielen bestaan uit bronkeuze + accounts en staan in Instellingen.
- **Het model kiest zelf als dat veilig kan.** Bij meerdere accounts krijgt elke tool van die dienst een optionele parameter `account`.
  - **Lezen:** zonder `account` worden alle toegestane accounts doorzocht en per account gelabeld.
  - **Acties:** `ActionGate` eist een account zodra er meer dan één mogelijk is. Kan het model het niet afleiden ("PR in `bedrijf/app`" hoort bij het werkaccount omdat dat account toegang heeft), dan stelt Nook een **verduidelijkingsvraag** met de accounts als knoppen.
  - In het plan staat bij elke stap altijd het gekozen account.

---

## 8. Chats, agents, taken en werkruimte

### 8.1 Begrippen (één betekenis per woord)

| Begrip | Betekenis | Type in de code |
|---|---|---|
| **Chat (Nook)** | Een gesprek met Nooks eigen brein | `NookChat.Conversation` (blijft) |
| **Agent** | Een programma dat zelfstandig werkt: Claude Code, Codex, Gemini CLI … | `AgentKind` (uitgebreid; vervangt de losse namenlijsten) |
| **Agentsessie** | Eén gesprek van een agent, waar het ook draait (terminal, Claude-app, Nook) | **`AgentSessionRecord`**, nieuw en samengevoegd (zie 8.2) |
| **Beurt** | Eén opdracht + uitvoering binnen een sessie | `TurnUsage` / beurt in `WorkspaceRun` |
| **Tool-aanroep** | Eén stap van een agent of van Nook | `RunEvent(.tool)` / `RetrievalStep` |
| **Taak** | Iets wat gedaan moet worden, los van wie het doet: open punt, herinnering, agentopdracht | bestaande `loops`-tabel, uitgebreid met optionele koppeling aan een sessie of chat |

### 8.2 Eén sessieregister

`AgentSessionStore` (nieuw, in `Services/`) voegt de vier bronnen samen tot één lijst:

- **sleutel:** `(agent, account-home, conversationID)`; voor alleen-proces `pid`;
- **bronnen:**
  - hooks (`AgentHub`) → live status;
  - processcan (`LocalAgentScanner`) → "draait, niet gekoppeld";
  - transcripten (`AgentHistory`) → afgerond;
  - `WorkspaceManager` → door Nook bestuurd.
- **regels:**
  - Een sessie staat er één keer in, met de "rijkste" bron leidend.
  - Een live sessie verschijnt niet ook onder Eerder.
  - Twee processen in dezelfde map blijven twee rijen.
  - Nooks eigen kindprocessen worden herkend via `NOOK_RUN_ID` / `NOOK_INTERNAL` in de omgeving, niet via `ppid`. Dat lost het risico op dat Nooks eigen Codex-run als vreemd proces wordt "beëindigd".

Zowel de notch als het venster lezen alleen uit dit register.

### 8.3 Wat de gebruiker kan, en waar

| Wat | Waar | Technisch |
|---|---|---|
| Alle agents en hun status zien | Venster › Agents, Notch › Agents | register |
| Actieve en afgeronde sessies terugvinden | Venster › Agents (zoeken, filters) | register + `AgentHistory` |
| Gesprek openen | Venster › Agents › detail | `RunDetailView`; voor terminalsessies de transcriptweergave (nu alleen Claude, uitbreiden naar Codex) |
| Starten / stoppen / hervatten | beide | `WorkspaceManager.start/stop/send` (bestaat) |
| Extra instructies geven | beide | `send` / `continueInNook` (bestaat); de "twee schrijvers"-situatie wordt voorkomen: een idle terminalsessie wordt standaard **geforkt**, niet hervat |
| Voortgang, resultaten, fouten | Venster › Agents | tijdlijn, inspector |
| Toestemmingen | `ApprovalCenter` (notch + detail) | samenvoeging van D3 |
| Account en model per sessie | `NewSessionSheet` + menu per beurt in het detail | bestaat, wordt verplaatst |
| Gebruik en kosten | Inspector per sessie; Instellingen › Gebruik totaal | `UsageReport` + `QuotaService`; Codex-limieten per account (`CODEX_HOME` per profiel) |

**Kleine bugs die meegaan:**
- `attentionCount` heeft een fout in de operatorvolgorde (`WorkspaceManager.swift:142`);
- het weekoverzicht mist door Nook gedraaide sessies;
- de accountdetectie breekt op paden met spaties (`LocalAgentScanner.swift:84`);
- er wordt een gesprek gekozen zonder op het account te letten (`AppModel+Agents.swift:25`).

### 8.4 Agentplanning met het lokale model

"Agentplanning" (Nook bedenkt welke stappen of welke agent) gaat via dezelfde `ToolLoop`, dus standaard lokaal. De coding-agents zelf (Claude Code, Codex) gebruiken hun eigen account en model. Dat blijft zo en is zichtbaar per sessie.

---

## 9. Browser, terminal en aanvullende functies

### 9.1 Terminal

Er is nu geen terminal, alleen `.command`-bestanden die Terminal.app opent (`TerminalLauncher.swift`).

**Voorstel:** één `TerminalSession`-service op basis van een pty, met **SwiftTerm** (MIT, gangbare Swift-terminalview) voor de weergave. Dit is een nieuwe afhankelijkheid en daarom een open vraag (V3).
- **Gebruik:** Venster › Werkruimte › Terminals, en "Open terminal hier" vanuit een agentsessie (in de map of worktree van de sessie).
- **Vervangt** de Terminal.app-route voor inloggen en uitloggen van agents (`claude /login`, `codex login`). Die stromen draaien dan in een ingebouwde terminal, zodat Nook ziet wanneer het klaar is in plaats van 15 minuten te pollen. Terminal.app blijft als keuze in Instellingen › Agents.
- **Veiligheid:**
  - Nooks brein krijgt **geen** vrije shell-tool.
  - Een commando dat het brein voorstelt, is een actie (`run_command`) met verplichte goedkeuring. Het commando staat volledig in beeld (niet afgekapt op 160 tekens), met een `CommandRisk`-beoordeling die op tokens werkt in plaats van op substrings (§11).
  - Het commando draait in een zichtbare terminalsessie, zodat je uitvoer en fouten ziet.
  - Agents houden hun eigen sandbox en rechten (Codex-sandbox, Claude-permissiemodus).

### 9.2 Browser

Er is nu geen browser; Nook leest tabbladen via AppleScript en haalt pagina's op met `WebTools`.

**Voorstel:** één `BrowserSession` met `WKWebView` (Apple, geen afhankelijkheid), in Venster › Werkruimte › Browser.
- **Lezen:** de AI kan de open pagina lezen (`read_browser_page`, via de DOM in plaats van OCR). `read_webpage` blijft voor ophalen op de achtergrond, maar gebruikt dezelfde URL-controle (§11).
- **Handelen:** in de eerste versie alleen *navigeren* en *zoeken* (een actie met goedkeuring) en de pagina aan de chat geven. Formulieren invullen of klikken namens de gebruiker komt pas later, na een apart ontwerp per actie. Dat is het grootste risico op prompt-injectie.
- De AppleScript-koppeling met Safari/Chrome blijft: dat is je eigen browser, en die is waardevol.
- **Eén implementatie:** chat, agents en de werkruimte gebruiken dezelfde `BrowserSession`- en `TerminalSession`-services. Er komen geen aparte varianten per scherm.

### 9.3 Muziek en overige hulpmiddelen

| Functie | Beslissing | Waarom |
|---|---|---|
| Muziek | Blijft: rust-status in de notch + tab alleen als er iets speelt. Bediening via één service (D13). | Veel gebruikt en past bij de notch; geen reden voor een plek in het venster |
| Shelf | Wordt "bijlagen": slepen op de notch of het invoerveld | Dezelfde stroom, één plek minder, en lost het verlies bij tabwissel op |
| Weekoverzicht | In Vandaag + menubalk | |
| Meedenken | Blijft, maar via de chatpijplijn (D10) en dus ook voor lokale modellen beschikbaar | Nu uit voor lokaal (`AppModel.swift:1443`) |
| Stem / wekwoord | Blijft; taal volgt de app-taal in plaats van hard nl-NL | |
| Crypto-portfolio | Blijft als koppeling, beheerd zoals de andere (§7) | Nu een eigen UI en eigen logica |
| Demo-scènes | Alleen in debug-builds | Nep-bevestigingen horen niet in productie |

---

## 10. Technische herstructurering en migratieplan

### 10.1 Nieuwe en gewijzigde verantwoordelijkheden

```
App/
  AppModel.swift            → alleen samenstelling + levenscyclus (~400 r.); geen domeinlogica meer
  Chat/ChatController.swift      ← AppModel.swift:419-1055 (+ notch-kaartpad, meedenken via dezelfde pijplijn)
  Chat/PlanExecutor.swift        ← AppModel.swift:784-908, 1234-1321
  Agents/AgentCoordinator.swift  ← AppModel.swift:1592-1805 + AppModel+Agents.swift + AppModel+Workspace.swift (goedkeuringen)
  Agents/AccountsController.swift← AppModel.swift:1807-2002 (zonder dode code)
  Proactive/ThinkAlongController.swift ← AppModel.swift:1436-1590
  Cards/CardFactory.swift        ← AppModel.swift:2154-2290 (strings via tr())
  Onboarding/OnboardingFlow.swift (nieuw, vervangt welkomstkaart + checklist)
  Today.swift                    ← todayItems + TodayItem (uit Demo)
Brain/
  ModelClient.swift, ToolLoop.swift, ModelProfile.swift (nieuw, klein)
  Clients/ (Anthropic, OpenAICompatible, LocalServer, MLX, ClaudeCode) ← bestaande bestanden, loop eruit
  ToolRegistry.swift (nieuw) — tools per bron en account, discovery, use_source
  SourceScope.swift — catalogus afgeleid uit descriptors
Core/
  SecretStore.swift (uit AppSettings.swift)
  VersionedFile.swift (nieuw) — versie + backup bij leesfout, voor nooks.json, runs.json, agentProfiles
  NookStore.swift — user_version + migraties, bewaartermijn audit
  Log.swift — os.Logger per categorie (vervangt NSLog/print)
Services/
  Accounts/AccountRegistry.swift (nieuw) + adapters voor AgentProfiles en AI-sleutels
  Agents/AgentSessionStore.swift (nieuw) — één register
  Agents/ApprovalCenter.swift (nieuw) — één goedkeuringsmodel
  Usage/QuotaService.swift (nieuw) — samengevoegd uit AgentsTab/UsageView/CodexUsage
  Workspace/TerminalSession.swift, BrowserSession.swift (nieuw, fase 7)
NotchUI/
  Chat/NookChatView.swift ← uit NookTab.swift (gedeeld door notch en venster)
  Pills/ → NookTab (samengevoegd), AgentsTab (ingekort), MusicTab
  Window/MainWindow* ← uitgebreid WorkspaceView
  Components/ — StatusDot, Chip, SectionHeader, ApprovalView, RelativeTime (samengevoegd)
  Theme/NookTheme.swift — + typeschaal, + WS-palet erin opgenomen
```

**Bewust niet gedaan:** geen nieuw state-framework, geen coordinator-patroon over alles heen, geen hernoeming van mappen die logisch zijn. De controllers zijn gewone `@MainActor ObservableObject`s die views direct observeren. Dat lost meteen het probleem op dat alles opnieuw tekent door het doorsturen van `objectWillChange` (`AppModel.swift:121-135`).

### 10.2 Bestand voor bestand

| Bestand | Actie | Toelichting |
|---|---|---|
| `App/AppModel.swift` | **Splitsen** | Zie 10.1. Dode code weg: `send(_:to:)`, `canContinue`, `startSession*`, `resume`, `copyResumeCommand`, `lastAutoRun`, `streamedLines`, `lastSources`, `runBrain`/`showStreaming`/`recentExchanges` |
| `App/AppModel+Agents.swift`, `+Workspace.swift` | **Samenvoegen** in `AgentCoordinator` / `AccountsController` | |
| `App/NookChat.swift` | **Aanpassen** | `VersionedFile`; `scope` uitbreiden met `accounts`; zoeken/hernoemen/archiveren; maximum van 40 wordt archiveren |
| `App/SettingsView.swift` (1.109 r.) | **Splitsen** per sectie (`Settings/*.swift`) + nieuwe indeling §4.3 | |
| `App/SettingsAccounts.swift`, `ConnectorSettingsSection.swift`, `PortfolioSettings.swift` | **Samenvoegen** tot `Settings/AccountsSettings.swift` | Eén lijst; portfolio gebruikt `ConnectorField` |
| `App/SmartSuggestions.swift` | **Behouden** | Eén bron voor suggesties |
| `Brain/BrainService.swift` | **Aanpassen** | Wordt orchestratie: prompt bouwen + `ToolLoop` aanroepen; Anthropic-loop → `AnthropicClient` |
| `Brain/AIProvider.swift` | **Aanpassen** | Enum blijft (compatibel met UserDefaults); loop → `OpenAICompatibleClient`; Ollama → `LocalServerClient` |
| `Brain/EmbeddedModel.swift` | **Aanpassen** | Alleen runtime, download, geheugen; modellijst herzien |
| `Brain/ClaudeCodeBrain.swift` | **Aanpassen** | Dichtzetten (§11); loop → gedeeld |
| `Brain/NookTools.swift` | **Aanpassen** | Beschrijvingen in het Engels; `media_control` via `NowPlayingService`; `read_clipboard` naar de klembord-connector; contacten met usage-beschrijving |
| `Brain/SourceScope.swift` | **Aanpassen** | Tabellen afgeleid uit descriptors; scope + accounts |
| `Brain/ActionGate.swift` | **Uitbreiden** | Statussen `approved`, `verified`; account verplicht bij ambiguïteit; reparatieronde |
| `Brain/Retrieval.swift` | **Aanpassen** | `@ref` alleen van vertrouwde tools; bestandsverwijzingen nooit uitvoerbaar openen |
| `Brain/CommandRisk.swift` | **Herschrijven** (zelfde API) | Tokeniseren, normaliseren, uitgebreide lijsten; tests erbij |
| `Brain/WebTools.swift` | **Aanpassen** | DNS-resolutie + redirect-controle op privé-adressen; "bekende URL" niet uit onbetrouwbare tekst |
| `Brain/LocalIntent.swift`, `FollowUps`, `ChartRescue`, `MailStats`, `NookDates` | **Behouden** | |
| `Core/AppSettings.swift` | **Aanpassen** | `BrainSelection` met migratie; Keychain → `SecretStore`; dubbele taalinstelling weg |
| `Core/NookStore.swift` | **Aanpassen** | Migraties, WAL, bewaartermijn audit, leesfunctie voor het logboek |
| `Core/I18n*.swift` | **Aanpassen** | ~76 hard-gecodeerde strings uit `AppModel` erin; ontbrekende Duitse sleutels (265) aanvullen of terugval nl → en; ongebruikte sleutels weg |
| `Demo/DemoContent.swift` | **Opsplitsen** | Modeltypes eruit; scènes `#if DEBUG` |
| `Services/Connectors/Connector.swift` | **Uitbreiden** | `ConnectorDescriptor`, gestructureerde foutsoort |
| `Services/Connectors/CloudConnectors.swift` (2.153 r.) | **Splitsen** per dienst (`GitHub.swift`, `Notion.swift` …) en per account instantiëren | |
| `Services/Connectors/ConnectorHub.swift` | **Aanpassen** | Eén refresh-pad (ook vanuit Instellingen via de hub) |
| `Services/AgentHub.swift`, `LocalAgentScanner.swift`, `AgentHistory.swift` | **Aanpassen** | Leveren aan `AgentSessionStore`; bugs uit §8.3 |
| `Services/AgentProfiles.swift` | **Behouden** + adapter naar `AccountRegistry` | |
| `Services/CodexUsage.swift` | **Aanpassen** | Per `CODEX_HOME` |
| `Services/Workspace/*` | **Behouden** | Goed gescheiden en getest; `WorkspaceManager` levert aan het register |
| `Services/TerminalLauncher.swift` | **Aanpassen** | Unieke tijdelijke bestanden + opruimen; later grotendeels vervangen door `TerminalSession` |
| `Services/SystemControl.swift` | **Aanpassen** | AppleScript op één seriële queue (NSAppleScript is niet thread-safe) |
| `Services/ScreenReader.swift` | **Aanpassen** | Uitsluitlijst uitbreiden + instelbaar |
| `NotchUI/Pills/NookTab.swift` | **Samenvoegen** | Home + Chat → één tab; `NookChatView` naar `Chat/` |
| `NotchUI/Pills/AgentsTab.swift` | **Inkorten** (~2.250 → ~600) | Accounts-modus, compose en uitgebreide statistieken eruit |
| `NotchUI/Pills/AgentRunPanel.swift` | **Inkorten** | Compacte samenvatting + `ApprovalView` + antwoordveld |
| `NotchUI/Pills/ConnectTab.swift`, `ShelfTab.swift` | **Verwijderen** | Functies verhuisd (D6, §9.3) |
| `NotchUI/Workspace/*` | **Uitbreiden** tot hoofdvenster | Chat- en Werkruimte-secties erbij; `UsageView` naar Instellingen |
| `NotchUI/Chat/MarkdownView.swift` | **Aanpassen** | `openURL`-handler: alleen https/mailto, met bevestiging bij afwijkende hosts |
| `NotchUI/Theme/NookTheme.swift`, `Workspace/WorkspaceComponents.swift` | **Samenvoegen** | Eén palet + typeschaal + vaste hoekradii |
| `project.yml` | **Aanpassen** | `NSContactsUsageDescription`; hardened runtime aan (met `allow-jit` als MLX het nodig heeft, eerst testen); nieuwe testbestanden in het testdoel; eventueel SwiftTerm |
| `README.md`, `docs/*.md` | **Bijwerken** per fase | |

### 10.3 Datacompatibiliteit (niets van de gebruiker gaat verloren)

| Data | Nu | Migratie |
|---|---|---|
| `nooks.json` | geen versie | Lezen zonder versie = v1. Bij een leesfout: bestand hernoemen naar `nooks.corrupt-<datum>.json` en de gebruiker waarschuwen, **nooit overschrijven**. Nieuwe velden optioneel. |
| `workspace/runs.json` | geen versie, enums streng | Idem; onbekende enum-waarden → `.unknown` in plaats van een decodeerfout |
| UserDefaults `agentProfiles` | JSON | Idem + adapter naar `AccountRegistry` |
| UserDefaults `provider`, `useLocal`, `localModel` | los | Eenmalig omzetten naar `BrainSelection`; oude sleutels blijven gelezen voor terugdraaien |
| Keychain | vaste namen | Bestaande namen blijven het standaardaccount; attributen bijwerken naar data-protection keychain met behoud van waarde |
| `nook.sqlite` | `CREATE IF NOT EXISTS` | `PRAGMA user_version` + genummerde migraties; bestaande tabellen = versie 1 |

---

## 11. De belangrijkste beveiligingsrisico's

Gesorteerd op ernst. Alle punten zijn in de code nagelopen; de punten met ✔ heb ik zelf bevestigd.

| # | Ernst | Risico | Waar | Oplossing |
|---|---|---|---|---|
| S1 ✔ | **Hoog** | Het Claude Code-brein staat `WebFetch`/`WebSearch` toe zonder URL-controle, en `Read`/`Glob`/`Grep` zijn niet uitgezet. De werkmap is de Nook-map met `nook.sqlite` (mailteksten in het audit-log) en de chatgeschiedenis. Schermtekst (onbetrouwbaar) kan zo een "lees dan haal op"-lek sturen. Gaat `--setting-sources` mis, dan probeert Nook het opnieuw met de instellingen en hooks van de gebruiker. | `ClaudeCodeBrain.swift:114-127`, `:162` | Lege tijdelijke werkmap; `--disallowedTools` aangevuld met Read/Glob/Grep/WebFetch; `WebSearch` alleen als de bron Web is toegestaan; geen herhaling zonder `--setting-sources` (dan een duidelijke fout "update Claude Code") |
| S2 ✔ | Hoog (functioneel) | `search_contacts` vraagt toegang tot Contacten zonder `NSContactsUsageDescription`, waardoor macOS de app beëindigt | `project.yml`, `NookTools.swift:404` | Beschrijving toevoegen |
| S3 | Hoog | Geen hardened runtime en geen sandbox: een ander proces van dezelfde gebruiker kan via DYLD code in Nook laden en zo de machtigingen voor scherm, microfoon, Automation en Agenda erven | `project.yml` | Hardened runtime aan (sandbox is niet haalbaar vanwege AppleScript en procesbeheer); testen met MLX (`allow-jit` indien nodig) |
| S4 ✔ | Middel | Een bronverwijzing `file:` kan een `.app` of `.command` in de thuismap openen = uitvoeren. Een `@ref`-regel in een mail of webpagina wordt als verwijzing herkend. | `AppModel.swift:922-926`, `Retrieval.swift:188` | `@ref` alleen van tools van Nook zelf; bestanden alleen "Toon in Finder" of openen bij niet-uitvoerbare typen |
| S5 ✔ | Middel | Markdown-links in modeluitvoer zijn met elk schema klikbaar | `MarkdownView.swift:164-166` | `openURL`-handler: alleen https en mailto, met de doelhost zichtbaar |
| S6 ✔ | Middel | Met "kleine dingen meteen doen" draait `open_app` enzovoort zonder vraag, ook als er onbetrouwbare tekst (scherm, mail, web) in de prompt zat | `AppModel.swift:1283-1289`, `:729` | Automatisch uitvoeren alleen als de vraag zelf de actie noemt én er geen onbetrouwbare inhoud de doorslag gaf; anders een plan met Uitvoeren |
| S7 | Middel | `WebTools`: de privé-adrescontrole kijkt alleen naar de letterlijke host (geen DNS, geen redirect-controle); URL's uit schermtekst gelden als "bekend" | `WebTools.swift:197-209`, `AppModel.swift:607` | Host resolven en privé-bereiken blokkeren, ook na een redirect. (Bij nader inzien blijven URL's uit schermtekst "bekend": de controle is een exacte match, dus er kan geen data aan worden toegevoegd. Dat is geen lekroute.) |
| S8 | Middel | De goedkeuringskaart kapt een commando af op 160 tekens | `AppModel.swift:1616`, `AppModel+Workspace.swift:117` | Volledig commando (scrollbaar) in `ApprovalView` |
| S9 | Middel | `CommandRisk` werkt met substrings: `rm -r -f /`, `curl x\|sh`, `bash -c`, `python -c`, `osascript`, `security dump-keychain` glippen erdoor; `printenv` en `cat ~/.ssh/...` gelden als veilig | `CommandRisk.swift` | Tokeniseren, gevoelige paden herkennen, uitgebreide gevaarlijke programma's; nieuwe tests |
| S10 | Middel | `read_file`/`search_files` mogen alles in de thuismap behalve verborgen mappen en `~/Library` | `LocalConnectors.swift:678` | Blokkeerlijst voor gevoelige extensies (`.pem`, `.key`, `.p12`, wachtwoordexports) + instelbare uitgesloten mappen |
| S11 | Middel | `read_clipboard` negeert de klembord-schakelaar | `NookTools.swift:376`, `SourceScope.swift:158` | Tool onder de klembord-connector |
| S12 | Laag-middel | De uitsluitlijst voor schermlezen is kort; `read_app("terminal")` leest de volledige scrollback | `ScreenReader.swift:33`, `:193` | Uitbreiden (Dashlane, LastPass, KeePassXC, Enpass, Proton Pass) en instelbaar; terminal alleen zichtbare tekst |
| S13 | Laag | Het audit-log bewaart mailteksten onbeperkt en wordt nergens getoond | `NookStore.swift:149` | Bewaartermijn (standaard 90 dagen) + weergave in Privacy |
| S14 | Laag | `statusline-previous.json` wordt via `/bin/sh -c` uitgevoerd; NSAppleScript draait op parallelle queues; `.command`-bestanden met berichten blijven in `$TMPDIR` | `HookScript.swift:215`, `SystemControl.swift:13`, `TerminalLauncher.swift` | Alleen eigen geschreven inhoud uitvoeren (hash-controle); seriële queue; opruimen |
| S15 | Laag | Keychain: oude bestandssleutelhanger, niet-atomisch schrijven | `AppSettings.swift:6-36` | `SecretStore` (§7.1) |

**Actiestatussen** (gevraagd in punt 12 van de opdracht): `ActionStepState` wordt *voorgesteld → goedgekeurd → bezig → uitgevoerd → gecontroleerd* (of *mislukt / overgeslagen / al gedaan*).
- **Gecontroleerd** betekent dat Nook na uitvoering terugleest dat het resultaat bestaat. Voorbeelden: het afspraak-id staat in de agenda, de GitHub-API geeft de nieuwe reactie terug.
- Kan dat niet, dan blijft de status **uitgevoerd** en zegt Nook dat ook zo.
- Elke overgang komt in het logboek.

**Prompt-injectie:**
- De bestaande structurele verdediging blijft de kern: acties worden nooit in de modelloop uitgevoerd, `UntrustedText.neutralize` omlijnt onbetrouwbare tekst, en `PlanRunner` controleert opnieuw.
- S1, S4–S7 dichten de gaten waar onbetrouwbare tekst tóch iets in gang kon zetten.
- Nieuw is dat elk plan met onbetrouwbare herkomst een label krijgt ("gebaseerd op een mail van …").

---

## 12. Implementatieplanning

Elke fase = één of enkele pull requests naar `main`, elk met groene CI (`xcodebuild build` + `NookTests`). Volgorde op basis van afhankelijkheden: de structurele fundamenten eerst, zichtbare UI daarna.

```
F0 Veiligheid & bugs ─┐
F1 Fundament ─────────┼─► F2 Brein ─► F3 Intelligente chat ─┐
                      └─► F4 Accounts & koppelingen ────────┼─► F5 Navigatie & UI ─► F6 Agents ─► F7 Werkruimte ─► F8 Afronden
```

| Fase | Inhoud | Hangt af van | Testcriteria |
|---|---|---|---|
| **F0 Veiligheid en bugs** (klein, direct) | S1, S2, S4, S5, S6, S8, S11; `attentionCount`; Shelf-verlies; `.command`-opruiming; `NSAppleScript` serieel | — | Nieuwe unit-tests: `CommandRisk` (bypass-gevallen), `Retrieval` (`@ref` uit onbetrouwbare bron genegeerd), open-URL-filter; build groen |
| **F1 Fundament** | `VersionedFile` + backup bij leesfout; SQLite-migraties; `os.Logger`; modeltypes uit `Demo/`; dode code weg; `AppModel` splitsen in controllers (zonder gedragswijziging); demo-scènes `#if DEBUG` | — | Decode-tests met oude en kapotte bestanden (geen dataverlies); alle bestaande tests groen; handmatige rooktest op een Mac: chat, plan, agentgoedkeuring, werkruimte |
| **F2 Brein** | `ModelClient` + één `ToolLoop`; `ModelProfile`; `BrainSelection` + migratie; lokaal als standaard voor nieuwe installaties; modelchip; contextbudget; `num_ctx`; web als bron (bugfix); Claude Code dichtgezet; brein-gebruik meten | F1 | `ToolLoop`-tests met `MockClient`: tool-call in tekst, schemafout → reparatie, limiet, geen actie-uitvoering in de loop; test "geen fallback": lokaal faalt → fout, nooit een andere client; evaluatieset voor modelkeuze |
| **F3 Intelligente chat** | Descriptor-catalogus; startset + `use_source`; synthese-instructie (tegenstrijdigheden, verwijzing per bewering); kaarten en meedenken via de chatpijplijn; actiestatussen + controle | F2 (F4 voor accounts in tools) | Router- en discovery-tests (vraag → verwachte bronnen); evaluatieset van ~30 vragen nl/en: juiste bronnen geraadpleegd, geen onnodige; tests voor actiestatussen |
| **F4 Accounts en koppelingen** | `AccountRegistry` + adapters; `SecretStore`; connectors per account (GitHub eerst); gestructureerde fouten; scope met accounts; verduidelijkingsvraag; descriptors | F1 | Migratietest (bestaande sleutel = standaardaccount, ongewijzigd leesbaar); `ActionGate` eist een account bij twee GitHub-accounts; scope sluit een account uit, dus geen tool-aanroep daarmee |
| **F4b** (optioneel) | MCP-client als connectortype; OAuth PKCE voor Google/Microsoft | F4 | Lezen via een test-MCP-server; acties alleen na goedkeuring |
| **F5 Navigatie en UI** | Hoofdvenster (Chat/Agents/Werkruimte); notch afslanken (Nook-tab samengevoegd, Koppelingen/Shelf weg); Instellingen herindeling; `ApprovalCenter` + `ApprovalView`; eerste-keer-flow; designtokens en componenten; strings naar I18n | F1, F2 (modelchip), F4 (accountpagina) | Elke functie uit §4.4 is te bereiken op de hoofdlocatie; geen functie verloren (checklist uit §3); de 10 gebruikersstromen hieronder handmatig doorlopen |
| **F6 Agents** | `AgentSessionStore` (één register, dedupe); detail met beurt-instellingen in het venster; fork in plaats van een tweede schrijver; Codex-limieten per account; `QuotaService`; Instellingen › Gebruik | F5 | Tests voor het register: dezelfde sessie uit hook + transcript + run = één rij; twee processen in één map = twee rijen; Nooks eigen kindproces wordt niet als vreemd herkend |
| **F7 Werkruimte** | `TerminalSession` (SwiftTerm), inloggen via de ingebouwde terminal; `BrowserSession` (WKWebView) lezen + navigeren; "Open in werkruimte" vanuit chat en agents | F5, F6 | Terminal: uitvoer/fout/exitcode zichtbaar; `run_command` alleen na goedkeuring; browser: `read_browser_page` levert tekst, navigeren vraagt goedkeuring |
| **F8 Afronden** | README, `docs/ASSISTANT.md`, `docs/AGENTS.md`, `CONTRIBUTING.md` bijwerken; Duitse vertalingen; opruimen | alles | Documentatie klopt met de app; CI groen |

**De tien gebruikersstromen** (testscript voor F5–F7):

| Stroom | Verloop na het herontwerp |
|---|---|
| Eerste keer openen | Notch → "Welkom" → venster met 3 stappen: (1) lokaal model kiezen en downloaden (geheugen-advies) of extern kiezen; (2) machtigingen; (3) koppelingen (optioneel, overslaan kan) → klaar, met een eerste suggestie |
| Lokaal model instellen | Instellingen › Brein › Lokaal → lijst (MLX + gevonden Ollama/LM Studio-modellen) → Download/Kies → Test → de modelchip toont het model |
| Externe dienst koppelen | Instellingen › Accounts & koppelingen → "+ Account" → dienst → sleutel of inloggen → status "Verbonden als @…" |
| Tweede account van dezelfde dienst | Zelfde stroom, label "Werk" → beide in de lijst, één als standaard |
| Chat met automatische bronnen | ⌘N → vraag → bronchips laten zien wat geraadpleegd is → antwoord met [n] |
| Actie in een externe app | Vraag → plan met account per stap → Uitvoeren → stap "gecontroleerd" → logboek |
| Meerdere agents beheren | Venster › Agents → *Wacht op jou* bovenaan → goedkeuren → instructie sturen → stoppen/hervatten |
| Browser of terminal openen | Venster › Werkruimte, of "Open terminal hier" bij een sessie |
| Eerdere chat of taak terugvinden | Venster › Chat zoeken, of Agents › Eerder met filter |
| Foutieve koppeling herstellen | Fout in de chat ("GitHub · Werk: token verlopen") → knop "Opnieuw verbinden" → direct naar dat account in Instellingen |

---

## Open vragen voor jou (beïnvloeden het plan)

| # | Vraag | Mijn voorstel |
|---|---|---|
| V1 | Instellingen als eigen venster (⌘,) of als vierde onderdeel in de zijbalk van het hoofdvenster? | Eigen venster (macOS-conventie) |
| V2 | Welke Mac (chip, geheugen) is je doelhardware? Dat bepaalt het standaard lokale model. | Automatisch kiezen op geheugen |
| V3 | Mag SwiftTerm als nieuwe afhankelijkheid erbij voor de ingebouwde terminal? | Ja; het alternatief is zelf een terminalview bouwen, en dat is veel werk |
| V4 | Wil je Google- en Microsoft-koppelingen (vraagt een eigen app-registratie per aanbieder) of eerst MCP als generieke route? | Eerst MCP (F4b); Google/Microsoft daarna |
| V5 | Akkoord dat de Koppelingen-tab en de Shelf-tab uit de notch verdwijnen (functies verhuizen)? | Ja |
| V6 | Mag F0 (veiligheid en bugs) al meteen, los van je akkoord op de rest? Het zijn kleine wijzigingen zonder gevolgen voor de structuur. | Ja |
