# protocol

Wat de Nook-apps met elkaar delen om te praten: nu het Companion-protocol tussen Mac en iPhone.

```
Sources/
  CompanionModels.swift   berichten, framing en regels (getest in CompanionModelsTests)
  CompanionPush.swift     inhoud van pushmeldingen
  CompanionSeal.swift     verzegeling met ChaCha20-Poly1305 (CryptoKit)
  WebhookSecurity.swift   SHA-256/HMAC zonder CryptoKit, ook voor webhooks op de Mac
```

Dit is (nog) geen Swift-pakket: `apps/macos/project.yml` en `apps/ios/project.yml` nemen de bestanden rechtstreeks op, zodat ze in hetzelfde module zitten en niets `public` hoeft te zijn. Wordt het een pakket, maak de types dan `public` en voeg een `Package.swift` toe.

Houd het platformonafhankelijk. Alleen `CompanionSeal.swift` gebruikt CryptoKit; op Linux, Windows en Android is daar een vervanger nodig (bv. swift-crypto).
