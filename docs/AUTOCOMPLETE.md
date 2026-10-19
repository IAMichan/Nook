# Overal aanvullen

Nook kan terwijl je in een andere app typt een vervolg van je zin voorstellen, als grijs blokje naast je cursor. **Tab** typt het in, elke andere toets stuurt het weg. Het model draait op je eigen Mac. Standaard is dat het model dat **Cotypist** al heeft gedownload, zodat je geen tweede kopie nodig hebt.

Aanzetten: **Instellingen › Stem & geluid › Overal aanvullen**.

## Hoe het werkt

1. Een toetsenbordfilter (`CGEventTap`) ziet dat je typt. Na 250 ms rust gaat het verder.
2. `AutocompleteField` leest via de Accessibility-API het veld dat de focus heeft: de tekst vóór de cursor, wat erna staat en waar de cursor op het scherm is. Wachtwoordvelden, terminals en wachtwoordmanagers worden overgeslagen. Staat er tekst achter de cursor, of is er tekst geselecteerd, dan komt er geen voorstel.
3. `LlamaCompleter` laat het GGUF-model via llama.cpp (Metal) de tekst vervolgen: hebzuchtig, één regel, hoogstens 24 tokens en 12 woorden. De vorige prompt blijft in de cache; een extra letter kost bijna niets.
4. `CompletionText.clean` maakt er een voorstel van. `GhostOverlay` tekent het naast de cursor in een paneel dat geen klikken en geen focus aanneemt.
5. Tab wordt door het filter tegengehouden en `AutocompleteTyper` typt het voorstel als Unicode-toetsevents. Het klembord blijft ongemoeid.

De tekst blijft op je Mac: niets wordt bewaard of verstuurd. Een voorstel dat bij oudere tekst hoort (je typte door terwijl het model rekende) wordt weggegooid.

## Het model van Cotypist

Cotypist is gesloten software en beschrijft nergens waar het zijn modellen bewaart. `CompletionModelLocator` zoekt daarom in `~/Library/Application Support`, `Caches`, `Containers`, `Group Containers` en `/Applications` naar mappen met "cotypist" in de naam en neemt elk `.gguf`-bestand daarin (zonder `mmproj`-bestanden). Van elk bestand leest `GGUFReader` de header (naam, architectuur, contextlengte) zonder het model te laden. Het nieuwste bestand wordt gebruikt, tenzij je in Instellingen een ander model kiest.

Nook leest het bestand alleen, op de plek waar het staat: geen kopie en geen wijziging. Staat Cotypists model in een ander formaat of versleuteld, dan herkent Nook het niet; de instelling meldt dan "Geen model gevonden" en je kunt zelf een `.gguf`-bestand kiezen (bijvoorbeeld een kleine Qwen- of Gemma-variant van Hugging Face).

## Bouwen

Het pakket `LlamaSwift` ([mattt/llama.swift](https://github.com/mattt/llama.swift), vastgezet op 2.10549.0 = llama.cpp b10549) zit in `apps/macos/project.yml`. Draai na een `git pull` `xcodegen` zoals gewoonlijk. Nook vraagt daarna toegang tot **Toegankelijkheid**, net als Flow.

## Grenzen

- Een model dat bedoeld is voor een chat-sjabloon werkt hier als gewoon tekstvervolg. Basismodellen en kleine instruct-modellen geven goede resultaten; een groot redeneermodel is te traag.
- Apps die geen cursorpositie via Accessibility geven (sommige Electron- en Chromium-velden zonder ingeschakelde toegankelijkheid) krijgen geen voorstel.
- De logica zonder AppKit (`GGUFReader`, `CompletionModels`, `CompletionText`) heeft tests in `Tests/NookTests/AutocompleteTests.swift`. De engine, het toetsfilter en de overlay zijn alleen op een Mac te testen.
