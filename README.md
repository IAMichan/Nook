# Nook

[![Build](https://github.com/IAMichan/nook/actions/workflows/build.yml/badge.svg)](https://github.com/IAMichan/nook/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)

Je persoonlijke agent in de notch van je Mac.

> **English:** Nook is a personal AI agent that lives in the MacBook notch. It listens on request, reads your screen locally (OCR) and proposes calendar events, reminders and tasks, shows what your coding agents (Claude Code, Codex) are doing, and controls music. Nothing runs without your explicit approval. The interface is in Dutch.

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

Druk op ⌘R. Nook heeft geen Dock-icoon: je ziet hem in de notch en als stip in de menubalk.

**De eerste keer**
1. Menubalk-stip → **Instellingen…** → kies bij Brein een Anthropic API-sleutel (blijft in de Keychain) of **Gratis model op je Mac** (ingebouwd, MLX: klik Download, niets anders te installeren).
2. Zet bij Machtigingen Agenda, Herinneringen, Microfoon en Scherm lezen aan zodra je ze wilt gebruiken.
3. Voor je agents: **Installeer hook-script** en kopieer de configuratie voor Claude Code of Codex.

Wil je hem zonder API-sleutel bekijken? Kies in de menubalk **Voorbeelddata tonen**.

## Wat het doet

| Wat | Hoe |
|---|---|
| Praten tegen Nook | ⌥ spatie (of de microfoonknop). Herkenning op je Mac; daarna denkt het brein mee. |
| Typen tegen Nook | Veld onderaan de tab Vandaag. |
| Meekijken | Zeg je "maak er een afspraak voor" of verwijs je naar iets met "hier", "dit" of "daar", dan leest Nook zelf eerst het voorste venster en haalt datum, tijd en plaats eruit. ⌥⌘N: leest de tekst van het voorste venster (OCR, lokaal) en stelt iets voor als er een afspraak, belofte of taak in staat. Optioneel automatisch (Instellingen). |
| Agenda, herinneringen | Afspraken en herinneringen maken na jouw "Uitvoeren". |
| Open punten | Nook onthoudt beloftes en taken (lokale database) en toont ze in Vandaag. |
| Muziek | Spotify en Muziek: nu speelt, bediening, Nook danst in de notch. |
| Agents | Claude Code, Codex e.d. via hooks: wie draait, wat doet hij, wie wacht op je. Riskante Bash-commando's komen als vraag in de notch. |
| Besturen | Apps openen, links openen, volume, muziek, Opdrachten (Shortcuts), conceptmail in Mail. |

## Privacy en veiligheid

- Niets wordt uitgevoerd zonder dat jij op Uitvoeren/Toestaan drukt. Nook verstuurt zelf nooit mail of berichten.
- Wat naar Anthropic gaat: wat je zegt of typt (als tekst), herkende schermtekst als je Nook laat meekijken, en de agenda- en taakgegevens die nodig zijn voor een voorstel. Het schermbeeld zelf verlaat je Mac niet. Spraak wordt bij voorkeur op je Mac herkend; ondersteunt jouw Mac dat niet, dan gebruikt macOS de spraakherkenning van Apple.
- Tekst van je scherm, agenda-titels en tool-uitkomsten gaan als "onbetrouwbare data" naar het brein, met de opdracht daar geen instructies uit te volgen.
- Wachtwoordmanagers worden nooit gelezen.
- De hook-socket is alleen voor jouw gebruiker (rechten 0600 + controle op gebruikers-ID).
- Alles wat Nook uitvoert staat in een logboek (`nook.sqlite`, tabel `audit`).

Een beveiligingsprobleem gevonden? Zie [SECURITY.md](SECURITY.md).

## Mappen

```
App/       start, menubalk, AppModel (verbindt alles), instellingen
NotchUI/   thema, karakter, kaarten, tabs, venster
Services/  agenda, muziek, agent-hub, stem, scherm lezen, sneltoets, hook-script
Brain/     Claude-koppeling, tools, datums, commando-risico
Core/      paden, instellingen + Keychain, opslag (SQLite)
Demo/      voorbeelddata (menubalk › Voorbeelddata tonen)
```

`Nook.xcodeproj`, `Info.plist` en de entitlements worden door XcodeGen gemaakt vanuit [`project.yml`](project.yml) en staan niet in git.

## Bekende beperkingen

- Het ingebouwde gratis model gebruikt de Swift-pakketten mlx-swift-lm, swift-huggingface en swift-transformers. Die vragen Xcode 26 of nieuwer en een Apple Silicon-Mac. De eerste build haalt de pakketten op en duurt lang. Draai `xcodegen` opnieuw na een `git pull`.
- De app is ad-hoc ondertekend. Daardoor ziet macOS elke nieuwe build als een andere app en kunnen machtigingen en Keychain-toegang opnieuw gevraagd worden. Met een eigen Developer ID-certificaat gebeurt dat niet.
- De hooks voor Claude Code en Codex volgen hun documentatie, maar zijn nog niet getest met de huidige versies.
- macOS heeft geen API om meldingen van andere apps te lezen, dus meldingen filteren zit er niet in. Meldingen van je agents lopen wel via Nook.

## Meedoen

Issues en pull requests zijn welkom. Lees eerst [CONTRIBUTING.md](CONTRIBUTING.md).

## Dank

Het idee voor een app in de notch is geïnspireerd door [boring.notch](https://github.com/TheBoredTeam/boring.notch). Er is geen code van overgenomen.

## Licentie

[MIT](LICENSE) © 2026 Michan van der Hoek
