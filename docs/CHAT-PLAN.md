# Plan: een Nook-chat die echt doet wat je vraagt (lokaal)

> **English summary:** why the local chat often ignored the question or failed to propose actions, what this change fixes
> (intent recognition before the model runs, intent tools always offered, a focused second try for actions, a sharper
> local prompt with spelled-out dates, streaming for the built-in model and Ollama, Qwen 3 as the default local model),
> and the next phases. Everything runs on the Mac; a cloud model stays an explicit choice.

Uitgangspunt: Nook denkt **op je Mac** (ingebouwd MLX-model, Ollama of LM Studio). Dat kost niets per vraag en er gaat
niets naar buiten. Een lokaal model is kleiner dan een cloudmodel, dus Nook moet het werk zo inrichten dat een klein
model het goed kan doen: minder kiezen, duidelijker vragen, en wat de Mac zelf kan, niet aan het model overlaten.

## Wat er misging

Gevonden in de code (route: `AppModel.answer` → `BrainService.run` → `ToolRunner` / `EmbeddedModel`):

1. **De juiste tool kwam vaak niet mee.** Een lokaal model krijgt 8 tot 14 tools. Welke dat waren, werd bepaald door
   woorden uit je vraag te vergelijken met de Engelse beschrijving van de tools. "Herinner me morgen aan de tandarts" heeft
   geen enkel woord gemeen met "Creates a reminder…", dus `create_reminder` viel er soms af. Dan *kan* het model de actie
   niet voorstellen, hoe goed het ook is.
2. **Het model antwoordde over de context in plaats van over je vraag.** Het lokale prompt zei "Answer from the context
   first" en zette je vraag pas onderaan, ná agenda, mail en scherm. Een klein model gaat dan je agenda samenvatten.
3. **Acties werden "bevestigd" zonder voorstel.** Kleine modellen zeggen vaak "Ik heb het in je agenda gezet!" of
   "Zal ik dat doen?" zonder de tool aan te roepen. Er kwam geen plan, dus er viel niets uit te voeren.
4. **Datums.** "Vrijdag om 3 uur" omzetten naar `2026-10-16T15:00:00+02:00` is rekenwerk waar een 3B-model vaak naast zit;
   `ActionGate` keurt het dan af.
5. **Geen live antwoord.** Het ingebouwde model en Ollama gaven het antwoord pas als alles klaar was. Het voelde alsof
   Nook niet reageerde.
6. **Verouderd standaardmodel.** Qwen 2.5 (2024) was de standaard. Qwen 3 is merkbaar beter in tools en in het Nederlands.

## Fase 1 — in deze wijziging

| Onderdeel | Wat | Waar |
|---|---|---|
| Intentie herkennen | Voordat het model draait, herkent Nook (nl/en/de) wat je vraagt: herinnering, afspraak, verplaatsen, notitie, taak, mail schrijven of lezen, contact, muziek, volume, app, shortcut, grafiek, scherm, browser, bestanden, GitHub, Notion, klembord, web. En of je iets wilt laten *doen* of iets *vraagt*. | `Brain/ChatIntent.swift` |
| Juiste tools altijd mee | De tools van die intentie staan altijd vooraan in de lijst voor het model, wat de woordovereenkomst ook zegt. | `BrainService.prioritized(_:for:limit:preferred:)` |
| Wat je wilt maken wint | "Maak een grafiek van mijn afspraken" is een grafiek, "mail Lisa over de meeting" is een mail, "herinner me aan de call" is een herinnering. | `ChatIntent.priority` |
| Scherper lokaal prompt | "Beantwoord precies wat de gebruiker vraagt; vat de context niet ongevraagd samen." Je vraag staat vóór én na de context. Bij een actie: "roep nu `create_reminder` aan". Nooit beweren dat iets al gedaan is. | `BrainService.localSystemPrompt` |
| Datums uitgeschreven | Het model krijgt de komende 8 dagen met datum en tijdzone ("tomorrow: Friday 2026-10-16", voorbeeld vrijdag 15:00). Geen rekenwerk meer. | `ChatIntent.dateSheet` |
| Gerichte tweede poging | Vroeg je duidelijk om een actie en stelde het model die niet voor, dan vraagt Nook het nog één keer, met **alleen** die tool, de datums en een kort prompt. Vroeg het model om een ontbrekend gegeven ("Hoe laat?"), dan niet; vroeg het om toestemming ("Zal ik…?"), dan wel. | `BrainService.fillIn`, `asksBack` |
| Kleine praat blijft klein | "Hoi" of "bedankt" krijgt geen agenda, mail en scherm mee, zodat het model daar niet over begint. | `BrainService.run` (`lean`) |
| Langer geheugen | Grotere lokale modellen krijgen de laatste 10 beurten (600 tekens) mee in plaats van 6 (300). | `BrainService.run` |
| Live antwoord | Het ingebouwde model en Ollama streamen: je ziet het antwoord verschijnen. Denkblokken en tool-JSON worden nooit getoond. | `EmbeddedModel.stream`, `OllamaConversation` |
| Qwen 3 | Nieuwe standaard: Qwen 3 4B (8 GB), Qwen 3 8B (16 GB), Qwen 3 30B-A3B (32 GB+, mixture of experts: snel als een 4B-model). Het "hardop denken" van Qwen 3 staat uit. Geïnstalleerde oudere modellen blijven werken. | `ModelAdvisor.catalog`, `EmbeddedModel` |
| Tests | Intentieherkenning (nl/en/de, vraag vs. opdracht, prioriteit, kleine praat) en het datumoverzicht. | `Tests/NookTests/ChatIntentTests.swift` |

De uitvoerlaag (plan → controle → Uitvoeren → `PlanRunner`) was al degelijk en blijft gelijk: niets gebeurt zonder je klik.
Het probleem zat ervoor: er kwam geen (goed) voorstel uit.

## Fase 2 — meten in plaats van gokken

* **Evaluatieset van echte vragen.** 150 tot 200 Nederlandse (en wat Engelse) verzoeken met het verwachte resultaat:
  welke tool, welke velden, of het een vraag of actie is. Uitbreiden met elke formulering waar Nook de mist in gaat.
* **Eval-runner op de Mac.** Een los doel (`NookEval`) dat de set door het echte lokale model haalt met nep-tools en scoort:
  juiste tool, geldige velden (via `ActionGate`), juiste datum, geen verzonnen feiten, antwoord in de juiste taal.
  Per model een scorekaart, zodat `toolSkill` in `ModelAdvisor` gemeten is in plaats van geschat.
* **Lokaal duimpje.** 👍/👎 onder een antwoord, alleen lokaal bewaard. Een 👎 met de vraag erbij gaat (met jouw OK) de
  evaluatieset in.

## Fase 3 — betrouwbare acties

* **Datums en tijden door de Mac.** `NSDataDetector` haalt datum en tijd zelf uit de vraag. Wijkt het model daarvan af,
  dan wint wat er letterlijk stond, en zie je dat in het plan.
* **Gestructureerde uitvoer afdwingen.** Bij MLX een grammatica/JSON-schema tijdens het genereren (logit-processor), zodat
  tool-argumenten altijd geldige JSON met de juiste velden zijn. Bij Ollama het `format`-veld met het schema.
* **Meerdere acties in één zin** ("plan een call met Jan en stuur hem een mail"): de intentieherkenning geeft een lijst,
  en de gerichte poging vult ze één voor één in.
* **Ongedaan maken.** Na het uitvoeren van een afspraak, herinnering of notitie een knop **Ongedaan maken** (de id's
  staan al in de uitkomst per stap).

## Fase 4 — sneller en slimmer gesprek

* **Gesprek in het geheugen houden.** Per Nook één `ChatSession` met KV-cache die blijft leven zolang het model geladen
  is. Een vervolgvraag hoeft dan niet het hele gesprek opnieuw te lezen: veel sneller.
* **Samenvatten van oudere beurten** in plaats van afkappen, zodat lange gesprekken hun draad houden.
* **Vervolgvoorstellen ook lokaal.** De »-suggesties onder een antwoord, met een kort apart prompt na het antwoord.
* **LM Studio streamen** (server-sent events op `/chat/completions`), net als Ollama nu.

## Fase 5 — keuze en grenzen

* **Upgrade-aanbod.** Heb je nog Qwen 2.5, dan biedt Nook één keer Qwen 3 aan (download één keer, daarna offline).
* **Bewust opschalen.** Bij een vraag die lokaal echt niet lukt een knop **Vraag het een groter model** die alleen werkt
  als jij een externe AI hebt ingesteld, en alleen voor die ene vraag. Nooit automatisch: de kosten blijven bij jou.

## Hoe je het test

1. `./update.sh` (er is een nieuw bestand: `Brain/ChatIntent.swift`), dan ⌘R.
2. **Instellingen › Brein**: kies het voorgestelde Qwen 3-model (eenmalige download).
3. Probeer in de chat:
   * "Herinner me morgen om 9 uur aan de tandarts" → plan met één herinnering, morgen 09:00.
   * "Zet vrijdag om 15:00 een afspraak met Lisa in mijn agenda" → plan met de afspraak.
   * "Stuur een mail naar Lisa dat ik later ben" → mailconcept in de chat.
   * "Maak een notitie: melk, eieren, brood" → plan met de notitie.
   * "Ben ik vrijdag vrij?" → een antwoord, geen plan.
   * "Hoi" → een korte groet, geen samenvatting van je agenda.
   * Een vervolgvraag: "en zaterdag?" na de vorige.
4. Het antwoord moet verschijnen terwijl het geschreven wordt.
