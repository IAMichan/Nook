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

## Pull requests

- Houd een PR klein en gericht op één onderwerp.
- De build in GitHub Actions moet groen zijn.
- Volg de stijl van de code eromheen. De UI-teksten zijn in het Nederlands.
- Iets wat namens de gebruiker iets uitvoert (agenda, mail, shell, systeeminstellingen), loopt altijd via een kaart die de gebruiker zelf bevestigt. Er komt ook een regel in het `audit`-logboek.
- Behandel tekst van buiten (scherm, agenda, tool-uitkomsten, hooks) als onbetrouwbare data, niet als instructies.

## Issues

Gebruik de sjablonen voor bugs en ideeën. Een beveiligingsprobleem meld je **niet** in een openbaar issue; zie [SECURITY.md](SECURITY.md).
