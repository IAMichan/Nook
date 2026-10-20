import SwiftUI
import Combine
import AppKit

/// Nook as a friend: what he wears, and the small moments he shares by himself (good morning, welcome back, a break,
/// a milestone). What to say and when is decided by `BuddyPlanner` and `NookOutfit`; this side gathers the signals,
/// dresses every orb and shows the moment below the notch.
extension AppModel {
    func startBuddy() {
        refreshOutfit()
        // Dress again when the wardrobe, the birthday or the music changes; the half-minute tick covers the clock.
        settings.$nookWardrobe.map { _ in () }
            .merge(with: settings.$birthday.map { _ in () }, NookPresence.shared.$listeningToMusic.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshOutfit() }
            .store(in: &buddy.bag)
        Timer.scheduledCoalesced(withTimeInterval: 30) { [weak self] _ in
            Task { @MainActor in self?.buddyTick() }
        }
    }

    /// An agent run finished: counts towards the milestones and the "while you were away" count. The last one of a
    /// busy stretch dresses Nook for a party for a little while.
    func buddyAgentFinished(last: Bool) {
        buddy.noteFinishedAgent()
        if last {
            buddy.celebratingUntil = Date().addingTimeInterval(8)
            refreshOutfit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { [weak self] in self?.refreshOutfit() }
        }
    }

    /// What Nook wears right now on every orb: your choices, plus what he picks himself for the season and the time.
    func refreshOutfit(at now: Date = Date()) {
        let outfit = NookOutfit.resolve(settings.nookWardrobe, context: outfitContext(at: now, celebrating: false))
        if NookAppearance.shared.outfit != outfit { NookAppearance.shared.outfit = outfit }
    }

    private func outfitContext(at now: Date, celebrating: Bool) -> NookOutfit.Context {
        let region = Locale.current.region?.identifier
        var context = NookOutfit.Context(date: now)
        context.region = region
        context.southernHemisphere = region.map { NookOutfit.southernRegions.contains($0) } ?? false
        context.birthday = NookMonthDay(stored: settings.birthday)
        context.celebrating = celebrating || (buddy.celebratingUntil.map { $0 > now } ?? false)
        context.headphones = NookPresence.shared.listeningToMusic
        return context
    }

    // MARK: Moments

    /// Every half minute: notes whether you are at your Mac, dresses Nook for the hour, and shares a moment when one
    /// is due and nothing else is going on.
    func buddyTick() {
        let now = Date()
        buddy.activity.note(idle: BuddyService.systemIdleSeconds(), at: now)
        refreshOutfit(at: now)
        guard settings.buddyMoments, !demoMode, settings.onboardingDone else { return }

        var signals = BuddyPlanner.Signals(now: now)
        signals.inEvent = buddyShouldStayQuiet(at: now)
        signals.notchFree = viewModel.state.isResting && !viewModel.pointerInside
        signals.active = buddy.activity.isActive(at: now)
        signals.firstOfDay = buddy.activity.justStartedDay(at: now)
        if let away = buddy.activity.justReturned(at: now) {
            signals.returnedAfter = away
            let back = buddy.activity.returnedAt ?? now
            signals.finishedWhileAway = buddy.finished(from: back.addingTimeInterval(-away), to: back)
        }
        signals.stretch = buddy.activity.stretch(at: now)
        signals.eventsToday = eventsLeftToday(at: now).count
        signals.finishedTotal = buddy.finishedTotal
        signals.birthday = NookMonthDay(stored: settings.birthday)

        guard let moment = BuddyPlanner.next(signals, ledger: buddy.ledger),
              viewModel.offerMoment(nookMoment(for: moment)) else { return }
        buddy.ledger.roll(to: BuddyActivity.dayKey(now))
        buddy.ledger.record(moment, at: now)
        if moment.kind == .breakTime { buddy.activity.restartStretch(at: now) }
    }

    /// In a meeting (an event going on in your calendar), on a call, or recording one: no moments.
    private func buddyShouldStayQuiet(at now: Date) -> Bool {
        // All-day events (a holiday, someone's birthday) are not meetings.
        let meeting = upcoming.contains { $0.start <= now && $0.end > now && $0.end.timeIntervalSince($0.start) < 12 * 3600 }
        let calling = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { BuddyService.callApps.contains($0) } ?? false
        return meeting || calling || NoteTaker.shared.isRecording
    }

    /// The moment as Nook shows it: his mood, his words in your language and tone, and what he wears.
    func nookMoment(for moment: BuddyMoment) -> NookMoment {
        let key = BuddyPlanner.lineKey(moment, tone: settings.buddyTone)
        let line: String
        switch moment.kind {
        case .morning, .welcomeBack:
            line = moment.count > 1 ? tr(key, moment.count) : tr(key)
        case .milestone:
            line = tr(key, moment.count)
        case .breakTime:
            line = tr(key, moment.minutes)
        default:
            line = tr(key)
        }
        let now = Date()
        var result = NookMoment(id: moment.id, line: line, mood: .rest)
        switch moment.kind {
        case .morning:
            result.mood = .cozy
            if moment.count > 0 {
                result.action = .showToday
                result.actionTitle = tr("buddy.action.today")
            }
        case .welcomeBack:
            result.mood = .surprised
            if moment.count > 0 {
                result.action = .openAgents
                result.actionTitle = tr("buddy.action.agents")
            }
        case .breakTime:
            result.mood = .caring
            result.action = .breathe
            result.actionTitle = tr("buddy.action.breathe")
            result.seconds = 16
        case .lateNight:
            result.mood = .sleepy
        case .fridayWrap:
            result.mood = .proud
        case .birthday:
            result.mood = .celebrate
            result.outfit = NookOutfit.resolve(settings.nookWardrobe, context: outfitContext(at: now, celebrating: true))
            result.seconds = 16
        case .milestone:
            result.mood = .celebrate
            result.outfit = NookOutfit.resolve(settings.nookWardrobe, context: outfitContext(at: now, celebrating: true))
            result.action = .openAgents
            result.actionTitle = tr("buddy.action.agents")
        }
        return result
    }

    /// The button on a moment.
    func performMomentAction(_ moment: NookMoment) {
        switch moment.action {
        case .breathe:
            buddy.activity.restartStretch(at: Date())
            viewModel.replaceMoment(NookMoment(id: "breathe-\(UUID().uuidString)", line: tr("buddy.breathe.in"), mood: .breathe,
                                               outfit: moment.outfit, seconds: NookMoment.breathLength))
        case .showToday:
            presentToday()
        case .openAgents:
            viewModel.show(.panel(.agents), inNotch: true)
        case nil:
            viewModel.show(.idle)
        }
    }

    /// The events in your calendar for the rest of today: what the morning greeting counts.
    func eventsLeftToday(at now: Date = Date()) -> [CalEvent] {
        upcoming.filter { $0.start > now && Calendar.current.isDate($0.start, inSameDayAs: now) }
    }

    /// The morning greeting, clicked: a card with what is on today, each with its time (and place).
    func presentToday() {
        let events = eventsLeftToday()
        guard !events.isEmpty else {
            viewModel.show(.card(answerCard(tr("buddy.today.empty"))))
            return
        }
        let shown = Array(events.prefix(6))
        var facts = shown.map { event in
            let time = NookDates.time(event.start) + " – " + NookDates.time(event.end)
            return Fact(label: event.location.isEmpty ? time : "\(time) · \(event.location)", value: event.title)
        }
        if events.count > shown.count {
            facts.append(Fact(label: tr("buddy.today.more"), value: "+\(events.count - shown.count)"))
        }
        let token = "today"
        viewModel.register("\(token)#calendar") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        let card = NookCard(
            id: token,
            mood: .cozy,
            context: tr("buddy.action.today"),
            title: events.count == 1 ? tr("buddy.today.one") : tr("buddy.today.many", events.count),
            detail: .facts(facts),
            primary: CardAction(label: tr("app.ok"), outcome: .dismiss),
            secondary: CardAction(label: tr("buddy.today.openCalendar"), outcome: .callback("\(token)#calendar", "")),
            contentHeight: 140 + CGFloat((facts.count + 1) / 2) * 44
        )
        viewModel.show(.card(card))
    }

    /// "Breathe with me", asked for: a minute of breathing along, also when no moment is showing.
    func breatheAlong() {
        let moment = NookMoment(id: "breathe-\(UUID().uuidString)", line: tr("buddy.breathe.in"), mood: .breathe,
                                seconds: NookMoment.breathLength)
        if case .moment = viewModel.state {
            viewModel.replaceMoment(moment)
        } else if !viewModel.offerMoment(moment) {
            viewModel.show(.idle)
            viewModel.offerMoment(moment)
        }
    }
}
