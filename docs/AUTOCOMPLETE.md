# Aanvullen

Terwijl je in een andere app typt, stelt Nook voor hoe je zin verdergaat. Dat gebeurt als grijze tekst achter je cursor, door een model op je eigen Mac. **Tab** neemt het volgende woord, **⇧Tab** neemt alles. Typ je zelf wat er staat, dan blijft de rest staan. Elke andere toets stuurt het voorstel weg.

Aanzetten doe je bij **Instellingen › Aanvullen**.

## Nook naast Cotypist

| | Cotypist | Nook |
| --- | --- | --- |
| Voorstellen in elke app, als grijze tekst | ✓ | ✓ |
| Woord voor woord (Tab) of alles (⇧Tab), doortypen | ✓ | ✓, toetsen vrij te kiezen |
| Model op je eigen Mac (llama.cpp, GGUF) | ✓ | ✓, en het model dat Cotypist al downloadde |
| Woordlimiet | 100 per dag gratis, daarna abonnement | geen |
| Eigen instructies | Plus | ✓ |
| Instructies per app | Pro | ✓, ook per website |
| Klembord als context | Pro | ✓ |
| Midden in een regel | Pro (Labs) | ✓ |
| Modelcatalogus | Pro | ✓, met advies voor jouw Mac |
| Emoji op naam | ✓ | ✓, ook met Nederlandse namen (`:lachen`, `:duim`) |
| Typfouten | autocorrect | verbetering die je met Tab neemt |
| Wat je geheugen weet (naam, werk, mensen) | – | ✓ |
| Wat er op je scherm staat (de mail waarop je antwoordt) | – | ✓, uit Nooks eigen schermlezing |
| Leren van je eigen schrijven | ✓ | ✓, lokaal, geheimen (ook BSN) weggefilterd, te wissen |
| Andere woorden kiezen met een cijfer | – | ✓ (proef) |
| Batterij: korter of pauzeren | – | ✓ |
| Slimme aanhalingstekens volgens macOS | ✓ | ✓, met `'s` en `'t` goed |
| Statistiek | ✓ | ✓, met bespaarde minuten |

De kolom Cotypist komt uit openbare reviews en hun prijspagina. Wil je het precies weten? Draai dan `scripts/inspect-cotypist.sh` op een Mac waar Cotypist op staat (zie onder).

## Hoe het werkt

1. **Toetsen opvangen.** Een toetsenbordfilter (`CGEventTap`) ziet elke toets eerder dan de app. Alleen de accepteertoetsen worden tegengehouden, en dan alleen als er een voorstel staat.
2. **Het veld lezen.** Na een korte pauze (standaard 120 ms) leest `AutocompleteField` via de Accessibility-API het veld met de focus. Dat is de tekst voor en na de cursor, de selectie, waar de cursor staat, de placeholder, de venstertitel en bij browsers de website. Voor Chromium, Electron en WebKit gebruikt het text markers en `AXManualAccessibility`. Wachtwoordvelden worden nooit gelezen. Zolang macOS beveiligde invoer gebruikt, doet Nook niets.
3. **Kiezen wat er komt.** Typ je `:naam`, dan komt er een emoji. Is het vorige woord een typfout, dan komt er de verbetering. Anders komt er een voorstel van het model.
4. **De prompt.** `PromptBuilder` maakt er een document van: wie je bent (je instructies en Nooks geheugen), eerder geschreven tekst, de tekst op het scherm, het klembord, waar je schrijft, en dan de tekst voor je cursor. Het begin van het venster schuift in stappen van 1000 tekens op. Zo hergebruikt het model zijn cache en kost één letter erbij maar één token.
5. **Het model.** `LlamaCompleter` gebruikt llama.cpp met Metal en kiest per stap het waarschijnlijkste token. Is het model te onzeker over het eerste woord, dan toont Nook niets. Daarna stopt het voorstel waar die zekerheid wegzakt. Hoe gretig dat gaat, stel je zelf in. Woorden die je vaak schrijft krijgen een kleine bonus.
6. **Tonen en typen.** `GhostOverlay` tekent het voorstel zelf, in een paneel dat geen klikken en geen focus aanneemt. De tekst krijgt het lettertype en de grootte van de app, uitgelezen via `AXAttributedStringForRange`. Hij is grijs zoals een plaatshouder, staat verticaal gecentreerd op de regel en begint precies waar je tekst eindigt, dus naast je tekst en nooit eroverheen. Daarvoor telt de rechterrand van het teken vóór de cursor eerder dan het lege bereik, want veel apps geven voor dat lege bereik een verkeerde plek. Alleen als de cursor op een nieuwe regel staat, telt het lege bereik. Een cursor buiten zijn eigen veld wordt genegeerd.
7. **Wat past.** Er verschijnen alleen woorden die tot de rechterrand van het veld passen, en Tab neemt alleen wat je ziet. Past er niets, dan komt het voorstel als kaartje onder de cursor.
8. **Doortypen en nemen.** Typ je een letter van het voorstel of neem je een woord, dan schuift de grijze tekst meteen op met de breedte van die letters. Daarna zet Nook hem precies op de plek die de app opgeeft. `AutocompleteTyper` typt een genomen woord als Unicode-toetsen, dus het klembord blijft ongemoeid.

Velden zonder gewone tekstwaarde, zoals rich-text editors in de browser (Gmail, Notion, Slack, Google Docs met toegankelijkheid aan), leest Nook via text markers. Chromium-browsers krijgen `AXEnhancedUserInterface` en Electron-apps `AXManualAccessibility`, zodat ze hun velden laten zien. Een webpagina die je alleen leest, telt niet als veld.

## Het model van Cotypist

`CompletionModelLocator` zoekt in `~/Library/Application Support`, `Caches`, `Containers`, `Group Containers` en `/Applications` naar mappen met "cotypist" in de naam. Het neemt elk `.gguf`-bestand daarin, behalve `mmproj`. `GGUFReader` leest van elk bestand de header (naam, architectuur, contextlengte) zonder het model te laden. Nook kiest het nieuwste model van Cotypist, en anders een eigen model uit `~/Library/Application Support/Nook/Autocomplete/Models`. Nook leest het bestand alleen: geen kopie, geen wijziging.

Heeft Cotypist geen los GGUF-bestand, dan download je in Instellingen een model uit de catalogus. Nook raadt Gemma aan, omdat dat het beste Nederlands schrijft.

## Cotypist uitlezen

```sh
scripts/inspect-cotypist.sh        # schrijft ~/Desktop/cotypist-report.txt
```

Het script leest alleen. Het toont:
- de bundel, frameworks en entitlements;
- de instellingssleutels, met waarden afgekapt op 60 tekens;
- de mappen met hun groottes;
- de modelbestanden met hun GGUF-metadata, waaronder het chat-sjabloon;
- de strings in het programma die over prompts, sampling en macOS-API's gaan.

Je getypte tekst en je schrijfgeschiedenis leest het nooit. Kijk het rapport na voordat je het deelt. Met dat rapport kan Nook nog dichter bij Cotypist komen, bijvoorbeeld met hetzelfde prompt-formaat of dezelfde samplinginstellingen.

## Bouwen en testen

Het pakket `LlamaSwift` ([mattt/llama.swift](https://github.com/mattt/llama.swift), vastgezet op 2.10549.0, dat is llama.cpp b10549) staat in `apps/macos/project.yml`. Draai na een `git pull` `xcodegen` zoals gewoonlijk.

De logica zonder AppKit heeft tests in `Tests/NookTests/AutocompleteTests.swift`. Dat zijn `GGUFReader`, `CompletionModels`, `CompletionSuggestion`, `CompletionPreferences`, `CompletionEmoji`, `CompletionPrivacy` en `CompletionLearning`. Ze draaien ook zonder Xcode met `scripts/core-tests.sh --filter AutocompleteTests`. De engine, het toetsfilter, de veldlezer en de overlay test je alleen op een Mac.

Een deel van het ontwerp en de code komt uit [Typist](https://github.com/BrodySalvucci/Typist) (MIT). Dat is een open-source app die het gedrag van Cotypist bestudeerde, zonder Cotypists code. Zie `THIRD-PARTY-NOTICES.md`.
