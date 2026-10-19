# protocol

Shared communication and security primitives across Nook apps—currently the Companion protocol between macOS and iPhone.

```text
Sources/
  CompanionModels.swift   Messages, framing, and policy rules (tested in CompanionModelsTests)
  CompanionPush.swift     APNs push payload formatting and JWT signing helpers
  CompanionSeal.swift     Authenticated encryption with ChaCha20-Poly1305 (CryptoKit)
  WebhookSecurity.swift   Pure-Swift SHA-256 and HMAC verification (no CryptoKit dependency)
```

`apps/macos/project.yml` and `apps/ios/project.yml` compile these source files directly into their respective targets. Keep all files portable (`Foundation`-only), with the sole exception of `CompanionSeal.swift` which uses `CryptoKit` on Apple platforms.
