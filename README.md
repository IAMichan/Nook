# Nook

[![Build](https://github.com/IAMichan/nook/actions/workflows/build.yml/badge.svg)](https://github.com/IAMichan/nook/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)

Je persoonlijke agent in de notch van je Mac.

> **English:** Nook is a personal AI assistant that lives in the MacBook notch. It keeps the text of every window on every display up to date locally, so any question is answered instantly with what you see, plus your calendar, reminders, mail, browser tabs, files and connected services (GitHub, Stripe, Vercel, Notion, Cal.com, n8n, Resend, crypto). It thinks with Claude, OpenAI, Google Gemini, Grok (xAI), Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Ollama, LM Studio or a built-in local model, shows what your coding agents are doing (Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, OpenCode, Amp, Hermes…), and controls music. Nothing runs without your explicit approval. The interface is in Dutch.

> **Status:** vroege versie (0.1). De app compileert, maar is nog weinig in de praktijk getest. Verwacht ruwe randjes.

## Vereisten

- macOS 15 of nieuwer, het liefst een Mac met notch
- Xcode 16 of nieuwer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Een [Anthropic API-sleutel](https://console.anthropic.com/)

## Bouwen en starten

```sh
brew install xcodegen
git clone https://github.com/IAMichan/nook.git
cd nook
xcodegen
open Nook.xcodeproj
```

Na elke `git pull` kan er een nieuw bestand bij zijn gekomen. Draai dan `./update.sh` (haalt op en draait `xcodegen`), anders klaagt Xcode over iets dat 'not in scope' is.

Wil je Nook niet in de notch? Kies in **Instellingen › Overzicht › Notch › Plek** voor **Zwevend op het scherm** en sleep hem aan de balk (of de bovenrand van het paneel) naar waar je hem wilt. Je positie wordt onthouden.

Druk op ⌘R. Nook heeft geen Dock-icoon: je ziet hem in de notch en als klein Nook-figuurtje in de menubalk.

**De eerste keer**
Nook laat de eerste keer zelf een welkomstkaart zien. In **Instellingen › Overzicht** staat een checklist met wat er nog moet:
1. **Brein**: Claude (API-sleutel), een andere AI (OpenAI, Google Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Ollama, LM Studio) of **Gratis op je Mac** (ingebouwd, MLX).
2. **Privacy en toegang**: Scherm lezen, Agenda, Herinneringen en Microfoon.
3. **Koppelingen**: zet aan wat je wilt (Mail, browser, bestanden). Klik bij GitHub op **Koppel met GitHub** en bevestig de code op github.com; voor Stripe en de rest plak je een sleutel.
4. Voor je agents: klik bij **Agents** op **Koppel…** naast Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, Muse, OpenCode, Amp of Hermes. Elke andere agent kan zich melden met `nook_agent`, zie [docs/AGENTS.md](docs/AGENTS.md). Nook laat precies zien wat er in het instellingenbestand verandert, maakt eerst een backup en schrijft pas na jouw OK. Start de agent daarna opnieuw. Met **Claude-abonnement in de notch** zie je ook je 5-uurs- en weeklimiet (Pro/Max).

Wil je hem zonder API-sleutel bekijken? Kies in de menubalk **Voorbeelddata tonen**.

## Wat het doet

| Wat | Hoe |
|---|---|
| Praten tegen Nook | ⌥ spatie (of de microfoonknop). Herkenning op je Mac; daarna denkt het brein mee. |
| Chatten met Nook | ⌥⌘ spatie, waar je ook bent, of het veld onderaan de tab Nook. Een echt gesprek: vervolgvragen worden begrepen, het antwoord verschijnt terwijl het geschreven wordt, met kopjes, lijstjes, tabellen en code. De vragen om mee te beginnen passen bij wat je nu doet (de app die voor staat, je volgende afspraak, een agent die wacht, het moment van de dag). |
| Nooks | Elk gesprek is een eigen Nook die aan één ding werkt. Begin er een met **Nieuwe Nook** (⌘N); de vorige werkt gewoon door. Links zie je al je Nooks met hun status: bezig, wacht op jou (een plan of mail) of klaar. Is er een klaar terwijl je iets anders doet, dan meldt hij zich in de notch. De geschiedenis blijft bewaard op je Mac (`nooks.json`), ook na een herstart; rechtsklik om een Nook weg te halen. |
| Bronnen en bewijs | Nook kiest per vraag zelf welke koppelingen ertoe doen en zoekt daar gericht. Boven het antwoord zie je per bron of hij doorzocht is, niets vond of faalde; onder het antwoord staan genummerde bronnen ([1], [2]) die je opent in Mail, de browser of Finder. Met de bronkiezer naast het invoerveld, of in je vraag ("alleen mijn agenda en mail", "niet mijn scherm"), bepaal je welke bronnen mogen. Zie [docs/ASSISTANT.md](docs/ASSISTANT.md). |
| Acties in stappen | Vraag iets dat meerdere dingen doet ("maak taken voor wat nog open staat en zet een mail klaar") en je krijgt één plan. Per stap zie je alle details; je kunt stappen uitzetten of tekst aanpassen. Mislukt er halverwege iets, dan zie je wat wel en niet lukte en ga je verder zonder dat iets dubbel gebeurt. |
| Grafieken | Vraag om een grafiek ("maak een grafiek van mijn afspraken per dag") en Nook tekent hem in de chat: staaf, lijn, vlak, taart of punten. De cijfers haalt hij uit je agenda, je diensten of het web. Schrijft het brein toch code, JSON, Mermaid of een tabel, dan maakt Nook daar zelf een echte grafiek van; lukt dat niet, dan vraagt hij het brein opnieuw om te tekenen. |
| Mail schrijven | "Schrijf een mail aan Lisa dat ik later ben": Nook zet een complete mail als concept in de chat. Pas hem aan en klik **Versturen** (via Mail), of **Open in Mail**. Er gaat nooit iets weg zonder jouw klik. |
| Al je schermen | Nook houdt de tekst van al je vensters op al je schermen bij (lokaal, OCR) en gebruikt die bij elke vraag. Daardoor is een antwoord meteen klaar. Boven een antwoord zie je waar Nook keek. |
| Koppelingen | Agenda, herinneringen, Mail (ongelezen en zoeken), browsertabs, recente bestanden en zoeken met Spotlight, klembord (standaard uit). Diensten met een eigen sleutel: GitHub (ook pull requests beoordelen, goedkeuren, samenvoegen en sluiten, altijd pas na jouw Uitvoeren), Vercel, Stripe, Notion, Cal.com, n8n, Resend en een crypto-portfolio. Alles in de tab Koppelingen. |
| Alle agenda's tegelijk | Vraag "ben ik 13 oktober beschikbaar?" en Nook kijkt in álle agenda's: Apple Agenda (met alle accounts die daar in zitten), agenda's via een ICS-adres (Google Agenda, Outlook, iCloud, werkagenda) onder **Andere agenda's**, en Cal.com. Je hoort in welke agenda's hij keek, en welke vrije momenten er zijn. |
| Eigen bronnen | Bijna elke app of dienst met een web-API of webhook koppel je onder **Eigen bronnen** (https, sleutel in de Keychain). Nook herkent aan het adres welke dienst het is (Slack, Discord, Teams, Telegram, Zapier, Make, n8n, Todoist…), haalt het icoon van die dienst op van de dienst zelf en weet hoe een bericht erheen moet. Lezen gaat direct; "stuur via Slack een bericht naar Lisa" wordt een plan dat pas weggaat na jouw **Uitvoeren**. Mist Nook een app waar je naar vraagt, dan vraagt hij welke je gebruikt en hoe je die koppelt. |
| Elk brein | Claude (met zoeken op het web), OpenAI, Google Gemini, Grok, Mistral, Groq, OpenRouter, DeepSeek, Qwen, Moonshot, Ollama en LM Studio, of het ingebouwde gratis model. |
| Meekijken | Zeg je "maak er een afspraak voor" of verwijs je naar iets met "hier", "dit" of "daar", dan leest Nook zelf eerst het voorste venster en haalt datum, tijd en plaats eruit. ⌥⌘N: leest de tekst van het voorste venster (OCR, lokaal) en stelt iets voor als er een afspraak, belofte of taak in staat. Optioneel automatisch (Instellingen). |
| Meedenken | Optioneel (Instellingen › Assistent). Ben je een tijdje met iets bezig, dan kijkt Nook mee en biedt hij zelf hulp aan, als korte zin naast de notch: "Zal ik dit in je agenda zetten?" of "Tip: dit kan ook in één keer". Wijs ernaar voor het hele voorstel met **Doe maar**, **Nee** of **Niet in deze app**. Zeg je vaker nee, dan houdt hij zich meer in. Een gemist aanbod staat nog even in Vandaag. |
| Vervolgvoorstellen | Onder een antwoord zet Nook wat hij daarna voor je kan doen, als knoppen ("Zet het in mijn agenda", "Schrijf een antwoord voor me"). Eén klik en hij gaat aan de slag. |
| Kleine dingen zelf doen | Optioneel. Vraag je om muziek, volume, een app, een herinnering of een open punt, dan doet Nook het meteen. Afspraken, mail, links, opdrachten en diensten vragen altijd eerst. |
| Agenda, herinneringen | Afspraken en herinneringen maken na jouw "Uitvoeren". |
| Open punten | Nook onthoudt beloftes en taken (lokale database) en toont ze in de tab Nook. |
| Muziek | Spotify en Muziek: hoes, doorspoelen, shuffle, herhalen en volume. |
| Agents | Claude Code, Codex, Gemini CLI e.d.: wie draait, wat doet hij (met live diff en +/− regels), wie wacht op je. Vraagt je agent toestemming, dan kan dat in de notch: **Toestaan**, **Altijd**, **Weigeren** of **In terminal**. Antwoord je in de terminal, dan verdwijnt de vraag meteen uit de notch. Meerkeuzevragen van Claude Code (AskUserQuestion) beantwoord je ook in de notch. **Open terminal** haalt het venster van de agent naar voren. Werkt er een agent, dan zie je dat in rust in de notch (een stipje per sessie); wijs ernaar en de Agents-tab gaat open. Is hij klaar, dan krijg je een kaartje met wat hij zei. |
| Abonnement | Hoeveel van je Claude- en Codex-limiet (5 uur en week) je gebruikt. |
| Werkruimte | Een eigen venster (⌥⌘W, of **Werkruimte** in de Agents-tab) waarin Nook zelf coding-agents start en volgt: Claude Code (`claude -p` met stream-json) en Codex (`codex exec --json`). **Nieuwe sessie** (⌘N): kies een project of map (of kloon een repository), schrijf de opdracht, kies agent, account, model, Agent- of Plan-modus, rechten, en of de agent in de map zelf of in een **eigen Git-worktree** met een eigen branch werkt. Je ziet antwoorden, tool-aanroepen, gewijzigde bestanden en goedkeuringsvragen live; goedkeuren kan in het venster of in de notch. Stoppen (⌘.), verder gaan en opnieuw proberen hervatten dezelfde sessie van de agent; na een herstart van Nook staat alles er nog. Rechts: branch, worktree, wijzigingen met diff, **Commit**, **Push** en een pull request (via je GitHub-koppeling of op github.com), altijd pas na jouw klik. **Worktrees** toont alle worktrees met hun sessie en wijzigingen; weghalen vraagt bevestiging en weigert bij lopende sessies. **Gebruik** toont tokens en kosten per agent en model, alleen zoals de agents ze zelf melden; wat ze niet melden staat er als "niet beschikbaar". |
| Meerdere accounts | Per agent meerdere accounts (bijvoorbeeld Claude Persoonlijk en Claude Werk), elk met een eigen map (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Inloggen met je abonnement of met een API-sleutel (Claude: in je Keychain; Codex: via `codex login --with-api-key` in de map van het account). Opnieuw inloggen, uitloggen, hernoemen en een standaard per agent. Elke werkruimte-sessie legt zijn account vast bij de start. Gemini CLI kent geen aparte accountmappen. |
| Weekoverzicht | Op maandag in de tab Nook (of via de menubalk): tijd met agents, sessies, regels code, toestemmingen, drukste dag. Alleen lokaal. |
| Shelf | Sleep een bestand (tekst, pdf, Word, rtf) in de Shelf en klik erop om Nook er iets over te vragen, of rechtsklik om het als bijlage in een nieuwe mail te zetten. |
| Snelle opdrachten | "Volgende nummer", "volume 30", "open Safari", "weekoverzicht": Nook herkent die zelf, zonder brein, dus meteen. |
| Eigen geluiden | Zet `attention`, `done` of `error` (.wav, .mp3, .aiff, .m4a) in de geluidenmap (Instellingen › Stem en geluid). |
| Stem | Optioneel leest Nook antwoorden voor, en luistert hij naar "Hé Nook" (alleen als je Mac spraak zelf herkent). |
| Besturen | Apps openen, links openen, volume, muziek, Opdrachten (Shortcuts), conceptmail in Mail. |

## Privacy en veiligheid

- Niets wordt uitgevoerd zonder dat jij op Uitvoeren/Toestaan drukt. Alleen als je **Kleine dingen meteen doen** aanzet, doet Nook muziek, volume, apps openen, herinneringen en open punten waar jij om vroeg meteen; voorstellen die Nook zelf bedenkt (Meedenken) vragen altijd eerst. Nook verstuurt zelf nooit mail of berichten: ook een bericht via Slack of een webhook gaat pas na jouw Uitvoeren.
- Wat naar de AI-aanbieder gaat die je kiest: wat je zegt of typt (als tekst), de herkende tekst van je vensters (uit te zetten bij Instellingen › Assistent) en een korte samenvatting uit je koppelingen. Dat gebeurt alleen als je iets vraagt, of af en toe als je **Meedenken** aanzet (standaard uit). Het schermbeeld zelf verlaat je Mac nooit. Met Ollama, LM Studio of het ingebouwde model blijft alles op je Mac. Spraak wordt bij voorkeur op je Mac herkend; ondersteunt jouw Mac dat niet, dan gebruikt macOS de spraakherkenning van Apple.
- Tekst van je scherm, agenda-titels en tool-uitkomsten gaan als "onbetrouwbare data" naar het brein, met de opdracht daar geen instructies uit te volgen.
- Wachtwoordmanagers worden nooit gelezen.
- Je gesprekken met Nook (de Nooks) staan alleen op je Mac, in `~/Library/Application Support/Nook/nooks.json` (alleen leesbaar voor jou). Voorgestelde acties die nog wachtten, worden na een herstart niet meer uitgevoerd.
- De hook-socket is alleen voor jouw gebruiker (rechten 0600 + controle op gebruikers-ID).
- Instellingenbestanden van je agents past Nook alleen aan na een voorbeeld en jouw klik, met eerst een backup ernaast (`settings.json.nook-backup-…`). Een onleesbaar bestand of een onverwachte vorm laat Nook ongemoeid.
- Het wekwoord staat standaard uit en werkt alleen met spraakherkenning op je eigen Mac.
- Alles wat Nook uitvoert staat in een logboek (`nook.sqlite`, tabel `audit`).

Een beveiligingsprobleem gevonden? Zie [SECURITY.md](SECURITY.md).

## Mappen

```
App/       start, menubalk, AppModel (verbindt alles), instellingen
NotchUI/   thema, karakter, kaarten, tabs, venster
Services/  agenda, muziek, agent-hub, stem, scherm lezen, sneltoets, hook-script
Brain/     Claude-koppeling, tools, datums, commando-risico, bronkeuze, bronverwijzingen, controle van acties
Core/      paden, instellingen + Keychain, opslag (SQLite)
Demo/      voorbeelddata (menubalk › Voorbeelddata tonen)
Tests/     unit-tests voor bronkeuze, bronverwijzingen en acties (xcodebuild test)
```

`Nook.xcodeproj`, `Info.plist` en de entitlements worden door XcodeGen gemaakt vanuit [`project.yml`](project.yml) en staan niet in git.

## Bekende beperkingen

- Het ingebouwde gratis model gebruikt de Swift-pakketten mlx-swift-lm, swift-huggingface en swift-transformers. Die vragen Xcode 26 of nieuwer en een Apple Silicon-Mac. De eerste build haalt de pakketten op en duurt lang. Draai `xcodegen` opnieuw na een `git pull`.
- De app is ad-hoc ondertekend. Daardoor ziet macOS elke nieuwe build als een andere app en kunnen machtigingen en Keychain-toegang opnieuw gevraagd worden. Met een eigen Developer ID-certificaat gebeurt dat niet.
- De hooks voor Claude Code, Codex en Gemini CLI volgen hun documentatie, maar zijn nog niet getest met de huidige versies. Het hook-script is een Perl-script (Perl staat standaard op macOS).
- macOS heeft geen API om meldingen van andere apps te lezen, dus meldingen filteren zit er niet in. Meldingen van je agents lopen wel via Nook.

## Meedoen

Issues en pull requests zijn welkom. Lees eerst [CONTRIBUTING.md](CONTRIBUTING.md).

## Dank

Het idee voor een app in de notch is geïnspireerd door [boring.notch](https://github.com/TheBoredTeam/boring.notch). Er is geen code van overgenomen.

## Licentie

[MIT](LICENSE) © 2026 Michan van der Hoek
