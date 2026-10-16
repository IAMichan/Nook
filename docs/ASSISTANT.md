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
          Zelf zoeken   Research: zoektermen uit de vraag (en bij een vervolgvraag uit de vraag ervoor), elke relevante
                        bron doorzoeken (zonder genoemde bron: overal), treffers rangschikken en de beste volledig lezen
                                                                                                    (Brain/Research.swift)
       3. Tools         AppModel.scopedTools: alleen tools van toegestane bronnen en accounts; lees-tools via RetrievalLedger
                        ChatIntent (nl/en/de) herkent wat de vraag wil; die tools staan altijd vooraan   (Brain/ChatIntent.swift)
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

### Zelf zoeken en lezen

Een klein lokaal model zoekt slecht: het roept één tool aan met de hele vraag als zoekterm, leest alleen de titels van de acht nieuwste notities of het begin van een mail. Daarom doet Nook dat werk zelf, op de Mac, vóór het model antwoordt, voor elk brein en elke bron hetzelfde (`Research`, aangeroepen vanuit `prepareRun`):

1. **Zoektermen.** De woorden die de vraag dragen: "Wat staat er in mijn notitie over de verbouwing?" wordt `verbouwing`. Vulwoorden, vraagwoorden, namen van bronnen, datums en tijden vallen weg (nl/en/de); namen gaan voor, een zin tussen aanhalingstekens blijft heel. Een korte vervolgvraag ("en het budget?") houdt de woorden van de vraag ervoor (`budget verbouwing`) en zoekt in dezelfde bronnen.
2. **Zoeken.** Elke relevante bron wordt met die woorden doorzocht: Notities (titel én inhoud van álle notities), Mail, Bestanden (Spotlight), Notion, GitHub, het web en elke MCP-server of eigen bron met een zoekveld. Noemt de vraag geen bron ("wat weet ik over project Apollo?"), dan zoekt Nook overal waar hij kan zoeken; het web alleen als de vraag erom vraagt, Contacten alleen bij een naam. Zonder zoekwoorden ("welke notities heb ik?") of bij een vraag naar het nieuwste of ongelezen kijkt Nook in het overzicht van de bron.
3. **Lezen.** De treffers van alle bronnen worden gerangschikt (een woord in de titel telt zwaarder dan in de tekst, hoofdletters en accenten tellen niet) en de beste worden volledig geopend met de lees-tool van die bron: `read_note`, `read_mail`, `read_file`, `notion_read_page`, `github_issue_details`, `read_webpage`. Een treffer die al helemaal zichtbaar was, wordt niet nog eens geopend.

Het model krijgt dit bovenaan de context ("Looked up for this question"): eerst waar Nook zocht en met welke woorden, dan de volledig gelezen documenten, dan de zoekresultaten. Wordt de context te lang, dan wijkt het algemene overzicht, niet de documenten. Het model krijgt daarnaast altijd de lees-tool bij elke zoek-tool, en de opdracht om zelf door te zoeken met andere woorden (een synoniem, een naam, één woord) voordat het zegt dat het iets niet vond. Lokale modellen met een groter venster (16k+) kunnen net als cloudmodellen met `use_source` elke toegestane bron bereiken.

**Alleen wat over je vraag gaat.** Uit zoekresultaten haalt Nook de notities, mails, chats en bestanden die niets met de zoekwoorden te maken hebben, voordat het model ze ziet; vindt een bron alleen zulke resultaten, dan staat er "geen resultaten over …". Van een lang document en van het venster van een app (`read_app`) houdt Nook de passages over de vraag (met de titel en de bronnenlijst). Het model mag alleen antwoorden uit een bron die over de vraag gaat, en zegt anders dat het niets vond.

**Apps zonder eigen koppeling.** Berichten (iMessage en sms), WhatsApp, Bear en Things bewaren alles in een database op je Mac. Nook leest die alleen-lezen met `sqlite3` (`Services/Connectors/AppConnectors.swift`, de opmaak in `Brain/AppData.swift`), zodat hij de hele geschiedenis doorzoekt en niet alleen wat op het scherm staat: `search_messages` / `read_messages`, `search_whatsapp` / `read_whatsapp`, `search_bear` / `read_bear`, `search_things`. Een gesprek lezen laat de berichten rond de treffers zien plus de nieuwste, in tijdsvolgorde. Namen komen uit Contacten (als Nook daar al bij mag), zodat "wat appte Jan?" Jans chats vindt. Berichten en WhatsApp vragen **Volledige schijftoegang** voor Nook (Systeeminstellingen › Privacy en beveiliging); tot die er is, laat Nook ze buiten het zoeken en staat de reden bij Instellingen › Accounts & koppelingen.

**MCP-servers.** Elke lees-tool met een zoekveld wordt meegezocht. Heeft dezelfde server een tool die één item opent (get/read/fetch/show… met één veld), dan opent Nook daarmee de beste treffers, uit een JSON-antwoord of uit regels met een id.

**Andere apps.** Noem je een app ("wat staat er in Slack?"), dan leest Nook haar vensters via de toegankelijkheidslaag en houdt hij de passages over je vraag. Documenten van apps (Obsidian, Word, Pages, pdf) vindt en leest hij via Spotlight.

Notities en Mail zoeken op elk woord apart en zetten de berichten met de meeste treffers bovenaan, met een id om ze daarna volledig te lezen. Spotlight vraagt alle woorden tegelijk; vindt dat niets, dan zoekt Nook per woord en houdt hij de bestanden die de meeste woorden raken.

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
| Mail (app Mail) | Op je Mac | ✅ ongelezen in de context; `search_mail` ➕ ook in Verzonden, ➕ met link naar het bericht, ➕ op elk woord apart; ➕ `read_mail` (hele bericht) | ⚠️ `compose_mail`: concept in de chat; jij klikt Versturen (via Mail) |
| Browser | Op je Mac en in Nook | ✅ open tabbladen met links (context); ➕ `read_nook_browser` (ingebouwde browser) | ➕ `open_in_nook_browser` |
| Terminal | In Nook | – | ➕ `run_command`: hele commando in het plan, gevaarlijke commando's geweigerd, draait zichtbaar in de werkruimte |
| MCP-servers | stdio of HTTP | ➕ lees-tools van de server | ➕ actie-tools van de server, altijd na jouw OK |
| Berichten (iMessage, sms) | Op je Mac, Volledige schijftoegang | ➕ `search_messages` (hele geschiedenis, op tekst en contactnaam), `read_messages` (gesprek rond de treffers) | – |
| WhatsApp | Op je Mac, Volledige schijftoegang | ➕ `search_whatsapp`, `read_whatsapp` | – |
| Bear | Op je Mac | ➕ `search_bear`, `read_bear` | – |
| Things | Op je Mac | ➕ `search_things` (open en afgerond, met project) | – |
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
* intentie uit de vraag (nl/en/de): welke actie, vraag of opdracht, kleine praat, datumoverzicht voor lokale modellen (`ChatIntentTests`);
* het grootboek: bron per tool, gelukt/leeg/mislukt, time-out, geen dubbele aanroep, cache, nummering;
* bronverwijzingen: alleen echte nummers blijven staan, alleen veilige links;
* prompt-injectie: tekst van derden kan de omlijning niet sluiten;
* gedeelde tool-loop met een nep-model (tool-aanroep in tekst, schemafout → reparatie, limieten, acties nooit in de loop), brein-keuze, sessieregister, vertaaldekking (nl/en/de), terminal-commando's;
* acties: validatie, normaliseren, velden voor de controle, vaste sleutel, gedeeltelijk mislukken en verder gaan zonder herhaling, uitgezette stappen, dubbel uitvoeren alleen na **Toch**, controle op het moment van uitvoeren.

Alle tools in deze tests zijn nep (mocks). De koppelingen zelf (Mail via AppleScript, EventKit, GitHub, Notion) zijn **niet** automatisch getest tegen echte accounts. Daarvoor is een Mac met toegang en sleutels nodig.

## Bekende beperkingen

* De bronkeuze uit de vraag werkt met trefwoorden en is geen taalbegrip. Een ongewone formulering wordt soms niet herkend; de bronkiezer werkt altijd.
* De interne teksten voor het brein en de beschrijvingen van wat een koppeling kan zijn in het Nederlands. De knoppen en meldingen zijn vertaald (nl/en/de).
* `search_mail` zoekt op onderwerp en afzender of ontvanger, niet in de hele tekst: in de inhoud zoeken via AppleScript is te traag. De beste treffers leest Nook wel volledig (`read_mail`).
* AppleScript-opdrachten (Notities, Mail) draaien na elkaar. Zoeken in duizenden notities kan daardoor een paar seconden duren; na 20 seconden stopt Nook en meldt hij dat bij de bron.
* Berichten, WhatsApp, Bear en Things worden gelezen uit hun eigen database. Verandert een app die opbouw in een update, dan kan zoeken daar mislukken tot Nook is bijgewerkt; de fout staat dan bij de bron. Discord, Teams en Telegram hebben geen leesbare lokale database: daarvoor blijft een MCP-server de route.
* De zoektermen komen uit een lijst met vulwoorden, niet uit taalbegrip. Een ongewoon woord als zoekterm maakt het zoeken hooguit breder; het model kan zelf opnieuw zoeken met andere woorden.
* Een klein lokaal model blijft zwak in meerstaps-redeneren over vijf of meer bronnen. Vraag je duidelijk om één actie en stelt het model die niet voor, dan vraagt Nook het nog één keer met alleen die tool. Zie [CHAT-PLAN.md](CHAT-PLAN.md) voor de volgende stappen. De loop vangt fouten op, maar de kwaliteit van de synthese hangt af van het model. `RoutingEvalTests` meet of de juiste bronnen gekozen worden, niet de kwaliteit van het antwoord.
* Google (Gmail, Drive) en Microsoft (Teams, OneDrive) vragen een eigen app-registratie met OAuth (PKCE) en zijn niet ingebouwd; MCP is daarvoor de route.
* Voorgestelde acties worden na een herstart niet opnieuw aangeboden (bewust). De uitkomst per stap blijft als tekst in het gesprek.
