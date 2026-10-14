import SwiftUI

// Alle inhoud in dit bestand is voorbeelddata om de UI mee te laten zien.
// In de volgende fases komt dit uit echte bronnen (agenda, mail, AgentHub).

/// Scènes die je via het menubalk-icoon van Nook kunt oproepen.
enum DemoScene: String, CaseIterable {
    case idle, music, suggestion, reminder, listening, plan, approval, today, agents

    var title: String {
        switch self {
        case .idle: return "Rust"
        case .music: return "Muziek"
        case .suggestion: return "Ziet je scherm"
        case .reminder: return "Herinnering"
        case .listening: return "Spraak"
        case .plan: return "Plan"
        case .approval: return "Goedkeuring"
        case .today: return "Nook"
        case .agents: return "Agents"
        }
    }
}

// MARK: Agents

enum AgentStatus: Equatable {
    case waiting, running, failed, done
    case detected   // draait op deze Mac, maar nog niet gekoppeld met hooks

    var label: String {
        switch self {
        case .detected: return "draait"
        case .waiting: return "wacht op jou"
        case .running: return "bezig"
        case .failed: return "fout"
        case .done: return "klaar"
        }
    }

    var color: Color {
        switch self {
        case .detected: return NookTheme.textSecondary
        case .waiting: return NookTheme.amber
        case .running: return NookTheme.iris
        case .failed: return NookTheme.coral
        case .done: return NookTheme.mint
        }
    }
}

struct AgentStep: Identifiable, Equatable {
    enum Mark: Equatable { case done, running, blocked, failed, todo }
    let id = UUID()
    var mark: Mark
    var text: String

    var symbol: String {
        switch mark {
        case .done: return "✓"
        case .running: return "◐"
        case .blocked: return "●"
        case .failed: return "✗"
        case .todo: return "○"
        }
    }

    var color: Color {
        switch mark {
        case .done: return NookTheme.mint
        case .running: return NookTheme.iris
        case .blocked: return NookTheme.amber
        case .failed: return NookTheme.coral
        case .todo: return NookTheme.textTertiary
        }
    }
}

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case add, remove, context }
    let id = UUID()
    var kind: Kind
    var text: String

    var color: Color {
        switch kind {
        case .add: return NookTheme.mintSoft
        case .remove: return NookTheme.coralSoft
        case .context: return NookTheme.textTertiary
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    var id: String
    var name: String
    var project: String
    var status: AgentStatus
    var file: String
    var placeholder: String
    var steps: [AgentStep]
    var diff: [DiffLine]
    /// Werkmap van de sessie.
    var cwd: String = ""
    /// De app waarin de agent draait (Terminal, iTerm, VS Code…), voor "Open terminal".
    var hostBundleID: String = ""
    /// Een verzoek dat nu op jouw antwoord wacht.
    var approvalID: String? = nil
    /// Regels erbij en eraf in deze sessie.
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    /// Eén zin uit het laatste antwoord of bericht van de agent.
    var summary: String = ""
    /// Komt van een draaiend proces, niet van hooks.
    var isDetected: Bool { status == .detected }
}

struct TodayItem: Identifiable {
    enum Target { case card(CardScene), agent(String), action(() -> Void), none }
    var id: String = UUID().uuidString
    var title: String
    var subtitle: String
    var action: String
    var color: Color
    var target: Target
}

// MARK: Inhoud

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

enum Greeting {
    static func quiet() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 0..<6: salutation = "Goedenacht"
        case 6..<12: salutation = "Goedemorgen"
        case 12..<18: salutation = "Goedemiddag"
        default: salutation = "Goedenavond"
        }
        return "\(salutation). Niets dat op je wacht."
    }

    static func line(count: Int) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 0..<6: salutation = "Goedenacht"
        case 6..<12: salutation = "Goedemorgen"
        case 12..<18: salutation = "Goedemiddag"
        default: salutation = "Goedenavond"
        }
        let words = ["Geen", "Eén ding", "Twee dingen", "Drie dingen", "Vier dingen", "Vijf dingen"]
        let what = count < words.count ? words[count] : "\(count) dingen"
        return "\(salutation). \(what) voor je."
    }
}
