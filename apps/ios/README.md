# Nook voor iOS

Hier staat **Nook Companion**, de iPhone-app die laat zien welke Agents-sessies jou nodig hebben, met goedkeuren, antwoorden, een bericht sturen en stoppen. Hij praat via je eigen wifi met Nook op je Mac; zie [docs/COMPANION.md](../../docs/COMPANION.md).

## Bouwen

```sh
brew install xcodegen
cd apps/ios
xcodegen
open NookCompanion.xcodeproj
```

Kies een iPhone (of simulator) en druk op ⌘R. `NookCompanion.xcodeproj`, `Info.plist` en de entitlements worden gemaakt vanuit [`project.yml`](project.yml) en staan niet in git.

## Opbouw

```
NookCompanion/   de app (SwiftUI): koppelen, sessielijst, acties, pushmeldingen
```

Het protocol, de verzegeling en de hashing deelt hij met de Mac via [`packages/protocol`](../../packages/protocol). Code uit `apps/macos` gebruikt hij niet.

## Volgende stap

De companion groeit hier uit tot een volwaardige iOS-versie van Nook. Wat iOS en de Mac allebei nodig hebben, hoort in `packages/`, niet gekopieerd in deze map.
