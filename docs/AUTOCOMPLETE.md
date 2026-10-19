# Aanvullen

Terwijl je in een andere app typt, stelt Nook voor hoe je zin verdergaat. Dat gebeurt als grijze tekst achter je cursor, door een model op je eigen Mac. **Tab** neemt het volgende woord, **⇧Tab** neemt alles. Typ je zelf wat er staat, dan blijft de rest staan. Elke andere toets stuurt het voorstel weg.

Aanzetten doe je bij **Instellingen › Aanvullen**. Dat paneel heeft vier tabbladen:

- **Algemeen**: aan/uit en de status, het model (dat van je brein, een GGUF-model op je Mac, een eigen bestand of een download), hoe lang en hoe gretig de voorstellen zijn, en de toetsen.
- **Apps**: al je geïnstalleerde apps met hun icoon en een schakelaar. Zoek een app of filter op Aan of Uit. Klik op een app voor eigen uitleg, Tab aan de app laten, midden in een regel, leren, tekstgrootte, hoogte en pauzeren. Daaronder staan websites: die zet je apart uit of geef je eigen uitleg, ook als de browser aan staat. Terminals, code-editors en wachtwoordmanagers staan standaard uit.
- **Stijl en context**: wat het model weet (app en venster, je geheugen, je scherm, het klembord), jouw stijl en leren, emoji, typfouten, batterij en andere woorden.
- **Statistiek**: hoe vaak je aanvullen gebruikte vandaag, deze week en in totaal, een grafiek van 30 dagen, bespaarde typtijd, ingevulde tekens, hoeveel voorstellen je nam, je reeks en in welke apps je het meest aanvult. Een keer is elke Tab die iets invult. Nook bewaart alleen aantallen, nooit wat je typte.

In de notch staat bij Vandaag een regel als aanvullen aan staat maar niet kan werken (geen toegang of geen model), met een knop die het juiste tabblad opent. Heb je vandaag aangevuld en is er ruimte, dan zie je daar ook hoe vaak, met een link naar Statistiek. Het menubalkmenu heeft een knop om te pauzeren met het aantal woorden van vandaag, en in de zijbalk van Instellingen krijgt Aanvullen een badge als er iets moet gebeuren.

## Wat het kan

- Voorstellen in elke app als grijze tekst in de regel. **Tab** neemt een woord en **⇧Tab** alles; je kunt ook doortypen. Alle toetsen kun je zelf kiezen.
- Een model op je eigen Mac: het model van je brein (MLX) of een GGUF-model (llama.cpp). Er is geen woordlimiet en geen abonnement.
- Je eigen instructies, ook per app en per website. Per app zet je aanvullen aan of uit, met een lijst van al je apps.
- Context uit je geheugen (naam, werk, mensen), van je scherm (de mail waarop je antwoordt) en van het klembord.
- Midden in een regel, emoji op naam (ook Nederlands: `:lachen`, `:duim`), typfouten verbeteren en andere woorden kiezen met een cijfer.
- Leren van je eigen schrijven, lokaal. Geheimen, ook een BSN, worden eruit gefilterd en je kunt alles wissen.
- Slimme aanhalingstekens volgens macOS, met `'s` en `'t` goed.
- Kortere voorstellen of pauze op batterij.
- Statistiek per dag, per week en per app.

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

## Welk model

**Automatisch** kiest in deze volgorde:

1. **Een GGUF-model dat al op je Mac staat.** Andere apps en tools hebben het dan al gedownload. `CompletionModelLocator` zoekt in `~/Library/Application Support`, `~/Library/Caches`, de map van LM Studio en de caches van Hugging Face en llama.cpp. De containers van andere apps slaat het over, want daarvoor vraagt macOS toestemming. Projectoren voor beeld, embedding-modellen en bestanden onder 50 MB tellen niet mee. `GGUFReader` leest van elk bestand alleen de header (naam, architectuur, contextlengte). Nook leest zo'n bestand alleen, op de plek waar het staat: geen kopie, geen wijziging.
2. **Een GGUF-model dat je in Instellingen downloadde.** Dat doe je bij **Instellingen › Aanvullen › Algemeen › GGUF-modellen downloaden**. Bovenaan staan de GGUF-modellen die al op je Mac staan, met een vinkje en *In gebruik* of *Gebruik*. Daaronder staat een lijst basismodellen met hun grootte en het geheugen dat ze vragen. Nook raadt Gemma aan, omdat dat het beste Nederlands schrijft. Je kunt ook een eigen link naar een `.gguf`-bestand plakken, zoals een Hugging Face-pagina of een directe link. Je ziet de voortgang in GB en kunt de download annuleren. Is een download klaar, dan controleert Nook of het echt een GGUF-model is en gebruikt het meteen. Gedownloade modellen kun je weer verwijderen. Staat er nog geen enkel model op je Mac, dan zit de knop voor het aanbevolen model direct in de melding "Nog geen model".
3. **Het model van je brein.** Dat is het lokale MLX-model dat het brein gebruikt. Je hoeft dan niets te downloaden. Aanvullen gebruikt alleen dat model en laadt nooit een ander, zodat de chat zijn model in het geheugen houdt.

Je kunt ook zelf een model kiezen, of een `.gguf`-bestand.

### Snelheid

Een voorstel moet er zijn voordat je verder typt. Daarom:

- **Woord voor woord.** Zodra het model één woord af heeft, staat dat woord al in beeld. De rest volgt terwijl het model doorschrijft, en Tab werkt meteen.
- **Vaste context per veld.** Wat vóór je tekst in de prompt staat (instructies, geheugen, scherm, klembord, waar je schrijft), haalt Nook één keer per veld op, en daarna maximaal elke tien minuten opnieuw. Zo blijft het begin van de prompt gelijk, en een toets kost alleen de laatste paar tokens.
- **Cache hergebruiken.** llama.cpp zet de cache terug tot het gedeelde begin. Modellen met een rollend venster (Gemma 3 en 4) krijgen daarvoor een volledige cache (`swa_full`). Hybride modellen, waarvan de cache niet terug kan, krijgen checkpoints: elke 64 tokens bewaart Nook een kopie (`llama_state_seq_get_data`), en bij de volgende toets gaat het daar verder. Het model van het brein werkt altijd met zulke checkpoints (`KVCache.copy()`), dus voor elk soort cache.
- **Kortere prompt:** hoogstens zo'n 2000 tekens tekst, met een begin dat in stappen van 500 opschuift.
- **Korte wachttijd:** 40 ms na de laatste toets. Een voorstel dat te laat is, stopt bij de volgende toets.
- **Window text without blocking:** with "What is on your screen" on (the default), the text of the window you write in comes from Nook's screen reading when that is on, and otherwise autocomplete reads the focused window itself through Accessibility (`AppTextReader.focusedWindowText`), once per field and off the main thread. The first suggestion in a field does not wait for it; the window text joins the prompt from the next key on.
- **Writing ahead:** while a suggestion is on screen, Nook already writes how the text goes on after it. Taking the last word (or typing it to the end) shows the next suggestion as soon as the app has the text, without the pause after a key or a new model call.
- **Model blijft geladen.** Gebruikt aanvullen het model van het brein, dan blijft dat tijdens het typen een kwartier in het geheugen in plaats van anderhalve minuut.

### Het model van je brein

`BrainCompleter` gebruikt hetzelfde model als het brein via `EmbeddedModel`, en werkt net als `LlamaCompleter`:

- **Zekerheidsdrempel:** een `LogitSampler` kiest steeds het waarschijnlijkste token en onthoudt hoe zeker het model daarvan was. Is het model onzeker over het eerste token, dan toont Nook niets. Daarna stopt het voorstel waar die zekerheid wegzakt.
- **Een eigen cache:** de prompt blijft in een eigen key-value-cache staan. Bij de volgende toets snijdt Nook die terug tot het gedeelde begin, zodat het model alleen leest wat nieuw is. Hybride modellen, waarvan de cache niet terug te snijden is, lezen de prompt opnieuw.
- **Jouw woorden:** woorden die je vaak schrijft krijgen een bonus.
- **Andere woorden:** Nook neemt de waarschijnlijkste eerste tokens en spelt elk woord daarna uit.
- **Spaties:** Nook decodeert tokens samen met het laatste token van de prompt. Anders laat de tokenizer de spatie vooraan vallen en plakt een voorstel aan het vorige woord vast.

Een chatantwoord gaat altijd voor: zolang het brein schrijft, toont aanvullen niets. Een chatmodel zet gewone tekst goed voort, maar een GGUF-basismodel is daar het best in.

## Bouwen en testen

Het pakket `LlamaSwift` ([mattt/llama.swift](https://github.com/mattt/llama.swift), vastgezet op 2.10549.0, dat is llama.cpp b10549) staat in `apps/macos/project.yml`. Draai na een `git pull` `xcodegen` zoals gewoonlijk.

De logica zonder AppKit heeft tests in `Tests/NookTests/AutocompleteTests.swift`. Dat zijn `GGUFReader`, `CompletionModels` (ook de modelkeuze), `CompletionSuggestion`, `CompletionPreferences`, `CompletionEmoji`, `CompletionPrivacy` en `CompletionLearning`. Ze draaien ook zonder Xcode met `scripts/core-tests.sh --filter AutocompleteTests`. De engine, het toetsfilter, de veldlezer en de overlay test je alleen op een Mac.

Een deel van het ontwerp en de code komt uit [Typist](https://github.com/BrodySalvucci/Typist) (MIT). Zie `THIRD-PARTY-NOTICES.md`.
