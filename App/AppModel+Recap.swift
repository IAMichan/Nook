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
        var label = tr("app.recap.thisWeek")
        let lastWeek = recap.summary(weekOf: now.addingTimeInterval(-7 * 86_400))
        if (calendar.component(.weekday, from: now) == 2 || summary.isEmpty), !lastWeek.isEmpty {
            summary = lastWeek
            label = tr("app.recap.lastWeek")
        }
        UserDefaults.standard.set(Self.weekKey(lastWeek.start), forKey: "recapSeen")

        guard !summary.isEmpty else {
            viewModel.show(.card(answerCard(tr("app.recap.empty"))))
            return
        }

        var facts = [
            Fact(label: tr("app.recap.time"), value: RecapStore.duration(summary.activeSeconds)),
            Fact(label: tr("app.recap.sessions"), value: "\(summary.sessions)"),
            Fact(label: tr("app.recap.prompts"), value: "\(summary.prompts)"),
            Fact(label: tr("app.recap.lines"), value: "+\(summary.linesAdded) −\(summary.linesRemoved)"),
            Fact(label: tr("app.recap.commands"), value: "\(summary.commands)"),
            Fact(label: tr("app.recap.decisions"), value: "\(summary.allowed) / \(summary.denied)")
        ]
        if let day = summary.busiestDay {
            facts.append(Fact(label: tr("app.recap.busiest"), value: NookDates.weekday(day) + " · " + RecapStore.duration(summary.busiestSeconds)))
        }
        if let project = summary.topProject {
            facts.append(Fact(label: tr("app.recap.topProject"), value: project))
        }

        let who = summary.topAgent.map { tr("app.recap.andCo", $0) } ?? tr("app.recap.yourAgents")
        let card = NookCard(
            id: "recap",
            mood: .done,
            context: tr("app.recap.since", label, NookDates.dayMonth(summary.start)),
            title: tr("app.recap.worked", who, RecapStore.duration(summary.activeSeconds)),
            detail: .facts(facts),
            primary: CardAction(label: tr("app.ok"), outcome: .dismiss),
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
            title: tr("app.recap.title"),
            subtitle: tr("app.recap.subtitle", RecapStore.duration(lastWeek.activeSeconds), lastWeek.sessions),
            action: tr("button.view"),
            color: NookTheme.mint,
            target: .action { [weak self] in self?.showWeekRecap() }
        )
    }

    static func weekKey(_ date: Date) -> String {
        "\(Int(date.timeIntervalSince1970))"
    }
}
