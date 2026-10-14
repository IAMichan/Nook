---
name: update-nook
description: Haal de nieuwste versie van Nook van GitHub (IAMichan/nook) binnen, voeg hem veilig samen met de lokale werkmap, genereer het Xcode-project opnieuw en controleer dat het bouwt. Gebruik wanneer de gebruiker zegt "update Nook", "haal de nieuwste versie op", "pull main" of vraagt of lokaal bij is met GitHub.
---

# Nook bijwerken vanaf GitHub

Werk in de Nook-repo (de map met `project.yml`). Antwoord in het Nederlands. Wees eerlijk over wat wel en niet gelukt is.

## Stappen

1. **Controleer waar je staat**
   - `git branch --show-current` en `git status --short`.
   - Staat de gebruiker niet op `main`, vraag dan of die op `main` wil bijwerken of de huidige branch wil bijwerken met `main`. Ga niet zelf van branch wisselen met onopgeslagen werk.

2. **Haal op**
   - `git fetch origin`
   - Toon wat er nieuw is: `git log --oneline HEAD..origin/main`. Is dat leeg, meld dan dat lokaal al bij is en sla stap 3 en 4 over.

3. **Bescherm lokaal werk**
   - Zijn er lokale wijzigingen (`git status --short` niet leeg): maak eerst een stash met een duidelijke naam, bijvoorbeeld `git stash push -u -m "voor-update-<tijd>"`.
   - Verwijder of overschrijf nooit lokale wijzigingen zonder dat de gebruiker dat vraagt. Geen `reset --hard`, geen `checkout .`, geen `clean`.

4. **Voeg samen**
   - Op `main`: `git merge --ff-only origin/main`. Lukt dat niet (lokale commits die niet op GitHub staan), stop dan en leg het uit. Doe niet zelf een merge of rebase zonder akkoord.
   - Op een andere branch: `git merge origin/main`.
   - Haal de stash terug met `git stash pop`. Bij conflicten: toon welke bestanden, los ze alleen op als het duidelijk is, en vraag anders de gebruiker.

5. **Genereer het project opnieuw**
   - `Nook.xcodeproj` staat niet in git en wordt gemaakt door XcodeGen. Draai na elke update `xcodegen generate` (nieuwe of verwijderde bestanden komen er anders niet in).

6. **Controleer de build**
   - `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build 2>&1 | grep -E "error:|BUILD"`
   - Meld `BUILD SUCCEEDED` of de fouten letterlijk. Los fouten niet ongevraagd op.

7. **Rond af**
   - Noem de commit waar lokaal nu op staat (`git log --oneline -1`), de belangrijkste nieuwe commits, en of er een stash is blijven staan.
   - Zeg dat Xcode het project opnieuw geopend moet worden (eerst afsluiten met ⌘Q) en dat een draaiende Nook eerst gestopt moet worden voor ⌘R.

## Let op

- Nook is een menubalk-app zonder venster of Dock-icoon. Een draaiende app betekent niet dat er iets te zien is; zoek het icoon in de menubalk.
- Niet pushen, niet committen en geen branches verwijderen, tenzij de gebruiker dat vraagt.
