# Wat Nook leert van Coucou

> **English summary:** a code-level comparison of Coucou (github.com/Louis-CFM/coucou, the open-source notch companion
> by Louis Raillé) with Nook, focused on the chat: attachments and vision, screen reading, integrations, local models
> and voice. Lists what this change adds (images for brains that can see, ask about a part of the screen, a keyless
> weather tool, a voice-recognition language that follows the settings, the best installed voice, Ollama keep-alive and
> model lists without embedding models, WhatsApp live through a local gateway: new messages in the notch, answering and
> sending after approval) and a plan for the rest (Apple Intelligence as a brain, Parakeet, multi-language dictation,
> dictate anywhere, a notetaker, attach a window).

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
| Wake word | "OK Coucou": energie-VAD (adaptieve drempel), herkenning pas als iemand praat, < 1 % CPU, pauze bij vergrendeld scherm. | "Hé Nook" via SFSpeech. | Coucou zuiniger → overgenomen |
| Spraakopdrachten | `IntentParser` (deterministisch, FR/EN, 60+ zinnen getest), `EntityResolver` (aliassen, Levenshtein ≤ 2), `ConversationContext` ("en nu Stripe", "maak ongedaan"), Foundation Models als terugval. | `LocalIntent`, `ChatIntent` (nl/en/de), daarna het brein. | Gelijkwaardig; Coucou's vervolgopdrachten zijn slimmer |
| Gesprekken opnemen | Notetaker: microfoon + systeemgeluid, geen bot, Parakeet + diarisatie (wie zegt wat), samenvatting en to-do's, audio daarna gewist. | Niet aanwezig. | **Coucou** |
| WhatsApp | Lezen én **versturen** via een lokale gateway (GOWA/OpenWA), webhook op 127.0.0.1 met HMAC, max 6 per minuut, alleen in bestaande chats. | Alleen-lezen uit de database (Volledige schijftoegang). | **Coucou** → overgenomen |
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

### 6. WhatsApp live: lezen, antwoorden en versturen (Coucou's WhatsApp-koppeling)

WhatsApp heeft geen officiële API voor een eigen account. Coucou praat daarom met een **koppeling op je eigen Mac**
(GOWA of OpenWA), die WhatsApp ziet als een gekoppeld apparaat, net als WhatsApp Web. Nook doet nu hetzelfde
(`Services/WhatsApp/`, de protocollen en het geheugenmodel overgenomen uit Coucou onder de MIT-licentie):

* **Instellen.** Instellingen › Accounts & koppelingen › **WhatsApp live** › *WhatsApp koppelen*, dan *Installeren*:
  Nook haalt GOWA van GitHub (de release voor jouw Mac), controleert de SHA-256 met de controlesom die GOWA publiceert
  (zonder controlesom installeert Nook niets), en start het alleen op 127.0.0.1. Daarna scan je de QR-code met WhatsApp
  › Gekoppelde apparaten. Liever OpenWA of een eigen GOWA? Kies het bij *Geavanceerd*, met adres en wachtwoord of sleutel
  (in de Sleutelhanger).
* **Nieuwe berichten in de notch.** Een kaart met de chat, de laatste regels en een veld: typ je antwoord en druk op
  Return, dan gaat het naar die chat. Of *Laat Nook antwoorden*: Nook leest de chat en stelt een antwoord voor als plan.
  *Gelezen* stuurt de leesbevestiging; *Niet meer tonen* verbergt de chat. Groepen blijven stil tenzij iemand je noemt.
* **In de chat.** "Heb ik nieuwe WhatsApps?", "wat schreef Lisa?" gebruiken `whatsapp_live` (live via je telefoon, ook
  wat net binnenkwam). "App Lisa dat ik 10 minuten later ben" of "stuur via WhatsApp aan Jan…" wordt een plan met
  `whatsapp_send`: je ziet ontvanger en tekst, en pas na **Uitvoeren** gaat het weg (ChatIntent herkent dit als bericht,
  niet als mail).
* **Grenzen, zoals bij Coucou.** Alleen naar chats die op je telefoon staan (nooit een nieuw nummer: een verkeerde gok mag
  geen vreemde bereiken), hoogstens 6 berichten per minuut, maximaal 4.096 tekens. Twee chats met dezelfde naam ("Jan")?
  Dan vraagt Nook welke.
* **Privacy.** Berichten staan alleen in het geheugen (de laatste 20 per chat, de afgelopen 12 uur bij het koppelen) en
  nooit op schijf of in een logboek; uitzetten of afsluiten wist alles. Nieuwe berichten komen binnen via een webhook die
  alleen op 127.0.0.1 luistert en elk bericht met een HMAC-SHA256-handtekening controleert; zonder webhook kijkt Nook elke
  20 seconden. Geen verzoek volgt een redirect: alles gaat naar de koppeling en nergens anders. *Alleen op deze Mac* voor
  WhatsApp (Instellingen › Brein) geldt ook hier: een externe AI ziet je chats dan niet.

Het lezen van WhatsApp op je Mac (de database, met Volledige schijftoegang) blijft bestaan voor de hele geschiedenis.

Tests: `Tests/NookTests/WhatsAppTests.swift` (gesprekken, webhook-handtekening, GOWA- en OpenWA-berichten, ontvangers,
snelheidslimiet) en `Tests/NookTests/CoucouLessonsTests.swift` (weer: plaats, voorspelling, tekst; afbeeldingen: JPEG/PNG, de drie
berichtformaten, herkennen van beeldbestanden; modellijsten).

### 7. Overal dicteren (Flow)

Houd rechter ⌥ vast (of ⌘, ⌃, fn: Instellingen › Stem & geluid › Overal dicteren), praat, laat los: de tekst staat waar
je typt, in elke app, en je klembord krijgt terug wat erop stond. Twee keer tikken is handsfree, Esc annuleert, ⌃⌘V plakt
de laatste nog eens. Een pilletje onderaan het scherm laat zien dat Nook luistert, met je woorden live.

* **Beter dan Coucou:** het opschonen (eh's, herhalingen, "om 3 uur, nee 4 uur" → "om 4 uur"), de promptmodus voor agents
  en vertalen doet **je eigen brein**, dus standaard op je Mac (ingebouwd model, Ollama, LM Studio of Apple
  Intelligence). Coucou heeft daarvoor een Claude-sleutel nodig. Een antwoord dat geen opschoning is, wordt weggegooid.
* Luistert in je talen tegelijk (tot drie herkenners on-device; de winnaar van de vorige keer eerst).
* Woordenboek, vervangingen en snippets in één veld ("cloud code => Claude Code", "handtekening :: Groet,\nMichan").
* Stijl per app: terminals en editors letterlijk, mail netjes, de rest natuurlijk.
* Statistieken (woorden, woorden per minuut, tijd bespaard, dagen op rij) en geschiedenis, alleen op deze Mac.

### 8. Gesprekken opnemen (Notetaker)

⌥⌘R, de menubalk of **+** in de chat. Nook neemt je microfoon en het geluid van de Mac op (geen bot in de call), schrijft
het transcript terwijl je praat, haalt de echo van de anderen uit jouw kant, en maakt daarna een samenvatting, kernpunten
en to-do's met je eigen brein. De notitie verschijnt als nieuwe Nook in de chat, met "Zet de to-do's in mijn
Herinneringen" en "Schrijf een mail met deze samenvatting".

* **Beter dan Coucou:** de audio komt **nooit op schijf** (elk stuk wordt meteen op de Mac getranscribeerd en vergeten), en
  je gesprekken zijn een bron voor de chat: "wat spraken we af met Lisa?", "welke to-do's kwamen uit de call van
  vanochtend?" (`search_call_notes`, `read_call_note`).
* Coucou onderscheidt de andere sprekers onderling (Parakeet + diarisatie); Nook nog niet: het is "Ik" en "De anderen".

### 9. Apple Intelligence als brein

Op macOS 26 met Apple Intelligence aan: kies het bij Instellingen › Brein of in de modelchip. Niets te downloaden. Een
eigen klein profiel (4k venster, vijf tools), tools via één JSON-object door de gedeelde controle (ActionGate), het
antwoord live. Werkt ook voor Flow en gespreksnotities. Coucou gebruikt dit model alleen voor spraakopdrachten.

### 10. Schermdeel: plakken en annoteren

Na ⌥⌘4 kies je: **Vraag Nook**, **Plak in** de app waar je was (⌃V in een terminal zodat Claude Code het beeld pakt; daarna
krijgt je klembord terug wat erop stond), **Kopiëren** of **Annoteren** (pijl, kader, pen, vier kleuren, ⌘Z).

### 11. Voorlezen zin voor zin, meertalig inspreken

Een ingesproken vraag wordt beantwoord terwijl het antwoord geschreven wordt, zin voor zin, zonder opmaak, links of
bronnummers. Staat de antwoordtaal op "Taal van mijn vraag", dan luistert Nook in je talen tegelijk.

### 12. Instelbare sneltoetsen

Instellingen › Overzicht: elke globale toets (praten, chat, scherm, schermdeel, opnemen) aanpasbaar of uit te zetten.
Eén toets doet één ding.

### 13. Ongedaan maken en vervolgopdrachten

"Maak ongedaan" (of "undo", "rückgängig") maakt het laatste wat Nook deed weer ongedaan: een afspraak of herinnering
wordt verwijderd, een open eindje afgevinkt. Wat bij elkaar hoort (één plan, binnen twee minuten) gaat in één keer. Ook
dit gaat als plan met Uitvoeren. Na elk uitgevoerd plan staat er een knop *Maak ongedaan* klaar.

### 14. Vage namen

Een naam die bijna klopt ("Viersel" → Vercel, "Spotfy" → Spotify, "Lissa" → Lisa in WhatsApp) wordt gevonden met
Levenshtein-afstand, net als Coucou's `EntityResolver`, zodat een ingesproken naam niet precies hoeft te kloppen. Apps
openen zoekt daarnaast in de geïnstalleerde apps.

### 15. De Mac zelf als bron

Bron *Deze Mac*: "waarom is mijn Mac traag?", "hoe vol is mijn schijf?", "hoe vol is mijn batterij?". De tool
`mac_status` leest processor, geheugendruk, schijf, batterij, warmte en de zwaarste apps, alles op deze Mac.

### 16. Zuiniger wake word

"Hé Nook" luistert nu eerst met een energie-VAD (adaptieve drempel, overgenomen uit Coucou). Pas als iemand praat
start de spraakherkenning, met een halve seconde terug zodat het begin van het woord niet wegvalt. Bij een vergrendeld
scherm, slaapstand of energiebesparing pauzeert hij helemaal.

### 17. Nook op een venster slepen

Sleep het figuurtje met ⌥ ingedrukt op een venster: het venster licht op, en bij loslaten krijgt de chat een beeld van
dat venster als context, net als bij Coucou.

### 18. Parakeet en sprekerherkenning

Instellingen › Stem en geluid › Parakeet: download eenmalig (±650 MB) NVIDIA's Parakeet en een sprekerherkenner (via
FluidAudio, Apache-2.0). Daarna gebruiken Flow en de Notetaker Parakeet: nauwkeuriger, 25 talen, helemaal offline op de
Neural Engine. In gesprekken worden de anderen uit elkaar gehouden ("Persoon 2", "Persoon 3"). Hun geluid blijft
daarvoor alleen in het geheugen en raakt nooit de schijf. Uit te zetten of te verwijderen; dan weer de herkenning van
de Mac. Alleen op Apple silicon.

### 19. Meer interfacetalen

Naast Nederlands, Engels en Duits nu ook **Frans** en **Spaans** (Instellingen › Weergave). Een nieuwe Mac in het
Frans of Spaans begint meteen in die taal. Wat nog niet vertaald is, valt terug op het Engels. Een test houdt alle vijf
gelijk (elke tekst bestaat in elke taal, met dezelfde %@ en %ld).

## Wat nog volgt

* Telefoon-apps (Coucou heeft iPhone en Android): buiten deze repository.
* Nog meer interfacetalen (Coucou heeft er tien). De tabellen staan klaar; een nieuwe taal is één blok in
  `Core/I18n+Languages.swift`.

## Wat Nook niet overneemt

* **Één gesprek zonder tools.** Coucou's chat is een gewone chat; Nooks bronnen, plannen en verwijzingen blijven.
* **Mail versturen vanuit een spraakopdracht zonder plan.** Coucou opent een mailkaart; Nook blijft bij het plan met
  Uitvoeren. Hetzelfde principe, Nooks vorm.
* **Bestandsnamen naar de cloud zonder inhoud.** Coucou stuurt bij niet-Claude-aanbieders alleen de bestandsnaam; Nook
  stuurt de inhoud (en nu het beeld) naar het brein dat je koos, en houdt zich aan *Alleen op deze Mac*.
