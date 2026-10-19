# Nook

[![Build](https://github.com/IAMichan/nook/actions/workflows/build.yml/badge.svg)](https://github.com/IAMichan/nook/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)

Je persoonlijke agent in de notch van je Mac.

> **English:** Nook is a personal AI assistant that lives in the MacBook notch. It keeps the text of every window on every display up to date locally, so any question is answered instantly with what you see, plus your calendar, reminders, mail, browser tabs, files and connected services (GitHub, Stripe, Vercel, Notion, Cal.com, n8n, Resend). It thinks with Claude, OpenAI, Google Gemini, Grok (xAI), Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Ollama, LM Studio or a built-in local model, shows what your coding agents are doing (Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, OpenCode, Amp, Hermes…), and controls music. Nothing runs without your explicit approval. The interface is in Dutch.

> **Status:** vroege versie (0.1). De app compileert, maar is nog weinig in de praktijk getest. Verwacht ruwe randjes.

> **Monorepo:** de macOS-app staat in [`apps/macos`](apps/macos). De iPhone-companion staat in [`apps/ios`](apps/ios). Voor Android, Windows en Linux staan de mappen klaar (zie [docs/MONOREPO.md](docs/MONOREPO.md)); die platformen zijn nog niet geschreven.

## Vereisten

- macOS 15 of nieuwer, het liefst een Mac met notch
- Xcode 26 of nieuwer (de MLX-pakketten van het ingebouwde model vragen dat) en een Apple Silicon-Mac
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Geen API-sleutel nodig: Nook denkt standaard op je eigen Mac (gratis, ingebouwd model). Een externe AI, zoals een [Anthropic API-sleutel](https://console.anthropic.com/), is een bewuste keuze.

## Bouwen en starten

```sh
brew install xcodegen
git clone https://github.com/IAMichan/nook.git
cd nook/apps/macos
xcodegen
open Nook.xcodeproj
```

Na elke `git pull` kan er een nieuw bestand bij zijn gekomen. Draai dan `./update.sh` (haalt op en draait `xcodegen`), anders klaagt Xcode over iets dat 'not in scope' is.

Wil je Nook niet in de notch? Kies in **Instellingen › Overzicht › Notch › Plek** voor **Zwevend op het scherm**. In rust zie je dan alleen Nook zelf, zonder balk. Sleep hem naar elke plek op elk aangesloten scherm (of aan de bovenrand van het open paneel); positie en scherm worden onthouden.

Heb je meer schermen? Zet in de notch-stand **Toon de notch op elk scherm** aan: elk aangesloten scherm krijgt een notch, en Nook opent op het scherm waar je muis is.

Druk op ⌘R. Nook heeft geen Dock-icoon: je ziet hem in de notch en als klein Nook-figuurtje in de menubalk.

**De eerste keer**
Nook laat de eerste keer een welkomstkaart zien. **Instellen** opent het hoofdvenster met een flow van drie stappen (elke stap kun je overslaan):
1. **Brein**: Nook stelt het lokale model voor dat bij het geheugen van jouw Mac past (of een model dat Ollama of LM Studio al draait) en installeert het met één klik. Liever een externe AI (Claude, OpenAI, Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Claude Code)? Kies die bij **Instellingen › Brein**. Nook schakelt nooit zelf naar de cloud.
2. **Wat Nook mag zien**: Scherm lezen en Agenda; Herinneringen en Microfoon vraagt Nook pas als je ze nodig hebt.
3. **Koppelingen** (optioneel): Mail, GitHub, Stripe, Notion, MCP-servers en meer, bij **Instellingen › Accounts & koppelingen**. Notion, Linear, Stripe, Vercel en Sentry koppel je met **Verbinden**: je logt in op de site van de dienst zelf (OAuth met PKCE via hun officiële MCP-server) en komt vanzelf terug in Nook; tokens staan in de Sleutelhanger en worden automatisch vernieuwd. Voor andere diensten plak je een sleutel met een stappenplan. Klik bij GitHub op **Koppel met GitHub** of plak een token; je kunt een tweede account van dezelfde dienst toevoegen ("GitHub · Werk").

Voor je agents: klik bij **Instellingen › Agents** op **Koppel…** naast Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp of Hermes. Elke andere agent kan zich melden met `nook_agent`, zie [docs/AGENTS.md](docs/AGENTS.md). Nook laat precies zien wat er in het instellingenbestand verandert, maakt eerst een backup en schrijft pas na jouw OK. Start de agent daarna opnieuw. Met **Claude-abonnement in de notch** zie je ook je 5-uurs- en weeklimiet (Pro/Max).

**Waar vind je wat**
- **De notch** is de plek waar je alles doet, zonder dat er een ander venster opengaat. Bovenin staan drie tabs (en Muziek als er iets speelt):
  - **Nook**: vragen stellen en chatten, Vandaag en je Nooks.
  - **Agents**: links je sessies, rechts de gekozen sessie. Elke rij laat zien of hij bezig is, op je wacht of klaar is, in welke map en met welk account. Met de **+** naast Sessies start je er een: "Wat zullen we bouwen in *map*?", één veld voor de opdracht, en daaronder kleine keuzes voor agent en account, Agent- of Plan-modus, rechten, huidige map of nieuwe worktree, en de branch waar hij vanaf begint. Return start de sessie, die meteen links in de lijst staat. Wijzigingen, commit, push en pull request openen ín de notch; met **Terug** (of Esc) ga je terug.
  - **Werkruimte**: terminals, de browser en worktrees. Je agents kunnen die ook zelf gebruiken: een dev-server starten in een zichtbare terminal, een pagina openen en controleren in Nooks browser en een pull request voorstellen dat jij goedkeurt. Een stipje op het terminal- of browsericoon naast een sessie betekent dat de agent daar iets opende. Zie [docs/WERKRUIMTE-AGENTS.md](docs/WERKRUIMTE-AGENTS.md).

  De notch opent op de tab die je het laatst gebruikte, behalve als een agent op je wacht: dan opent hij bij die agent. Een stipje naast een tab betekent: hier wacht iets op je (amber) of hier wordt gewerkt (wit).
- **Instellingen** (⌘, of het tandwiel in de notch) is de enige plek voor configuratie en koppelen: Algemeen, Accounts & koppelingen (bovenaan wat al gekoppeld is, daaronder **Koppel** bij elke dienst), Brein, Assistent, Geheugen, Agents (agents koppelen en hun accounts), Stem & geluid, Privacy & beveiliging en Gebruik.
- Liever een groot venster? Kies **Open in venster** in het menubalk-menu (⌥⌘W).

Wil je Nook eerst bekijken met voorbeeldgegevens? Zet **Voorbeelddata** aan bij Instellingen › Algemeen.

## Wat het doet

| Wat | Hoe |
|---|---|
| Praten tegen Nook | ⌥ spatie (of de microfoonknop). Herkenning op je Mac; daarna denkt het brein mee. |
| Chatten met Nook | ⌥⌘ spatie, waar je ook bent, het veld onderaan de tab Nook, of het hoofdvenster (⌥⌘W) met al je Nooks. Een echt gesprek: vervolgvragen worden begrepen, het antwoord verschijnt terwijl het geschreven wordt, met kopjes, lijstjes, tabellen en code. De vragen om mee te beginnen passen bij wat je nu doet (de app die voor staat, je volgende afspraak, een agent die wacht, het moment van de dag). |
| Nooks | Elk gesprek is een eigen Nook die aan één ding werkt. Begin er een met **Nieuwe Nook** (⌘N); de vorige werkt gewoon door. Links zie je al je Nooks met hun status: bezig, wacht op jou (een plan of mail) of klaar. Is er een klaar terwijl je iets anders doet, dan meldt hij zich in de notch. De geschiedenis blijft bewaard op je Mac (`nooks.json`), ook na een herstart; rechtsklik om een Nook weg te halen. |
| Bronnen en bewijs | Nook kiest per vraag zelf welke koppelingen ertoe doen en zoekt daar gericht. Boven het antwoord zie je per bron of hij doorzocht is, niets vond of faalde; onder het antwoord staan genummerde bronnen ([1], [2]) die je opent in Mail, de browser of Finder. Met de bronkiezer naast het invoerveld, of in je vraag ("alleen mijn agenda en mail", "niet mijn scherm"), bepaal je welke bronnen mogen. Zie [docs/ASSISTANT.md](docs/ASSISTANT.md). |
| Acties in stappen | Vraag iets dat meerdere dingen doet ("maak taken voor wat nog open staat en zet een mail klaar") en je krijgt één plan. Per stap zie je alle details; je kunt stappen uitzetten of tekst aanpassen. Mislukt er halverwege iets, dan zie je wat wel en niet lukte en ga je verder zonder dat iets dubbel gebeurt. |
| Grafieken | Vraag om een grafiek ("maak een grafiek van mijn afspraken per dag") en Nook tekent hem in de chat: staaf, lijn, vlak, taart of punten. De cijfers haalt hij uit je agenda, je diensten of het web. Schrijft het brein toch code, JSON, Mermaid of een tabel, dan maakt Nook daar zelf een echte grafiek van; lukt dat niet, dan vraagt hij het brein opnieuw om te tekenen. |
| Mail schrijven | "Schrijf een mail aan Lisa dat ik later ben": Nook zet een complete mail als concept in de chat. Pas hem aan en klik **Versturen** (via Mail), of **Open in Mail**. Er gaat nooit iets weg zonder jouw klik. |
| Al je schermen | Nook houdt de tekst van al je vensters op al je schermen bij (lokaal, OCR) en gebruikt die bij elke vraag. Daardoor is een antwoord meteen klaar. Boven een antwoord zie je waar Nook keek. |
| Koppelingen | Agenda, herinneringen, Mail (ongelezen en zoeken), browsertabs, recente bestanden en zoeken met Spotlight, klembord (standaard uit). Diensten met een eigen sleutel: GitHub (ook pull requests beoordelen, goedkeuren, samenvoegen en sluiten, altijd pas na jouw Uitvoeren), Vercel, Stripe, Notion, Cal.com, n8n en Resend. Alles bij **Instellingen › Accounts & koppelingen**, ook een tweede account van dezelfde dienst en MCP-servers (stdio of HTTP) als generieke route naar Slack, Linear, Jira en andere diensten. |
| Alle agenda's tegelijk | Vraag "ben ik 13 oktober beschikbaar?" en Nook kijkt in álle agenda's: Apple Agenda (met alle accounts die daar in zitten), agenda's via een ICS-adres (Google Agenda, Outlook, iCloud, werkagenda) onder **Andere agenda's**, en Cal.com. Je hoort in welke agenda's hij keek, en welke vrije momenten er zijn. |
| Eigen bronnen | Bijna elke app of dienst met een web-API of webhook koppel je onder **Eigen bronnen** (https, sleutel in de Keychain). Nook herkent aan het adres welke dienst het is (Slack, Discord, Teams, Telegram, Zapier, Make, n8n, Todoist…), haalt het icoon van die dienst op van de dienst zelf en weet hoe een bericht erheen moet. Lezen gaat direct; "stuur via Slack een bericht naar Lisa" wordt een plan dat pas weggaat na jouw **Uitvoeren**. Mist Nook een app waar je naar vraagt, dan vraagt hij welke je gebruikt en hoe je die koppelt. |
| Lokaal eerst | Standaard denkt Nook op je Mac (ingebouwd model, Ollama of LM Studio): niets verlaat je computer en het kost niets per vraag. Nook stelt per Mac het passende model voor. Een chip bij het invoerveld laat zien welk brein actief is. Extern (Claude met zoeken op het web, OpenAI, Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Claude Code) kies je bewust bij Instellingen › Brein. |
| Meekijken | Zeg je "maak er een afspraak voor" of verwijs je naar iets met "hier", "dit" of "daar", dan leest Nook zelf eerst het voorste venster en haalt datum, tijd en plaats eruit. ⌥⌘N: leest de tekst van het voorste venster (OCR, lokaal) en stelt iets voor als er een afspraak, belofte of taak in staat. Optioneel automatisch (Instellingen). |
| Afbeeldingen en schermdelen | Sleep een foto of screenshot op de chat, of druk ⌥⌘4 en trek een kader om een stuk van je scherm. Een brein dat kan zien (Claude, OpenAI, Gemini, een vision-model in Ollama of LM Studio) krijgt het beeld zelf; elk brein krijgt de tekst die Nook erin leest. |
| WhatsApp live | Koppel je telefoon via een koppeling op je eigen Mac (één klik bij **Instellingen › Accounts & koppelingen › WhatsApp live**, daarna een QR-code scannen). Nieuwe berichten verschijnen in de notch: typ je antwoord en druk op Return, of laat Nook een antwoord voorstellen. In de chat: "app Lisa dat ik later ben" wordt een plan dat pas na **Uitvoeren** weggaat. |
| Meedenken | Optioneel (Instellingen › Assistent). Ben je een tijdje met iets bezig, dan kijkt Nook mee en biedt hij zelf hulp aan, als korte zin naast de notch: "Zal ik dit in je agenda zetten?" of "Tip: dit kan ook in één keer". Wijs ernaar voor het hele voorstel met **Doe maar**, **Nee** of **Niet in deze app**. Zeg je vaker nee, dan houdt hij zich meer in. Een gemist aanbod staat nog even in Vandaag. |
| Nook zelf | Nook is een bol met licht en schaduw die je muis volgt. Hij springt op als je iets verstuurt, knikt als iets klaar is, krijgt blosjes als je muis even op hem rust en giechelt na drie snelle klikken. In het open paneel draagt hij een ring met alles waar hij en je agents mee bezig zijn: wit en bezig, amber als het op jou wacht, rood bij een fout, mint als het klaar is. Wijs een stuk aan en hij kijkt ernaar; klik en je gaat erheen. In de dichte notch is de ring er niet. |
| Vervolgvoorstellen | Onder een antwoord zet Nook wat hij daarna voor je kan doen, als knoppen ("Zet het in mijn agenda", "Schrijf een antwoord voor me"). Eén klik en hij gaat aan de slag. |
| Kleine dingen zelf doen | Optioneel. Vraag je om muziek, volume, een app, een herinnering of een open punt, dan doet Nook het meteen. Afspraken, mail, links, opdrachten en diensten vragen altijd eerst. |
| Agenda, herinneringen | Afspraken en herinneringen maken na jouw "Uitvoeren". |
| Geheugen | Ingebouwd, niets te installeren. Zeg "onthoud dat Lisa mijn vrouw is" of "voortaan korte antwoorden" en Nook weet het in elk volgend gesprek; "vergeet…" haalt het weg. Nook leert ook zelf: van je correcties, van wat je over jezelf vertelt, van de agenda of lijst die je in zijn voorstellen steeds kiest (die vult hij daarna zelf in), van acties die mislukten en van welke bron je vragen beantwoordt. Alles staat op je Mac en is te bekijken, aan te passen en te vergeten bij **Instellingen › Geheugen**. Gebruikte je de MCP-geheugenserver, dan neem je die kennisgraaf daar met één klik over. Zie [docs/ASSISTANT.md](docs/ASSISTANT.md#geheugen-nook-onthoudt-en-leert). |
| Aanvullen | Terwijl je in een andere app typt, stelt een model op je eigen Mac een vervolg van je zin voor, als grijze tekst bij je cursor. **Tab** neemt een woord, **⇧Tab** alles. Nook gebruikt het GGUF-model dat Cotypist al heeft gedownload (alleen gelezen) of downloadt er zelf een, zonder woordlimiet. Hij weet meer dan Cotypist: wat in je geheugen staat en wat op je scherm staat. Ook emoji op naam (`:lachen`), typfouten, instructies per app en website, leren van je eigen stijl en statistiek. Wachtwoordvelden en beveiligde invoer worden nooit gelezen. Aanzetten bij **Instellingen › Aanvullen**. Zie [docs/AUTOCOMPLETE.md](docs/AUTOCOMPLETE.md). |
| Open punten | Nook onthoudt beloftes en taken (lokale database) en toont ze in de tab Nook. |
| Muziek | Spotify en Muziek: hoes, doorspoelen, shuffle, herhalen en volume. |
| Agents | Claude Code, Codex, Gemini CLI e.d.: wie draait, wat doet hij (met live diff en +/− regels), wie wacht op je. Vraagt je agent toestemming, dan kan dat in de notch: **Toestaan**, **Altijd**, **Weigeren** of **In terminal**. Antwoord je in de terminal, dan verdwijnt de vraag meteen uit de notch. Meerkeuzevragen van Claude Code (AskUserQuestion) beantwoord je ook in de notch. **Open terminal** haalt het venster van de agent naar voren. Werkt er een agent, dan zie je dat in rust in de notch (een stipje per sessie); wijs ernaar en de Agents-tab gaat open. Is hij klaar, dan krijg je een kaartje met wat hij zei. |
| Abonnement | Hoeveel van je Claude- en Codex-limiet (5 uur en week) je gebruikt. |
| Werkruimte | Het hoofdvenster (⌥⌘W) met **Chat**, **Agents** en **Werkruimte**. Onder Agents start en volgt Nook zelf coding-agents: Claude Code (`claude -p` met stream-json) en Codex (`codex exec --json`). **Nieuwe sessie** (⌘N): kies een project of map (of kloon een repository), schrijf de opdracht, kies agent, account, model, Agent- of Plan-modus, rechten, en of de agent in de map zelf of in een **eigen Git-worktree** met een eigen branch werkt. Je ziet antwoorden, tool-aanroepen, gewijzigde bestanden en goedkeuringsvragen live; goedkeuren kan in het venster of in de notch. Stoppen (⌘.), verder gaan en opnieuw proberen hervatten dezelfde sessie van de agent; na een herstart van Nook staat alles er nog. Rechts: branch, worktree, wijzigingen met diff, **Commit**, **Push** en een pull request (via je GitHub-koppeling of op github.com), altijd pas na jouw klik. **Worktrees** toont alle worktrees met hun sessie en wijzigingen; weghalen vraagt bevestiging en weigert bij lopende sessies. **Gebruik** (Instellingen › Gebruik) toont limieten per account, en tokens en kosten per agent en model, alleen zoals de agents ze zelf melden; wat ze niet melden staat er als "niet beschikbaar". Elke goedkeuring toont het hele commando of de hele wijziging, in de notch en in het venster. |
| Terminal en browser | Onder **Werkruimte**: een ingebouwde terminal (SwiftTerm) en een browser (WebKit, niets wordt bewaard). Nook kan de open pagina lezen (`read_nook_browser`) en een pagina openen na jouw OK (`open_in_nook_browser`). Een commando van Nook (`run_command`) is altijd een actie: je ziet het hele commando, gevaarlijke commando's worden geweigerd en het draait in een zichtbare terminal. |
| Meerdere accounts | Ook voor diensten: twee GitHub-accounts naast elkaar, per chat te kiezen. Per agent meerdere accounts (bijvoorbeeld Claude Persoonlijk en Claude Werk), elk met een eigen map (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Inloggen met je abonnement of met een API-sleutel (Claude: in je Keychain; Codex: via `codex login --with-api-key` in de map van het account). Opnieuw inloggen, uitloggen, hernoemen en een standaard per agent. Elke werkruimte-sessie legt zijn account vast bij de start. Gemini CLI kent geen aparte accountmappen. |
| Werkruimte voor agents | Je agents gebruiken Nooks eigen terminal, browser en pull requests via een lokale MCP-server (`~/.nook/nook-mcp`): een dev-server starten in een zichtbare terminal (`terminal_run`, `terminal_read`), een pagina openen en controleren in Nooks browser met tekst, console-fouten en screenshot (`browser_open`, `browser_read`, `browser_screenshot`), en een pull request voorstellen (`pull_request_create`). Sessies die Nook start krijgen het vanzelf; een agent die je zelf start koppel je bij Instellingen › Agents › Werkruimte. Lezen gaat direct; een commando dat niet duidelijk onschuldig is en elk pull request vragen eerst jouw **Toestaan**, gevaarlijke commando's weigert Nook altijd, en Plan-modus mag alleen kijken. Zie [docs/WERKRUIMTE-AGENTS.md](docs/WERKRUIMTE-AGENTS.md). |
| Weekoverzicht | Op maandag bij Vandaag in de tab Nook (of via de menubalk): tijd met agents, sessies, regels code, toestemmingen, drukste dag. Alleen lokaal. |
| Bijlagen | Sleep een bestand (tekst, pdf, Word, rtf) op de chat of de notch om Nook er iets over te vragen, of kies de paperclip bij het invoerveld. |
| Snelle opdrachten | "Volgende nummer", "volume 30", "open Safari", "weekoverzicht": Nook herkent die zelf, zonder brein, dus meteen. |
| Eigen geluiden | Zet `attention`, `done` of `error` (.wav, .mp3, .aiff, .m4a) in de geluidenmap (Instellingen › Stem en geluid). |
| Stem | Optioneel leest Nook antwoorden voor, en luistert hij naar "Hé Nook" (alleen als je Mac spraak zelf herkent). |
| Besturen | Apps openen, links openen, volume, muziek, Opdrachten (Shortcuts), conceptmail in Mail. |

## Een lokaal brein dat goed antwoordt

Instellingen › Brein heeft een blok *Kwaliteit van het lokale brein*: **Bewijs eerst** (eerst de relevante zinnen uit elk gevonden document kopiëren, dan pas antwoorden), **Antwoorden controleren** (een getal, tijd of adres dat nergens in de bronnen staat, geeft een nieuw antwoord) en **Meet dit brein** (20 vragen met bekende antwoorden, met score en tijd). Zo vergelijk je modellen en instellingen met cijfers. Zie [docs/ASSISTANT.md](docs/ASSISTANT.md) en [scripts/finetune](scripts/finetune/README.md) om een model op Nooks taak te trainen.

## Privacy en veiligheid

- Niets wordt uitgevoerd zonder dat jij op Uitvoeren/Toestaan drukt. Alleen als je **Kleine dingen meteen doen** aanzet, doet Nook muziek, volume, apps openen, herinneringen en open punten waar jij om vroeg meteen; voorstellen die Nook zelf bedenkt (Meedenken) vragen altijd eerst. Nook verstuurt zelf nooit mail of berichten: ook een bericht via Slack of een webhook gaat pas na jouw Uitvoeren.
- Wat naar de AI-aanbieder gaat die je kiest: wat je zegt of typt (als tekst), de herkende tekst van je vensters (uit te zetten bij Instellingen › Assistent) en een korte samenvatting uit je koppelingen. Dat gebeurt alleen als je iets vraagt, of af en toe als je **Meedenken** aanzet (standaard uit). Het schermbeeld zelf verlaat je Mac nooit. Met Ollama, LM Studio of het ingebouwde model blijft alles op je Mac. Spraak wordt bij voorkeur op je Mac herkend; ondersteunt jouw Mac dat niet, dan gebruikt macOS de spraakherkenning van Apple.
- **Alleen op deze Mac** (Instellingen › Brein): per bron kies je dat alleen een brein op je Mac die mag lezen. Antwoordt een externe AI, dan krijgt die van zo'n bron geen context, geen tools, geen schermtekst en geen eerdere antwoorden die ermee gemaakt zijn, ook niet als je er in je vraag om vraagt; Nook zegt dan dat de bron niet is gebruikt. Met een brein op je Mac werkt alles weer.
- Tekst van je scherm, agenda-titels en tool-uitkomsten gaan als "onbetrouwbare data" naar het brein, met de opdracht daar geen instructies uit te volgen.
- Wachtwoordmanagers worden nooit gelezen.
- Nooks geheugen staat alleen op je Mac (`nook.sqlite`). Een externe AI krijgt per vraag alleen de paar herinneringen die erbij horen, nooit die je op **Alleen op deze Mac** zette. Wachtwoorden, codes, links en opdrachten worden nooit onthouden, en wat Nook zelf leert moet in je eigen berichten staan: tekst van het scherm, een mail of een webpagina kan niets in zijn geheugen zetten.
- Je gesprekken met Nook (de Nooks) staan alleen op je Mac, in `~/Library/Application Support/Nook/nooks.json` (alleen leesbaar voor jou). Voorgestelde acties die nog wachtten, worden na een herstart niet meer uitgevoerd.
- De hook-socket is alleen voor jouw gebruiker (rechten 0600 + controle op gebruikers-ID).
- Instellingenbestanden van je agents past Nook alleen aan na een voorbeeld en jouw klik, met eerst een backup ernaast (`settings.json.nook-backup-…`). Een onleesbaar bestand of een onverwachte vorm laat Nook ongemoeid.
- Het wekwoord staat standaard uit en werkt alleen met spraakherkenning op je eigen Mac.
- Alles wat Nook uitvoert staat in een logboek (`nook.sqlite`, tabel `audit`). Je ziet het bij Instellingen › Privacy & beveiliging, met zoeken; het wordt 90 dagen bewaard.
- Het Claude Code-brein draait in een lege map zonder bestands- of web-tools; webpagina's gaan alleen naar publieke adressen (ook na een redirect); links in antwoorden openen alleen https of mail; bronverwijzingen naar bestanden voeren nooit iets uit.
- Gebruikersgegevens gaan niet verloren: een bestand dat niet gelezen kan worden, wordt eerst naast de oorspronkelijke bewaard (`….unreadable-<datum>.json`) en nooit overschreven.

Een beveiligingsprobleem gevonden? Zie [SECURITY.md](SECURITY.md).

## Mappen

```
(in apps/macos/)
App/       start, menubalk, AppModel (alleen samenstelling; elk onderdeel in een eigen AppModel+….swift), instellingen
NotchUI/   thema, karakter, kaarten, notch-tabs, hoofdvenster, werkruimte (terminal, browser), gedeelde onderdelen
Services/  agenda, muziek, agent-hub, sessieregister, goedkeuringen, limieten, werkruimte, koppelingen (met MCP)
Brain/     modellen en één tool-loop, bronkeuze, tools, commando-risico, bronverwijzingen, controle van acties
Core/      paden, instellingen + Keychain (SecretStore), opslag (SQLite met migraties), vertalingen (nl/en/de)
Demo/      voorbeelddata (alleen in debug-builds en bij Voorbeelddata in Instellingen)
Tests/     unit-tests (xcodebuild test)
```

`Nook.xcodeproj`, `Info.plist` en de entitlements worden door XcodeGen gemaakt vanuit [`apps/macos/project.yml`](apps/macos/project.yml) en staan niet in git.

## Bekende beperkingen

- Het ingebouwde gratis model gebruikt de Swift-pakketten mlx-swift-lm, swift-huggingface en swift-transformers. Die vragen Xcode 26 of nieuwer en een Apple Silicon-Mac. De eerste build haalt de pakketten op en duurt lang. Draai `xcodegen` opnieuw na een `git pull`.
- De app is ad-hoc ondertekend. Daardoor ziet macOS elke nieuwe build als een andere app en kunnen machtigingen en Keychain-toegang opnieuw gevraagd worden. Met een eigen Developer ID-certificaat gebeurt dat niet.
- Nook is hardened-runtime ondertekend (geen sandbox: AppleScript en procesbeheer kunnen niet in een sandbox). Of het ingebouwde MLX-model daar zonder extra entitlement draait, is op een echte Mac te controleren.
- De hooks voor Claude Code, Codex en Gemini CLI volgen hun documentatie, maar zijn nog niet getest met de huidige versies. Het hook-script is een Perl-script (Perl staat standaard op macOS).
- macOS heeft geen API om meldingen van andere apps te lezen, dus meldingen filteren zit er niet in. Meldingen van je agents lopen wel via Nook.

## Meedoen

Issues en pull requests zijn welkom. Lees eerst [CONTRIBUTING.md](CONTRIBUTING.md).

## Dank

Het idee voor een app in de notch is geïnspireerd door [boring.notch](https://github.com/TheBoredTeam/boring.notch). Er is geen code van overgenomen.

## Licentie

[MIT](LICENSE) © 2026 Michan van der Hoek
