import Foundation

/// Tools die iets in de chat laten zien: een grafiek of een mailconcept. Ze draaien meteen (zoals lees-tools),
/// want er gebeurt nog niets buiten Nook: een mail gaat pas weg als de gebruiker zelf op "Versturen" klikt.
@MainActor
enum ChatTools {
    static func specs(onChart: @escaping (ChatChart) -> Void, onMail: @escaping (MailDraft) -> Void) -> [ToolSpec] {
        let point: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "Categorie of moment op de x-as, bijvoorbeeld \"ma\", \"jan\" of \"Amsterdam\"."],
                "value": ["type": "number", "description": "De waarde."]
            ],
            "required": ["label", "value"]
        ]
        let series: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Naam van de reeks (voor de legenda)."],
                "points": ["type": "array", "items": point, "description": "De punten, in de volgorde waarin ze getoond worden."]
            ],
            "required": ["name", "points"]
        ]

        return [
            ToolSpec(
                name: "show_chart",
                description: "Tekent een grafiek in de chat. Gebruik dit ALTIJD als de gebruiker om een grafiek, diagram, chart of visualisatie vraagt, en ook uit jezelf als cijfers (over tijd, of tussen een paar categorieën) als grafiek duidelijker zijn. Haal de cijfers eerst op met andere tools of het web als dat nodig is; gebruik alleen echte cijfers of cijfers van de gebruiker, verzin nooit data. Kies bar voor vergelijken, line of area voor verloop in de tijd, pie voor verdeling van een geheel (hooguit 6 delen), point voor losse metingen. Na het tekenen geef je in je antwoord in één of twee zinnen de belangrijkste conclusie; herhaal niet alle cijfers.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Korte titel boven de grafiek."],
                        "type": ["type": "string", "enum": ChatChart.Kind.allCases.map(\.rawValue), "description": "Soort grafiek."],
                        "unit": ["type": "string", "description": "Eenheid van de waarden, bijvoorbeeld \"€\", \"uur\" of \"%\". Optioneel."],
                        "series": ["type": "array", "items": series, "description": "Eén of meer reeksen (hooguit 4 voor lijnen en staven). Bij pie precies één reeks."]
                    ],
                    "required": ["title", "type", "series"]
                ],
                kind: .read,
                summarize: { input in "Grafiek: \((input["title"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    guard let chart = ChatChart.parse(input) else {
                        throw NookError("Geen bruikbare data: geef series met points (label en value).")
                    }
                    onChart(chart)
                    return "De grafiek \"\(chart.title)\" staat nu in de chat bij je antwoord. Beschrijf hem niet opnieuw punt voor punt."
                }
            ),
            ToolSpec(
                name: "compose_mail",
                description: "Schrijft een complete e-mail en toont die als concept in de chat. De gebruiker kan hem daar aanpassen en met één klik versturen of in Mail openen. Gebruik dit ALTIJD als de gebruiker vraagt een mail te schrijven, op te stellen, te beantwoorden of door te sturen. Schrijf de hele mail in body, met aanhef en afsluiting, in de toon en taal die passen bij de ontvanger. Zoek het adres op in de context, op het scherm of met search_mail; ken je het niet, laat to dan leeg en zeg dat in je antwoord. Herhaal de mail niet in je antwoord: zeg in één zin wat je schreef.",
                schema: [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "E-mailadres(sen) van de ontvanger, gescheiden door komma's. Leeg als onbekend."],
                        "cc": ["type": "string", "description": "CC-adressen, optioneel."],
                        "subject": ["type": "string", "description": "Onderwerp. Bij een antwoord: \"Re: \" plus het oorspronkelijke onderwerp."],
                        "body": ["type": "string", "description": "De volledige tekst van de mail, zonder onderwerpregel."]
                    ],
                    "required": ["subject", "body"]
                ],
                kind: .read,
                summarize: { input in "Mail: \((input["subject"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let subject = ((input["subject"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = ((input["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { throw NookError("De inhoud van de mail ontbreekt.") }
                    let draft = MailDraft(
                        to: ((input["to"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        cc: ((input["cc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        subject: subject,
                        body: body
                    )
                    onMail(draft)
                    return "Het mailconcept staat in de chat. De gebruiker controleert het en verstuurt het zelf met de knop Versturen."
                }
            )
        ]
    }
}
