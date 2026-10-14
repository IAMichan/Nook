# Nook

Je persoonlijke agent in de notch van je Mac.

## Starten

```sh
brew install xcodegen
cd /Users/michanvanderhoek/IMDigital/Code/Applicaties/Nook
xcodegen
open Nook.xcodeproj
```

Druk op ⌘R. Nook heeft geen Dock-icoon: je ziet hem in de notch en als stip in de menubalk.

**Eerste keer**
1. Menubalk-stip → **Instellingen…** → plak je Anthropic API-sleutel (blijft in de Keychain).
2. Zet bij Machtigingen Agenda, Herinneringen, Microfoon en Scherm lezen aan zodra je ze wilt gebruiken.
3. Voor je agents: **Installeer hook-script** en kopieer de configuratie voor Claude Code of Codex.

## Wat het doet

| Wat | Hoe |
|---|---|
| Praten tegen Nook | ⌥ spatie (of de microfoonknop). Herkenning op je Mac; daarna denkt het brein mee. |
| Typen tegen Nook | Veld onderaan de tab Vandaag. |
| Meekijken | ⌥⌘N: leest de tekst van het voorste venster (OCR, lokaal) en stelt iets voor als er een afspraak, belofte of taak in staat. Optioneel automatisch (Instellingen). |
| Agenda, herinneringen | Afspraken en herinneringen maken na jouw "Uitvoeren". |
| Open punten | Nook onthoudt beloftes en taken (lokale database) en toont ze in Vandaag. |
| Muziek | Spotify en Muziek: nu speelt, bediening, Nook danst in de notch. |
| Agents | Claude Code, Codex e.d. via hooks: wie draait, wat doet hij, wie wacht op je. Riskante Bash-commando's komen als vraag in de notch. |
| Besturen | Apps openen, links openen, volume, muziek, Opdrachten (Shortcuts), conceptmail in Mail. |

## Veiligheid

- Niets wordt uitgevoerd zonder dat jij op Uitvoeren/Toestaan drukt. Nook verstuurt zelf nooit mail of berichten.
- Tekst van je scherm, agenda-titels en tool-uitkomsten gaan als "onbetrouwbare data" naar het brein, met de opdracht daar geen instructies uit te volgen.
- De hook-socket is alleen voor jouw gebruiker (rechten 0600 + controle op gebruikers-ID).
- Wachtwoordmanagers worden nooit gelezen. Het schermbeeld zelf verlaat je Mac niet; alleen herkende tekst gaat naar het brein.
- Alles wat Nook uitvoert staat in een logboek (`nook.sqlite`, tabel `audit`).

## Mappen

```
App/       start, menubalk, AppModel (verbindt alles), instellingen
NotchUI/   thema, karakter, kaarten, tabs, venster
Services/  agenda, muziek, agent-hub, stem, scherm lezen, sneltoets, hook-script
Brain/     Claude-koppeling, tools, datums, commando-risico
Core/      paden, instellingen + Keychain, opslag (SQLite)
Demo/      voorbeelddata (menubalk › Voorbeelddata tonen)
```

## Let op

- De code compileert zonder fouten of waarschuwingen (Xcode 16.4, macOS 15); GitHub Actions bouwt hem bij elke push (`.github/workflows/build.yml`). De app is nog niet gestart: machtigingen, de hook-socket en de Claude-koppeling zijn nog niet in de praktijk getest.
- Met ad-hoc ondertekening ziet macOS elke nieuwe build als een andere app: machtigingen en Keychain-toegang kunnen opnieuw gevraagd worden. Met een eigen Developer ID-certificaat verdwijnt dat.
- De hook-opzet voor Claude Code en Codex is gebaseerd op hun documentatie maar niet getest tegen de huidige versies.
- Er is geen API om meldingen van andere apps te lezen; "meldingen filteren" is daarom niet gebouwd. Meldingen van je agents lopen wel via Nook.
- Bundle-ID `nl.imdigital.nook` is een aanname. "Nook" is de werknaam: controleer de merknaam (BOIP/EUIPO) voor een release.
- De naam, het karakter en de geluiden van Coucou zijn niet overgenomen; boring.notch is alleen als inspiratie gebruikt (GPL-3).
