# Monorepo

Nook is één repo voor alle platformen. Nu zijn de macOS-app en de iPhone-companion geschreven; de rest heeft een map, een README met de bedoeling, en (voor het gedeelde stuk) een plek in de CI.

```
apps/
  macos/     de huidige app (Swift, AppKit/SwiftUI, XcodeGen) — gebouwd en getest in CI
  ios/       Nook Companion voor iPhone (SwiftUI, XcodeGen) — groeit uit tot de iOS-app
  android/   toekomstige Android-app (nu alleen een README)
  windows/   toekomstige Windows-app (nu alleen een README)
  linux/     toekomstige Linux-app (nu alleen een README)
packages/
  core/      Swift-pakket voor de platformonafhankelijke kern (Foundation-only), nu leeg op een placeholder na
  protocol/  gedeeld protocol tussen apps (Companion-protocol, verzegeling, hashing), gebruikt door macos en ios
docs/        ontwerp en plannen, gelden voor alle platformen
scripts/     hulpscripts (o.a. core-tests.sh)
```

## Regels

- Elke app staat in `apps/<platform>` en heeft zijn eigen build, project en tests. De CI bouwt een app alleen als er iets in zijn map (of in een pakket waar hij van afhangt) verandert.
- Wat meer dan één platform nodig heeft, hoort in `packages/`, niet gekopieerd in een app. Een pakket mag nooit van een app afhangen.
- Een pakket gebruikt alleen Foundation (geen AppKit, UIKit, CryptoKit, Combine) zodat het op Linux, Windows en Android bouwt. Enige uitzondering nu: `CompanionSeal.swift` in `packages/protocol` (CryptoKit), zie de README daar.
- Platformgebonden dingen (notch, menubalk, AppleScript, ScreenCaptureKit, Keychain) blijven in de app van dat platform, achter een protocol dat het pakket definieert.

## Wat er nu staat

- **De macOS-app** is ongewijzigd verplaatst naar `apps/macos`. De paden in `apps/macos/project.yml` zijn onderling hetzelfde gebleven; bouwen gaat vanuit die map (`cd apps/macos && xcodegen`).
- **De iPhone-companion** staat in `apps/ios` met een eigen `project.yml` (`cd apps/ios && xcodegen`). Wat hij met de Mac deelt (protocol, verzegeling, hashing) staat in `packages/protocol`; beide projecten nemen die bestanden rechtstreeks op. Zie [COMPANION.md](COMPANION.md).
- **De portable kern** staat nog in `apps/macos` (`Core/`, `Brain/`, `Services/Workspace/`, …). `scripts/core-tests.sh` bouwt die al op Linux. De volgende stap voor ieder ander platform is deze bestanden naar `packages/core` te verhuizen, zodat de macOS-app er ook gewoon van afhangt.

## Volgorde voor een nieuw platform

1. Verhuis de Foundation-only bestanden van de kern naar `packages/core`. Laat `apps/macos` er via Swift Package Manager van afhangen en kijk dat CI groen blijft.
2. Kies de UI-techniek van het platform en zet het project in `apps/<platform>` (zie de README daar).
3. Implementeer de platformdiensten achter de protocollen uit de kern (opslag, geheimen, scherm lezen, agenda, hotkeys).
4. Voeg een eigen CI-job toe in `.github/workflows/`, met een `paths:`-filter op `apps/<platform>/**` en `packages/**`.
5. Zet de platformregel in de README en in `THIRD-PARTY-NOTICES.md` als er nieuwe afhankelijkheden zijn.

## Open keuzes

- **UI-techniek per platform.** De kern is Swift, en Swift draait op Linux, Windows en Android. Dan kan de kern gedeeld worden. De UI is per platform: SwiftUI op iOS, Jetpack Compose op Android, WinUI/WPF of een Swift-UI-laag op Windows, GTK/Qt op Linux. Hier is nog niets gekozen.
- **Het lokale model.** De MLX-pakketten bestaan alleen voor Apple Silicon. Andere platformen hebben een andere lokale runtime nodig (bv. llama.cpp) of gebruiken Ollama/LM Studio/een externe AI.
- **Releasekanalen** (notarisatie, TestFlight, Play Store, MSIX, Flatpak/AppImage) staan hier nog niet in.
