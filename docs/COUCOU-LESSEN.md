# Wat Nook leert van Coucou

> **English summary:** a code-level comparison of Coucou (github.com/Louis-CFM/coucou, the open-source notch companion
> by Louis Raillé) with Nook, focused on the chat: attachments and vision, screen reading, integrations, local models
> and voice. Lists what this change adds (images for brains that can see, ask about a part of the screen, a keyless
> weather tool, a voice-recognition language that follows the settings, the best installed voice, Ollama keep-alive and
> model lists without embedding models) and a plan for the rest (Apple Intelligence as a brain, Parakeet, multi-language
> dictation, dictate anywhere, a notetaker, WhatsApp sending, attach a window).

Coucou en Nook lijken op elkaar: allebei een figuurtje in de notch, allebei agents volgen, allebei een chat. Maar ze zijn
anders gebouwd. Nooks chat is op veel punten al verder (bronnen, bewijs, plannen, lokale modellen die zelf zoeken).
Coucou is sterker in **zien** (beelden en schermdelen naar het brein), **spraak** (dicteren overal, Parakeet, stemmen,
wake word met VAD) en een paar **koppelingen** (WhatsApp versturen, weer, Spotify). Dit document zet het naast elkaar,
zegt wat nu is overgenomen en wat de volgende stappen zijn.

Alles hieronder is gelezen in de broncode van Coucou (`NotchBuddy/Sources/App`, `docs/SPEC.md`,
`docs/INTEGRATIONS.md`, `docs/VOICE.md`), niet in de README alleen.

## Naast elkaar

| Onderwerp | Coucou | Nook (voor deze wijziging) | Wie is verder |
|---|---|---|---|
| Chatbrein | Claude (met web_search), Gemini, OpenAI, DeepSeek, Qwen, Moonshot, Ollama, LM Studio. Één gesprek per keer, geen tools in de chat. | 13 aanbieders + ingebouwd MLX-model, tool-lus, plannen met goedkeuring, bronnen en verwijzingen, QueryPlanner, Research, Grounding. | **Nook** |
| Bestand vragen | PDF als `document`-blok, afbeelding als `image`-blok naar Claude, tekst ≤ 200 KB inline. Lokaal: tekst tot 24.000 tekens. | Alles wordt platte tekst (`FileText.read`). **Afbeeldingen konden niet**: "I cannot read text from…". | **Coucou** → overgenomen |
| Schermdeel | ⌘⇧S: `screencapture -i`, Mochi "slikt" het, knoppen Plakken (⌘V of ⌃V in een terminal), Kopiëren, Annoteren (pijl, kader, pen), Vraag het Claude. | Alleen OCR van hele vensters (⌥⌘N, Meedenken, "op mijn scherm"). | **Coucou** → deels overgenomen |
| Venster als context | Sleep Mochi op een venster: halo, screenshot (1568 px), URL van het tabblad via AppleScript. | OCR van alle vensters, browser-tabs als bron. | Gelijk; Coucou's gebaar is leuker |
| Lokale modellen | Ollama/LM Studio via `/v1/chat/completions`, `<think>` verbergen, embed-modellen uit de lijst, duidelijke fouten ("Ollama draait niet"). Apple Intelligence (Foundation Models) voor spraak, met `@Generable`-tools. | MLX ingebouwd, Ollama `/api/chat` met `num_ctx`, LM Studio, ModelAdvisor, LocalEval, ChatIntent, fill-in. Geen Apple Intelligence; embed-modellen konden gekozen worden; Ollama laadt na 5 min uit. | **Nook**, behalve Apple Intelligence |
| Dicteren in de chat | `MacDictation`: tot drie herkenners tegelijk (je talen), wint die met het meeste vertrouwen; rechtsklik kiest een vaste taal. | Eén herkenner, **vast op nl-NL**. | **Coucou** → deels overgenomen |
| Overal dicteren | Flow: houd een toets (rechter ⌥, fn…), praat, laat los: tekst wordt geplakt waar je typt, klembord terug. Parakeet (NVIDIA, Neural Engine, 25 talen, offline). Woordenboek, vervangingen, snippets, opschonen per app, promptmodus. | Niet aanwezig. | **Coucou** |
| Stem | `VoiceSpeaker`: beste geïnstalleerde stem (Premium > Enhanced), geslacht kiesbaar, zin-voor-zin voorlezen terwijl het antwoord binnenkomt, optioneel ElevenLabs. | `AVSpeechSynthesisVoice(language:)`: de standaard (vaak compacte) stem, eerste 600 tekens. | **Coucou** → deels overgenomen |
| Wake word | "OK Coucou": energie-VAD (adaptieve drempel), herkenning pas als iemand praat, < 1 % CPU, pauze bij vergrendeld scherm. | "Hé Nook" via SFSpeech. | Coucou zuiniger |
| Spraakopdrachten | `IntentParser` (deterministisch, FR/EN, 60+ zinnen getest), `EntityResolver` (aliassen, Levenshtein ≤ 2), `ConversationContext` ("en nu Stripe", "maak ongedaan"), Foundation Models als terugval. | `LocalIntent`, `ChatIntent` (nl/en/de), daarna het brein. | Gelijkwaardig; Coucou's vervolgopdrachten zijn slimmer |
| Gesprekken opnemen | Notetaker: microfoon + systeemgeluid, geen bot, Parakeet + diarisatie (wie zegt wat), samenvatting en to-do's, audio daarna gewist. | Niet aanwezig. | **Coucou** |
| WhatsApp | Lezen én **versturen** via een lokale gateway (GOWA/OpenWA), webhook op 127.0.0.1 met HMAC, max 6 per minuut, alleen in bestaande chats. | Alleen-lezen uit de database (Volledige schijftoegang). | Coucou voor versturen |
| Weer | Open-Meteo, geen sleutel, 15 min cache. | Via web zoeken (onbetrouwbaar voor kleine modellen). | **Coucou** → overgenomen |
| Diensten | GitHub, Vercel, Stripe (omzet vandaag), Resend, n8n, Notion, Cal.com, crypto-portfolio, Spotify. | Dezelfde plus Notion/Linear/Sentry via OAuth-MCP, eigen bronnen, MCP-servers, accounts. | **Nook** |
| Privacy | Geen telemetrie, Keychain `WhenUnlockedThisDeviceOnly`, alleen bestanden in Downloads/Bureaublad/Documenten. | Geen telemetrie, Keychain, alleen-op-deze-Mac-bronnen, `UntrustedText`, `ActionGate`, `NetworkGuard`. | **Nook** |

## Wat deze wijziging toevoegt

### 1. Afbeeldingen naar het brein (zoals Coucou's `readFileAsBlock`)

Sleep een foto, screenshot of scan op de chat, of kies hem met **+ › Bestand toevoegen**. Nook:

* verkleint hem op de Mac tot maximaal 1568 px (de grootte die Claude volledig leest; groter kost alleen tijd en tokens),
  als JPEG, of PNG als het plaatje transparant is (`Brain/ChatImage.swift`);
* leest de tekst erin met Vision (dezelfde OCR als het scherm) en geeft die aan **elk** brein, ook het ingebouwde model;
* geeft het plaatje zelf aan breinen die kunnen zien: Claude (`image`-blok vóór de tekst), alle OpenAI-compatibele
  aanbieders en LM Studio (`image_url` als data-URL), Ollama (`images` naast de tekst, voor Gemma 3, Qwen 2.5 VL,
  Llama 3.2 Vision…);
* weigert een model zonder ogen het verzoek, dan antwoordt Nook gewoon opnieuw uit de herkende tekst
  (`BrainService.execute`). Je krijgt dus nooit een fout omdat je model geen beelden kan lezen.

Het ingebouwde MLX-model en Claude Code krijgen alleen de tekst.

### 2. Vraag over een schermdeel (Coucou's ⌘⇧S)

**⌥⌘4**, of **+ › Vraag over een schermdeel**: de notch klapt in, je sleept een kader (spatie kiest een venster, Esc
annuleert), en het stuk scherm staat als afbeelding in de chat. Daarna geldt alles van punt 1. De selectie is die van
macOS zelf (`screencapture -i -x -o`); het plaatje blijft in een tijdelijke map op je Mac (de tien nieuwste) en gaat pas
naar een brein als je er een vraag over stelt. Zonder toestemming voor Schermopname zegt Nook waar je die aanzet.

### 3. Het weer, zonder sleutel (Coucou's `WeatherSource`)

Nieuwe lees-tool `get_weather` (bron *Web*): het weer nu en tot 7 dagen vooruit van Open-Meteo, met temperatuur,
regenkans, neerslag en wind (`Brain/Weather.swift`). Zonder plaats gebruikt Nook de stad van de tijdzone van je Mac
(Europe/Amsterdam → Amsterdam), zonder locatietoestemming. Een vraag over het weer krijgt deze tool altijd vooraan
(`ChatIntent`), zodat ook een klein lokaal model exacte cijfers geeft in plaats van ze uit zoekresultaten te raden.

### 4. Lokale modellen

* **Ollama blijft geladen.** Ollama gooit een model na 5 minuten uit het geheugen; op een Mac met 24 GB of meer houdt
  Nook het 30 minuten vast (`keep_alive`), zodat een vervolgvraag niet eerst op het laden wacht.
* **Geen embed-modellen meer in de lijst.** `nomic-embed-text`, `bge-m3`, `whisper`, `tts`, `dall-e`… kunnen niet chatten
  maar stonden wel in de keuzelijsten van Ollama, LM Studio en de cloud-aanbieders. `AIProvider.isChatModel` haalt ze
  eruit, ook uit de lokale aanbevelingen.

### 5. Spraak

* **De herkenning volgt je taal.** Was vast Nederlands; nu de taal waarin Nook antwoordt, of bij "Taal van mijn vraag" de
  taal van Nooks interface, met de regio van je Mac als die erbij past (nl-BE, en-GB) (`VoiceService.locale`).
* **De mooiste stem die je hebt.** Voorlezen kiest de beste geïnstalleerde stem: Premium, dan Verbeterd, dan de
  standaard, nooit een grapstem of je Persoonlijke stem (`SpeechOutput.bestVoice`). Download een Premium-stem bij
  Systeeminstellingen › Toegankelijkheid › Gesproken materiaal › Systeemstem › Beheer stemmen.

Tests: `Tests/NookTests/CoucouLessonsTests.swift` (weer: plaats, voorspelling, tekst; afbeeldingen: JPEG/PNG, de drie
berichtformaten, herkennen van beeldbestanden; modellijsten).

## Wat nog volgt (op volgorde van waarde voor de chat)

### A. Apple Intelligence als brein (macOS 26)

Coucou gebruikt `FoundationModels` (`LanguageModelSession`) als lokaal brein voor spraak, met tools via `@Generable`.
Voor Nook is dit het lokale brein dat **niets hoeft te downloaden**: op elke Mac met Apple Intelligence aan.

* Nieuwe `BrainRuntime.apple`, met `SystemLanguageModel.default.availability` in Instellingen › Brein (Intel-Mac,
  Apple Intelligence uit of taal niet ondersteund: zeg het, kies niets stil).
* Tools: `DynamicGenerationSchema` uit de JSON-schema's van `ToolSpec`, zodat de bestaande `ToolRunner` en `ActionGate`
  gelijk blijven. Het model heeft een venster van ~4k tokens: `ModelProfile` als het kleinste profiel (weinig tools,
  `fillIn` voor acties, Research vooraf doet het zoekwerk).
* `session.prewarm()` bij het openen van de chat (Coucou doet dat bij het wake word); één sessie per Nook zolang hij
  open is (het KV-cache-idee uit CHAT-PLAN fase 4).
* Ook geschikt voor de kleine klussen naast elk brein: QueryPlanner, de samenvatting van een lang gesprek, een mail
  opstellen ("bedank haar voor gisteren"), zoals Coucou's `VoiceBrain.draftMail`.

### B. Dicteren in meerdere talen tegelijk

Coucou's `MacDictation` luistert met maximaal drie herkenners tegelijk (de talen van macOS, je toetsenborden, Engels) en
houdt de uitkomst met het hoogste vertrouwen; de winnaar van de vorige keer staat vooraan. De extra talen luisteren
alleen on-device, zodat audio nooit naar Apple gaat in een taal die je niet sprak. Met een rechtsklik op de microfoon
kies je een vaste taal. Dit lost het tweetalige gebruik op (Nederlands praten, Engelse termen) dat één herkenner mist.

### C. Parakeet, offline en nauwkeuriger

NVIDIA Parakeet via FluidAudio op de Neural Engine: 25 talen, een minuut spraak in een paar honderd milliseconden,
eenmalig ±650 MB. Coucou houdt de modellen in een eigen map en laadt ze vooraf in zodra dicteren aan staat. Voor Nook:
als keuze in Instellingen › Stem & geluid naast de herkenning van de Mac, voor de chat, het wake word en (D).

### D. Overal dicteren (Flow)

Houd een toets vast (rechter ⌥), praat, laat los: de tekst komt waar de cursor staat. Klembord terug na het plakken
(Coucou bewaart alle soorten van het klembord en zet ze na 1,5 s terug als er niets anders gekopieerd is). Twee keer
tikken is handsfree, Esc annuleert, ⌃⌘V plakt de laatste nog eens. Daarbovenop wat Nook al heeft: het gekozen brein
(lokaal!) schoont op ("om 3 uur, nee 4 uur" → "om 4 uur"), met een plausibiliteitscheck: een "opschoning" die veel
langer of korter is dan wat je zei, wordt weggegooid. En een promptmodus voor agents: wat je zegt wordt een
gestructureerde opdracht (doel, context, stappen, klaar als). Vraagt Toegankelijkheid.

### E. Schermdeel: plakken, annoteren

Het tweede deel van Coucou's schermdeel: **Plak in de app waar je was** (⌘V, of ⌃V in een terminal zodat Claude Code
het beeld pakt, klembord daarna terug) en **Annoteren** (pijl, kader, pen, vier kleuren, ⌘Z) voordat je het aan Nook of
een agent geeft. Samen met de Werkruimte: "dit knopje staat scheef, fix het" met het beeld naar de agent.

### F. Nook op een venster slepen

Sleep Nook (de bol) op een venster: een halo om dat venster, een screenshot ervan als afbeelding (punt 1) en, bij Safari,
Chrome, Arc of Brave, de URL van het tabblad. Hetzelfde als schermdeel, maar met één gebaar en zonder kader trekken.

### G. Voorlezen terwijl het antwoord komt

Coucou leest zin voor zin voor zodra een zin af is, in plaats van te wachten op het hele antwoord (en Nook kapt nu af op
600 tekens). Met een korte, gesproken versie van het antwoord: geen markdown, geen lijsten, geen links.

### H. Gesprekken opnemen (Notetaker)

Microfoon + systeemgeluid (ScreenCaptureKit), geen bot in de call, live transcript, daarna Parakeet + diarisatie (wie
zegt wat), samenvatting en to-do's door het gekozen brein (lokaal kan), audio gewist zodra het transcript klaar is.
Correcties die je maakt worden een woordenlijst voor de volgende keer. To-do's worden Nook-open-punten of herinneringen
via het gewone plan (niets zonder jouw klik). Deze notities worden een bron voor de chat ("wat spraken we af met Lisa?").

### I. WhatsApp versturen

Nook leest WhatsApp nu uit de database. Versturen kan via Coucou's route: een lokale gateway (GOWA) die Nook met één klik
installeert (release van GitHub, SHA-256 gecontroleerd), webhook alleen op 127.0.0.1 met HMAC-handtekening, geen
redirects, alleen naar een bestaande chat, maximaal 6 berichten per minuut en altijd als stap in een plan.

### J. Vervolgopdrachten en namen

Coucou's `ConversationContext` begrijpt "en nu voor Stripe" (zelfde actie, ander doel) en "maak ongedaan" (de omgekeerde
actie), en `EntityResolver` vindt "Viersel" als "Vercel" (aliassen, Levenshtein ≤ 2). Voor Nooks `LocalIntent` en de
bronkeuze in de vraag ("zoek in Notie") is dat dezelfde winst.

### K. Kleine dingen

* Een zuiniger wake word: Coucou's `EnergyVAD` start de herkenning pas als iemand praat (< 1 % CPU in stilte) en
  pauzeert bij een vergrendeld scherm en in Energiebesparing.
* Weet Nook een Claude-model niet (`not_found_error`), noem het model en waar je een ander kiest (Coucou doet dat).
* Notch-reacties op de Mac zelf (Coucou's `MachineVitals`: een drukke processor, weinig geheugen, lege batterij) als
  bron voor de chat: "waarom is mijn Mac traag?" → de apps die nu de processor gebruiken.

## Wat Nook niet overneemt

* **Één gesprek zonder tools.** Coucou's chat is een gewone chat; Nooks bronnen, plannen en verwijzingen blijven.
* **Mail versturen vanuit een spraakopdracht zonder plan.** Coucou opent een mailkaart; Nook blijft bij het plan met
  Uitvoeren. Hetzelfde principe, Nooks vorm.
* **Bestandsnamen naar de cloud zonder inhoud.** Coucou stuurt bij niet-Claude-aanbieders alleen de bestandsnaam; Nook
  stuurt de inhoud (en nu het beeld) naar het brein dat je koos, en houdt zich aan *Alleen op deze Mac*.
