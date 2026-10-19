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
- Acties (goedkeuren, antwoorden) vragen nog steeds dat de telefoon de Mac bereikt; een pushmelding werkt overal waar de telefoon internet heeft, maar de knoppen erin pas als de Mac bereikbaar is.
- De Mac luistert alleen als de metgezel aanstaat.

## Waar zit het

- Gedeeld: `Companion/Shared/CompanionModels.swift` (protocol, framing, regels; getest in `CompanionModelsTests`), `CompanionSeal.swift` (CryptoKit).
- Mac: `Services/Companion/CompanionServer.swift` (NWListener + Bonjour `_nookcompanion._tcp`), `CompanionStore.swift` (toestellen, koppelvenster), `App/Settings/CompanionSettings.swift`.
- iPhone: `Companion/iOS/` (target `NookCompanion` in `project.yml`).

## Pushmeldingen

Nook stuurt ze zelf, zonder server van ons: de Mac ondertekent een verzoek met jouw eigen APNs-sleutel en stuurt het naar Apple (`api.push.apple.com`), die het naar de telefoon brengt.

**Eenmalig instellen (Apple Developer-account):**
1. Zet Push Notifications aan voor de app-id `nl.imdigital.nook.companion` (Certificates, Identifiers & Profiles › Identifiers).
2. Maak een APNs-sleutel (Keys › + › Apple Push Notifications service) en download het `.p8`-bestand. Noteer het sleutel-id en je team-id.
3. Nook › Instellingen › iPhone-metgezel › Pushmeldingen: vul de twee id’s in en importeer het `.p8`-bestand (het gaat naar de sleutelhanger). Met "Stuur testmelding" controleer je alles.
4. Op de iPhone: sta meldingen toe als de app erom vraagt. De app geeft haar token (versleuteld) door aan de Mac.

**Wat je krijgt:** een melding bij toestemming nodig, een vraag, een klare sessie, een mislukte sessie en een bereikte limiet (elk aan/uit), met op de toestemmingsmelding de knoppen *Weiger* (en *Sta toe* als het laag risico is) zonder de app te openen. Het app-icoon toont hoeveel sessies je nodig hebben.

**Regels:** alleen als je niet bij de Mac bent (twee minuten inactief of scherm vergrendeld), stille uren (toestemming en vragen komen desgewenst toch door), en per melding één keer (geen dubbele).

**Privacy:** Apple ziet de tekst. Die noemt standaard alleen de agent en wat er nodig is ("Claude Code · Wacht op jouw toestemming"); de sessietitel staat er alleen in als je dat aanzet. Nooit een commando, bestand of antwoord.

**Let op:** een development-build van de app (Xcode) gebruikt Apple’s sandbox-omgeving, TestFlight/App Store de productie-omgeving; de app meldt dat zelf aan de Mac. Een verlopen of ingetrokken token wordt bij Apple’s antwoord (410) automatisch vergeten.
