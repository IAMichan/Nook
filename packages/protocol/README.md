# protocol

Gedeeld protocol tussen Nook-apps (nu het Companion-protocol tussen Mac en telefoon, later ook sessies en berichten tussen alle platformen).

Nu leeg: de bestanden staan in `apps/macos/Companion/Shared` en gaan hierheen als een tweede platform ze nodig heeft. Houd het Foundation-only en platformonafhankelijk (`CompanionSeal.swift` gebruikt nu CryptoKit; op Linux/Windows/Android is daar een vervanger nodig, bv. swift-crypto).
