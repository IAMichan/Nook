import SwiftUI

// All content in this file is sample data for previewing the UI.
// In subsequent phases, this will come from real sources (calendar, mail, AgentHub).

/// Scenes that can be invoked via Nook's menu bar icon.
enum DemoScene: String, CaseIterable {
    case idle, music, suggestion, reminder, listening, plan, approval, today, agents

    var title: String {
        tr("scene." + rawValue)
    }
}

// MARK: Content

enum DemoContent {
    static func card(for scene: CardScene) -> NookCard {
        switch scene {
        case .suggestion:
            return NookCard(
                id: "suggestion",
                mood: .seen,
                context: "Mail · Lisa de Vries",
                title: "Koffie met Lisa vrijdag om 14:00. Zal ik het in je agenda zetten?",
                detail: .event(top: "VR", big: "16", line: "14:00 – 15:00 · Café op de hoek", subline: "Werk-agenda · Lisa krijgt een uitnodiging"),
                primary: CardAction(label: "Toevoegen", outcome: .done("Koffie met Lisa staat in je agenda")),
                secondary: CardAction(label: "Niet nu", outcome: .dismiss),
                contentHeight: 180
            )
        case .reminder:
            return NookCard(
                id: "reminder",
                mood: .remind,
                context: "Uit je Slack-bericht · ma 12 okt",
                title: "Volgens mij moet je Tom nog het kwartaalrapport sturen.",
                detail: .event(top: "PDF", big: "Q3", line: "Q3-rapport-definitief.pdf", subline: "Documenten › Atlas · 2,4 MB"),
                primary: CardAction(label: "Mail opstellen", outcome: .done("Concept voor Tom staat klaar in Mail")),
                secondary: CardAction(label: "Morgen", outcome: .dismiss),
                contentHeight: 180
            )
        case .listening:
            return NookCard(
                id: "listening",
                mood: .listen,
                context: "Ik luister, praat gerust",
                title: "“Plan morgen een uur met Sanne en mail haar de link…”",
                detail: .waveform,
                primary: CardAction(label: "Klaar", outcome: .show(.plan)),
                secondary: CardAction(label: "Annuleren", outcome: .dismiss),
                contentHeight: 166
            )
        case .plan:
            return NookCard(
                id: "plan",
                mood: .think,
                context: "Plan · 3 stappen",
                title: "Zo regel ik het met Sanne:",
                detail: .steps([
                    PlanStep(number: 1, text: "Vrij moment: wo 14 okt, 10:00–11:00", tag: "gevonden", tone: .good),
                    PlanStep(number: 2, text: "Event “Overleg met Sanne” + Meet-link", tag: "", tone: .neutral),
                    PlanStep(number: 3, text: "Mail aan Sanne versturen", tag: "vraagt je OK", tone: .caution)
                ]),
                primary: CardAction(label: "Uitvoeren", outcome: .done("Event gemaakt · mail wacht op je OK")),
                secondary: CardAction(label: "Annuleren", outcome: .dismiss),
                contentHeight: 212
            )
        case .approval:
            return NookCard(
                id: "approval",
                mood: .waiting,
                context: "Claude Code · atlas",
                title: "Mag Claude een pakket installeren?",
                detail: .command("npm install stripe", note: "Omkeerbaar · één pakket · ik zie geen risico"),
                primary: CardAction(label: "Toestaan", outcome: .done("Toegestaan · npm install draait")),
                secondary: CardAction(label: "Weigeren", outcome: .dismiss),
                contentHeight: 198
            )
        }
    }

    static let today: [TodayItem] = [
        TodayItem(title: "Koffie met Lisa, vrijdag 14:00", subtitle: "Klaar om in je agenda te zetten", action: "Bekijk", color: NookTheme.iris, target: .card(.suggestion)),
        TodayItem(title: "Rapport naar Tom", subtitle: "Je beloofde het gisteren", action: "Opstellen", color: NookTheme.amber, target: .card(.reminder)),
        TodayItem(title: "Gemini CLI loopt vast", subtitle: "api · 2 van 48 tests falen", action: "Helpen", color: NookTheme.coral, target: .agent("gm"))
    ]

    static let agents: [AgentSession] = [
        AgentSession(
            id: "cc", name: "Claude Code", project: "atlas", status: .waiting,
            file: "src/payments.ts  +42 −8",
            placeholder: "Volgende opdracht voor Claude Code…",
            steps: [
                AgentStep(mark: .done, text: "14 bestanden gelezen"),
                AgentStep(mark: .done, text: "src/payments.ts aangepast"),
                AgentStep(mark: .blocked, text: "wil uitvoeren: npm install stripe")
            ],
            diff: [
                DiffLine(kind: .context, text: "  export async function charge(order) {"),
                DiffLine(kind: .remove, text: "-   return legacyPay(order.total)"),
                DiffLine(kind: .add, text: "+   const intent = await stripe.paymentIntents"),
                DiffLine(kind: .add, text: "+     .create({ amount: order.total })"),
                DiffLine(kind: .add, text: "+   return intent.id")
            ]
        ),
        AgentSession(
            id: "cx", name: "Codex", project: "website", status: .running,
            file: "app/hero.tsx  +18 −4",
            placeholder: "Volgende opdracht voor Codex…",
            steps: [
                AgentStep(mark: .done, text: "hero.tsx gelezen"),
                AgentStep(mark: .running, text: "nieuwe kop en knoppen bouwen"),
                AgentStep(mark: .todo, text: "daarna: build draaien")
            ],
            diff: [
                DiffLine(kind: .context, text: "  <section className=\"hero\">"),
                DiffLine(kind: .remove, text: "-   <h1>Welkom</h1>"),
                DiffLine(kind: .add, text: "+   <h1>Je Mac, die meedenkt</h1>"),
                DiffLine(kind: .add, text: "+   <Button>Download</Button>")
            ]
        ),
        AgentSession(
            id: "gm", name: "Gemini CLI", project: "api", status: .failed,
            file: "tests/auth.test.ts",
            placeholder: "Zeg wat Gemini moet proberen…",
            steps: [
                AgentStep(mark: .done, text: "token-refresh herschreven"),
                AgentStep(mark: .failed, text: "npm test: 2 van 48 falen"),
                AgentStep(mark: .todo, text: "wacht op nieuwe opdracht")
            ],
            diff: [
                DiffLine(kind: .context, text: "  it(\"refreshes an expired token\""),
                DiffLine(kind: .remove, text: "-   expected: 200"),
                DiffLine(kind: .add, text: "+   received: 401"),
                DiffLine(kind: .context, text: "  at auth.test.ts:88")
            ]
        ),
        AgentSession(
            id: "nk", name: "Nook", project: "weekrapport", status: .done,
            file: "weekrapport-41.md",
            placeholder: "Vraag Nook iets over dit rapport…",
            steps: [
                AgentStep(mark: .done, text: "agenda en mails van week 41 verzameld"),
                AgentStep(mark: .done, text: "concept geschreven"),
                AgentStep(mark: .done, text: "opgeslagen in Documenten")
            ],
            diff: [
                DiffLine(kind: .add, text: "+ # Week 41"),
                DiffLine(kind: .add, text: "+ - Atlas: betalingen naar Stripe"),
                DiffLine(kind: .add, text: "+ - 3 klantgesprekken, 1 offerte uit"),
                DiffLine(kind: .add, text: "+ - Volgende week: launch website")
            ]
        )
    ]
}
