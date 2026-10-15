import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Week recap card and Today item.
extension AppModel {
    // MARK: Week Recap

    func showWeekRecap() {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        var summary = recap.summary(weekOf: now)
        var label = "Deze week"
        let lastWeek = recap.summary(weekOf: now.addingTimeInterval(-7 * 86_400))
        if (calendar.component(.weekday, from: now) == 2 || summary.isEmpty), !lastWeek.isEmpty {
            summary = lastWeek
            label = "Vorige week"
        }
        UserDefaults.standard.set(Self.weekKey(lastWeek.start), forKey: "recapSeen")

        guard !summary.isEmpty else {
            viewModel.show(.card(answerCard("Ik heb nog niets bijgehouden. Koppel je agents bij Instellingen › Agents, dan zie je hier wat ze voor je deden.")))
            return
        }

        var facts = [
            Fact(label: "tijd met agents", value: RecapStore.duration(summary.activeSeconds)),
            Fact(label: "sessies", value: "\(summary.sessions)"),
            Fact(label: "opdrachten", value: "\(summary.prompts)"),
            Fact(label: "regels erbij / eraf", value: "+\(summary.linesAdded) −\(summary.linesRemoved)"),
            Fact(label: "commando's", value: "\(summary.commands)"),
            Fact(label: "toegestaan / geweigerd", value: "\(summary.allowed) / \(summary.denied)")
        ]
        if let day = summary.busiestDay {
            facts.append(Fact(label: "drukste dag", value: NookDates.weekday(day) + " · " + RecapStore.duration(summary.busiestSeconds)))
        }
        if let project = summary.topProject {
            facts.append(Fact(label: "meeste tijd in", value: project))
        }

        let who = summary.topAgent.map { "\($0) en co" } ?? "Je agents"
        let card = NookCard(
            id: "recap",
            mood: .done,
            context: "\(label) · vanaf \(NookDates.dayMonth(summary.start))",
            title: "\(who) werkten \(RecapStore.duration(summary.activeSeconds)) voor je.",
            detail: .facts(facts),
            primary: CardAction(label: "Oké", outcome: .dismiss),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 140 + CGFloat((facts.count + 1) / 2) * 44
        )
        viewModel.show(.card(card))
    }

    /// Weekly recap banner displayed in Nook tab on Mondays until viewed.
    func weeklyRecapItem() -> TodayItem? {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        guard calendar.component(.weekday, from: now) == 2 else { return nil }
        let lastWeek = recap.summary(weekOf: now.addingTimeInterval(-7 * 86_400))
        guard !lastWeek.isEmpty, UserDefaults.standard.string(forKey: "recapSeen") != Self.weekKey(lastWeek.start) else { return nil }
        return TodayItem(
            id: "recap",
            title: "Je week met agents",
            subtitle: "\(RecapStore.duration(lastWeek.activeSeconds)) · \(lastWeek.sessions) sessies",
            action: "Bekijk",
            color: NookTheme.mint,
            target: .action { [weak self] in self?.showWeekRecap() }
        )
    }

    static func weekKey(_ date: Date) -> String {
        "\(Int(date.timeIntervalSince1970))"
    }
}
