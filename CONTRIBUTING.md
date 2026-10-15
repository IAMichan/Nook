# Meedoen aan Nook

Fijn dat je wilt helpen. Bugs melden, ideeën en pull requests zijn allemaal welkom.

## Lokaal bouwen

```sh
brew install xcodegen
xcodegen
open Nook.xcodeproj
```

Of vanaf de command line:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Voeg je een bestand toe? Draai daarna opnieuw `xcodegen`. Het Xcode-project staat niet in git.

## Opbouw in het kort

- `AppModel` is alleen de samenstelling; elk onderdeel staat in een eigen `AppModel+….swift` (chat, plannen, voice, kaarten, agents, accounts, …). Nieuwe logica hoort in een eigen type of extensie, niet in `AppModel.swift`.
- Chat, kaarten en Meedenken gebruiken dezelfde `prepareRun`. Maak geen tweede pad naar het brein.
- Een nieuwe koppeling beschrijft zichzelf (`SourceCatalog.register`: bron, tools, aliassen, intenties). Je hoeft geen tabellen te bewerken.
- Elke tekst voor de gebruiker gaat door `tr("sleutel")` en staat in alle drie de talen (nl/en/de). `I18nCoverageTests` faalt als een taal een sleutel mist of als de plaatshouders (`%@`, `%ld`) niet gelijk zijn.
- Geheimen gaan via `SecretStore` (alias `Keychain`), nooit in een bestand of in `UserDefaults`.

## Tests

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:NookTests test
```

De kern (bronkeuze, acties, tool-loop, sessieregister, vertalingen) gebruikt alleen Foundation en is ook zonder Xcode te testen met een Swift-toolchain; de UI en alles met AppKit draait alleen op macOS (CI).

## Pull requests

- Houd een PR klein en gericht op één onderwerp.
- De build in GitHub Actions moet groen zijn.
- Volg de stijl van de code eromheen. De UI-teksten zijn in het Nederlands.
- Iets wat namens de gebruiker iets uitvoert (agenda, mail, shell, systeeminstellingen), loopt altijd via een kaart die de gebruiker zelf bevestigt. Er komt ook een regel in het `audit`-logboek.
- Behandel tekst van buiten (scherm, agenda, tool-uitkomsten, hooks) als onbetrouwbare data, niet als instructies.

## Issues

Gebruik de sjablonen voor bugs en ideeën. Een beveiligingsprobleem meld je **niet** in een openbaar issue; zie [SECURITY.md](SECURITY.md).
