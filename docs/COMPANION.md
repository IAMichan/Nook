# Nook Companion (iPhone)

Een kleine iPhone-app die laat zien welke Agents-sessies jou nodig hebben, en waarmee je kunt **goedkeuren, antwoorden, een bericht sturen en stoppen**. Ze praat rechtstreeks met Nook op je Mac via je eigen wifi; er is geen server van ons tussen.

## Koppelen

1. Mac: Instellingen › Agents › Werkruimte › **iPhone-metgezel** aan, dan **Koppel een iPhone**. Nook toont een QR-code (en een link `nook://pair?…`) die vijf minuten en één keer geldt.
2. iPhone: open Nook Companion en scan de code (of plak de link).
3. De eerste aanvraag bewijst dat de telefoon de sleutel heeft; de Mac bewaart het toestel (sleutel in de Keychain). Ontkoppelen = de sleutel verwijderen, aan beide kanten.

## Beveiliging

- De sleutel (32 willekeurige bytes) reist alleen via de QR-code, nooit over het netwerk.
- Elk bericht is verzegeld met ChaCha20-Poly1305 (sleutel via HKDF uit de koppelsleutel; toestel-id en richting zitten in de geauthenticeerde data). Wie meeluistert op het wifi ziet geen titels of commando’s en kan niets veranderen of namaken.
- Een aanvraag heeft een tijdstempel (maximaal 60 s verschil) en een uniek id; de Mac weigert oude en herhaalde aanvragen (`RequestGuard`) en begrenst tot 120 per minuut per toestel. Maximaal 8 gelijktijdige verbindingen, 256 KB per bericht, 30 s per verbinding.
- Wat de telefoon mag (`CompanionPolicy`): weigeren altijd; **toestaan alleen als het laag risico is** (bestanden lezen/bewerken, of een shell-commando dat `CommandRisk` als veilig beoordeelt). Alles daarbuiten (onbekende of gevaarlijke commando’s, web, MCP-tools) kan alleen op de Mac. Een vraag met meerdere onderdelen beantwoord je ook op de Mac.
- Elke actie vanaf de telefoon staat in het auditlogboek (`companion_allow`, `companion_deny`, `companion_answer`, `companion_send`, `companion_stop`, `companion_paired`).
- Een bericht van de telefoon is jouw eigen bericht (het toestel is gekoppeld door jou); tekst die agents of webpagina’s opleveren blijft data.

## Grenzen (bewust)

- Alleen in hetzelfde lokale netwerk (of via een VPN zoals Tailscale als je het adres van de Mac daarin gebruikt; de koppelcode bevat de hostnaam `….local`).
- Geen pushmeldingen: de app ververst elke 5 seconden terwijl ze open is. Pushmeldingen vragen een server en een Apple-certificaat; dat is een aparte stap.
- De Mac luistert alleen als de metgezel aanstaat.

## Waar zit het

- Gedeeld: `Companion/Shared/CompanionModels.swift` (protocol, framing, regels; getest in `CompanionModelsTests`), `CompanionSeal.swift` (CryptoKit).
- Mac: `Services/Companion/CompanionServer.swift` (NWListener + Bonjour `_nookcompanion._tcp`), `CompanionStore.swift` (toestellen, koppelvenster), `App/Settings/CompanionSettings.swift`.
- iPhone: `Companion/iOS/` (target `NookCompanion` in `project.yml`).
