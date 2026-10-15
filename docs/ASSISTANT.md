# De Nook-chat: bronnen, bewijs en acties

> **English summary:** how the Nook chat decides which sources to use, how it records what it actually searched, how answers cite their sources, and how proposed actions are validated, approved and executed. Includes the capability matrix per integration and the known limitations.

Dit document beschrijft hoe een vraag in de chat (tab **Chat**, ⌥⌘ spatie) door Nook loopt, wat elke koppeling echt kan en wat (nog) niet.

## De weg van een vraag

```
NookChatView (invoer, bronkiezer, modelchip, bijlage)   — gedeeld door de notch en het hoofdvenster
  └─ AppModel.handleUserText → ask → answer             (App/AppModel+Chat.swift)
       1. Bronkeuze     SourceScope.parse(vraag)  +  bronkiezer van deze Nook   (Brain/SourceScope.swift)
       2. Voorbereiding AppModel.prepareRun: één voorbereiding voor chat, kaarten, scherm kijken en Meedenken
          Context       SourceRouter.relevant → ConnectorHub.contextLines(scope:full:)
                        relevante bronnen volledig, de rest als één regel met de tool om erin te kijken
       3. Tools         AppModel.scopedTools: alleen tools van toegestane bronnen en accounts; lees-tools via RetrievalLedger
                        Gefaseerd: een startset (kleiner voor lokale modellen) plus één regel per overige bron;
                        het brein ontgrendelt een bron met `use_source` (BrainService.run)
       4. Brein         BrainService.run met BrainSelection (ingebouwd MLX, Ollama, LM Studio of extern), één ToolRunner
                        voor alle modellen; lees-tools draaien meteen
       5. Opzoeken      RetrievalLedger: per bron de zoekterm, gelukt / niets / mislukt, time-out 25 s,
                        geen dubbele aanroepen, korte cache (90 s), genummerde bronverwijzingen   (Brain/Retrieval.swift)
       6. Antwoord      Citations.sanitize: alleen [n] die bij een echt opgehaalde bron hoort blijft staan
       7. Voorstel      actie-tools worden nooit uitgevoerd; ActionGate controleert de invoer   (Brain/ActionGate.swift)
       8. Goedkeuring   PlanReview: elke stap met alle velden, aan/uit, tekst aanpassen, Uitvoeren / Annuleren
                        (stappen met een account tonen dat account; bij twee mogelijke accounts vraagt Nook welk)
       9. Uitvoeren     PlanRunner: opnieuw controleren, dubbel-uitvoeren voorkomen, stoppen bij een fout,
                        verder gaan zonder herhaling; staten: voorgesteld → goedgekeurd → uitgevoerd → gecontroleerd
                                                                                                    (AppModel+Plans.swift)
      10. Bewaren       nooks.json (gesprek, bronnen, verwijzingen, uitkomst per stap); nook.sqlite (audit,
                        executed_actions)
```

### Kaarten en Meedenken gebruiken dezelfde route

De kaarten in de notch (scherm bekijken ⌥⌘N, Meedenken) lopen via dezelfde `prepareRun` als de chat: dezelfde bronkeuze, dezelfde tools met het grootboek, dezelfde controle van acties en dezelfde bronverwijzingen. Alleen de presentatie verschilt (een kaart in plaats van een bericht). Bij die kaarten laat Nook de lookups vooraf weg, omdat de vraag over het scherm zelf gaat. Meedenken werkt ook met een lokaal brein.

### Welk brein

`BrainSelection` is de ene waarde die zegt waar Nook denkt: ingebouwd (MLX), Ollama, LM Studio of extern. Nieuwe installaties zijn lokaal; wie al een externe AI had gekozen, houdt die. Het modelprofiel (`ModelProfile`) bepaalt contextgrootte, aantal tools en rondes, voor alle runtimes gelijk. Nook schakelt nooit zelf naar een andere aanbieder: is het gekozen model niet beschikbaar, dan zie je een duidelijke fout met wat je kunt doen.

### Accounts

Een dienst kan meerdere accounts hebben (`AccountRegistry`, bijvoorbeeld "GitHub · Werk"). Tools van zo'n dienst hebben een optioneel veld `account`. Lezen zonder account doorzoekt alle toegestane accounts en labelt de uitkomst; een actie vraagt een account zodra er meer dan één mogelijk is. De bronkiezer bepaalt per chat welke accounts mogen. Een mislukte koppeling toont **Opnieuw verbinden** (ongeldige gegevens) of **Opnieuw proberen** (netwerk), gebaseerd op `ConnectorErrorKind`.

### Terminal en browser

`run_command` (bron *Terminal*) is altijd een actie: het hele commando staat in het plan, `CommandRisk` werkt op tokens, een gevaarlijk commando wordt door `ActionGate` geweigerd, en het draait in een zichtbare terminal van de werkruimte. `read_nook_browser` leest de open pagina in de ingebouwde browser; `open_in_nook_browser` opent alleen https en vraagt toestemming.

### Bronkeuze

* **Bronkiezer** naast het invoerveld, per Nook bewaard: *Alle bronnen* (automatisch), *Alleen deze bronnen*, of *Nooit gebruiken* (scherm, web, klembord).
* **In de vraag zelf**, in het Nederlands, Engels of Duits: "alleen mijn agenda en mail", "only use my calendar and email", "zoek in Slack en GitHub, maar niet op mijn scherm", "ohne Bildschirm", "gebruik alle bronnen".
* Wat de vraag zegt gaat voor, behalve dat een bron die in de bronkiezer uit staat niet terugkomt.
* Uitgesloten bronnen gaan niet als context mee en hun tools zijn voor het brein onzichtbaar. Ook bij het uitvoeren wordt het nog eens gecontroleerd.

### Verbonden, gekozen, doorzocht, gevonden

Boven elk antwoord staat per bron een chip:

| Chip | Betekenis |
|---|---|
| filter-icoon | De bronkeuze voor dit antwoord (alleen als die beperkt was) |
| oog | Context die zonder tool meeging (scherm, bestand) |
| ✓ Mail · 3 | Doorzocht, met 3 verwijzingen |
| ○ GitHub · niets gevonden | Doorzocht, niets gevonden |
| ✗ Notion | Doorzoeken mislukte; de reden staat in de tooltip én onder het antwoord |

Met ⓘ zie je precies welke context meeging en elke zoekactie met zoekterm en uitkomst. Faalt een bron, dan zegt Nook onder het antwoord dat het mogelijk onvolledig is. Het brein krijgt de fout ook en moet het zelf melden.

### Bronverwijzingen

Tools geven verwijzingen mee (`ReferenceParser.line`, een regel `@ref titel | link | detail`). Het grootboek nummert ze over alle tools van één antwoord en geeft het brein alleen de genummerde lijst. Het antwoord verwijst met `[1]`. Nummers die niet bij een opgehaalde bron horen, worden verwijderd. Klikbaar zijn alleen `https:`, `file:` (binnen je eigen map) en `message:` (opent de mail in Mail).

### Acties

* Elke actie is een voorstel. `ActionGate.problems` controleert verplichte velden, typen, toegestane waarden, datums (ISO 8601), einde na begin, alleen https-links, `eigenaar/naam` voor repositories (zonder `..`) en mailadressen. Onbekende velden gaan eruit.
* De gebruiker ziet per stap alle velden volledig, kan stappen uitzetten en tekstvelden aanpassen (opnieuw gecontroleerd). Uitvoeren kan pas als alle aangezette stappen kloppen.
* Bij het uitvoeren controleert `PlanRunner` alles opnieuw: de tool bestaat nog, de bron mag nog en de invoer klopt. Een tool-aanroep van het model alleen is nooit genoeg.
* **Geen dubbel werk:** elke gelukte actie krijgt een vaste sleutel (tool + invoer) in `executed_actions`. Precies dezelfde actie binnen 12 uur wordt niet herhaald, maar gemeld als *al uitgevoerd*. Met **Toch nog een keer** kan het wel. Muziek, volume en apps of links openen zijn hiervan uitgezonderd.
* **Gedeeltelijk mislukt:** het plan stopt bij de eerste fout (latere stappen kunnen ervan afhangen). Per stap zie je gelukt, mislukt, niet uitgevoerd of overgeslagen. **Verder met de rest** voert alleen de stappen uit die nog niet lukten. Nook zegt nooit dat iets gelukt is zonder bevestiging van de dienst.
* Goedkeuren, annuleren en elke uitvoering staan in `nook.sqlite`, tabel `audit`.
* De uitkomst per stap (met id's, zoals het id van een gemaakte afspraak) staat in de geschiedenis voor het brein, zodat "verplaats die afspraak" en "rond dat punt af" werken.

### Veiligheid

* Mail, berichten, webpagina's, documenten en schermtekst gaan omlijnd als `<tool_data>` / `<screen_content>` naar het brein. `UntrustedText.neutralize` maakt tags in die tekst onschadelijk, zodat een mail de omlijning niet kan sluiten of zich als systeem- of gebruikersbericht kan voordoen.
* Het systeemprompt verbiedt instructies uit zulke data te volgen of een uitgesloten bron te gebruiken. De echte bescherming zit in de uitvoerlaag: zonder jouw klik gebeurt er niets buiten Nook.
* Sleutels blijven in de Keychain en gaan nooit naar het brein.

## Wat elke koppeling kan

Legenda: ✅ werkt (code nagelopen, logica getest) · ➕ nieuw in deze versie · ⚠️ werkt met beperkingen · ❌ niet ingebouwd.

| Bron | Soort | Lezen | Schrijven (na jouw OK) |
|---|---|---|---|
| Apple Agenda (alle accounts in macOS) | Op je Mac | ✅ context 7 dagen, `list_events` (➕ met id en agenda), `check_availability` over alle agenda's | ✅ `create_event` (➕ kies agenda, geeft id), ➕ `update_event`. ❌ deelnemers uitnodigen: EventKit staat dat niet toe |
| Andere agenda's (ICS) | Adres | ✅ via `check_availability` | ❌ alleen lezen |
| Herinneringen | Op je Mac | ✅ open herinneringen in de context | ✅ `create_reminder` (➕ geeft id), ➕ `complete_reminder` |
| Open punten van Nook | Nook | ✅ `list_open_loops` (➕ met id) | ✅ `add_open_loop`, ➕ `complete_open_loop` |
| Mail (app Mail) | Op je Mac | ✅ ongelezen in de context; `search_mail` ➕ ook in Verzonden, ➕ met link naar het bericht | ⚠️ `compose_mail`: concept in de chat; jij klikt Versturen (via Mail) |
| Browser | Op je Mac en in Nook | ✅ open tabbladen met links (context); ➕ `read_nook_browser` (ingebouwde browser) | ➕ `open_in_nook_browser` |
| Terminal | In Nook | – | ➕ `run_command`: hele commando in het plan, gevaarlijke commando's geweigerd, draait zichtbaar in de werkruimte |
| MCP-servers | stdio of HTTP | ➕ lees-tools van de server | ➕ actie-tools van de server, altijd na jouw OK |
| Bestanden (Spotlight) | Op je Mac | ✅ `search_files`, `read_file` (pdf, Word, rtf, tekst), ➕ met klikbare verwijzing | – |
| Klembord | Op je Mac | ✅ standaard uit | – |
| Scherm | Op je Mac | ✅ OCR van alle vensters, alleen met toestemming | – |
| GitHub | Inloggen (device flow, scope `repo read:user`) of token | ✅ je PR's, `github_pr_details`; ➕ `github_search` (issues en PR's), ➕ `github_issue_details` | ✅ review, reactie, samenvoegen, sluiten van PR's; ➕ `github_create_issue`, ➕ `github_comment_issue`, ➕ `github_update_issue` |
| Notion | API-sleutel (integratie) | ✅ `notion_search` (➕ met id), ➕ `notion_read_page` (tekst van een pagina) | ❌ |
| Stripe, Vercel, Cal.com, n8n, Resend | API-sleutel | ✅ overzichten | ❌ alleen lezen |
| Eigen bronnen | Eigen API of webhook | ✅ `read_source` (GET, alleen binnen de host) | ✅ `send_to_source`: Slack (webhook of API), Discord, Teams (webhook), Telegram, algemene webhook |
| Web | Internet | ✅ zoeken en pagina's lezen | – |

### Nog niet ingebouwd (en wat nu wel kan)

Dit staat ook in de app, bij **Instellingen › Accounts & koppelingen › Nog niet ingebouwd**. Een **MCP-server** (Instellingen › Accounts & koppelingen) is de generieke route voor Slack, Linear, Jira, Notion en andere diensten die er een hebben.

* **Slack lezen:** kan als eigen bron met een user-token (`search.messages`, scope `search:read`). Inloggen met Slack (OAuth) zit er nog niet in.
* **Microsoft Teams lezen, OneDrive, SharePoint:** dit vraagt Microsoft Graph met een eigen app-registratie en OAuth, en dat is niet gebouwd. Sturen naar Teams kan via een webhook. Bestanden die met Finder synchroniseren, vindt Nook via Spotlight.
* **Google Drive:** geen directe koppeling. Synchroniseer de map met Finder.
* **Gmail, Outlook en Exchange:** via de app Mail.
* **Linear, Jira, Todoist en GitLab:** lezen kan als eigen bron. Taken aanmaken in die diensten kan niet.
* **Discord lezen:** niet ingebouwd.

## Testen

`Tests/NookTests` (doel `NookTests` in `project.yml`, draait in CI met `xcodebuild test`) test de kern, die alleen Foundation gebruikt:

* bronkeuze uit de vraag (nl/en/de), samenvoegen met de bronkiezer, routering;
* het grootboek: bron per tool, gelukt/leeg/mislukt, time-out, geen dubbele aanroep, cache, nummering;
* bronverwijzingen: alleen echte nummers blijven staan, alleen veilige links;
* prompt-injectie: tekst van derden kan de omlijning niet sluiten;
* gedeelde tool-loop met een nep-model (tool-aanroep in tekst, schemafout → reparatie, limieten, acties nooit in de loop), brein-keuze, sessieregister, vertaaldekking (nl/en/de), terminal-commando's;
* acties: validatie, normaliseren, velden voor de controle, vaste sleutel, gedeeltelijk mislukken en verder gaan zonder herhaling, uitgezette stappen, dubbel uitvoeren alleen na **Toch**, controle op het moment van uitvoeren.

Alle tools in deze tests zijn nep (mocks). De koppelingen zelf (Mail via AppleScript, EventKit, GitHub, Notion) zijn **niet** automatisch getest tegen echte accounts. Daarvoor is een Mac met toegang en sleutels nodig.

## Bekende beperkingen

* De bronkeuze uit de vraag werkt met trefwoorden en is geen taalbegrip. Een ongewone formulering wordt soms niet herkend; de bronkiezer werkt altijd.
* De interne teksten voor het brein en de beschrijvingen van wat een koppeling kan zijn in het Nederlands. De knoppen en meldingen zijn vertaald (nl/en/de).
* `search_mail` zoekt op onderwerp en afzender of ontvanger, niet in de hele tekst: in de inhoud zoeken via AppleScript is te traag.
* Een klein lokaal model blijft zwak in meerstaps-redeneren over vijf of meer bronnen. De loop vangt fouten op, maar de kwaliteit van de synthese hangt af van het model. `RoutingEvalTests` meet of de juiste bronnen gekozen worden, niet de kwaliteit van het antwoord.
* Google (Gmail, Drive) en Microsoft (Teams, OneDrive) vragen een eigen app-registratie met OAuth (PKCE) en zijn niet ingebouwd; MCP is daarvoor de route.
* Voorgestelde acties worden na een herstart niet opnieuw aangeboden (bewust). De uitkomst per stap blijft als tekst in het gesprek.
