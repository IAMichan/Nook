import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Looking at the screen and thinking along while the user works.
extension AppModel {
    // MARK: Screen Context

    func lookAtScreen(manual: Bool) {
        guard settings.brainReady else {
            if manual { presentSetupCard() }
            return
        }
        // The screen is kept on this Mac: an external brain does not get its text.
        guard !settings.privateSources.contains(SourceCatalog.screen) else {
            if manual { viewModel.show(.card(errorCard(tr("app.look.private")))) }
            return
        }
        if manual {
            viewModel.show(.card(thinkingCard(context: tr("app.look.context"), title: tr("app.look.title"))))
        }
        Task {
            do {
                let snapshot = try await screen.capture()
                let hash = snapshot.text.hashValue
                if !manual {
                    if hash == lastScreenHash { return }
                }
                lastScreenHash = hash
                await runBrain(
                    userText: "This is what the user currently has on screen. Do you see anything you can help with, such as an event, a commitment, or a task? Propose an appropriate action. If nothing relevant: NONE.",
                    snapshot: snapshot,
                    silentIfNone: !manual,
                    context: tr("app.look.saw", snapshot.appName),
                    ownRequest: true
                )
            } catch {
                if manual { replaceThinking(with: errorCard(error.localizedDescription)) }
            }
        }
    }

    // MARK: ThinkAlong

    /// Pending proactive offer awaiting response, displayed temporarily in Today.

    /// When actively working, Nook evaluates screen context and offers assistance when genuinely helpful.
    func thinkAlongTick() {
        // Not while you share your screen or sit in a meeting and chose quiet for it.
        guard settings.autoWatch, settings.brainReady, !autoBusy, !demoMode, !quiet.silent,
              !settings.privateSources.contains(SourceCatalog.screen),
              ScreenAccess.isUsable, viewModel.state.isResting else { return }
        // Thinking along is optional: never while the Mac is hot, saving power or busy with something heavy. With the
        // model on this Mac each look is a full run on the GPU, so it looks less often (`ThinkAlong.localLookGap`).
        guard !SystemLoad.isConstrained else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundle = frontApp?.bundleIdentifier ?? ""
        // Window title and contents from live cache; throttled to at most once per 5 minutes without cache.
        let front = screenContext.windows.first { $0.isFront && $0.bundleID == bundle }
        let window = front?.title ?? ""
        let print = front?.fingerprint ?? UInt64(Date().timeIntervalSince1970 / 300)
        guard thinkAlong.shouldLook(bundleID: bundle, window: window, print: print,
                                    minGap: settings.useLocal ? ThinkAlong.localLookGap : nil) else { return }
        thinkAlong.didLook(bundleID: bundle, window: window, print: print)

        autoBusy = true
        let appName = frontApp?.localizedName ?? "deze app"
        Task {
            await thinkAlongRun(bundleID: bundle, appName: appName, window: window)
            autoBusy = false
        }
    }

    func thinkAlongRun(bundleID: String, appName: String, window: String) async {
        guard let snapshot = try? await screenSnapshot() else { return }
        var request = """
        [Think along] The user is working in \(appName)\(window.isEmpty ? "" : " (window: \(window.prefix(80)))"). \
        You are looking over their shoulder without being asked. Every interruption costs them attention, so speak up only \
        with something they would be glad to see right now. Most of the time the right answer is NONE.

        Worth an offer, and only when it is about something visible on this screen:
        - A follow-up you can take over with an action tool: an invitation or appointment with a date and time to put in the calendar, \
        a question or request in a mail or chat to answer (write a draft), a task or promise due within two days to remind them of, \
        a link, file or app to open.
        - A concrete, clearly faster way to do exactly what they are doing on this screen: a specific feature, shortcut or command, \
        named together with the thing on screen it applies to.

        Never:
        - Anything that is not on this screen. Nook's own reminders, open loops, calendar, memory and earlier conversations are in \
        the context to avoid duplicates and conflicts, not to be brought up.
        - Dates more than two days away. Always read the full year and compare with the current date ("Now").
        - A calendar item or reminder for ongoing work (code, a pull request, a document, a tool or app).
        - Summaries, compliments, generic productivity advice, or describing what they are already doing.
        - Offering something without calling the tool in this same answer. A question without an action is never allowed.

        Form: when you take something over, call the tool right away and start your text with one short question of at most \
        ten words that names the concrete thing (the person, subject or date), followed by at most one sentence on why now. \
        A tip starts with "Tip:", names the concrete thing on screen, and is never combined with a question. \
        \(settings.ownLanguageInstruction) When in doubt, answer only NONE.
        """
        let earlier = thinkAlong.recentOffers
        if !earlier.isEmpty {
            request += "\nYou recently offered these; do not repeat them, not even reworded: " + earlier.joined(separator: "; ") + "."
        }
        // The same preparation as a chat answer; thinking along reads the screen, so no lookups up front.
        let prepared = await prepareRun(text: request, scope: .automatic, snapshotText: snapshot.text, ledger: RetrievalLedger(), prefetch: false)

        guard var plan = try? await brain.run(
            userText: request,
            context: prepared.context,
            untrustedLabel: "\(snapshot.appName) — \(snapshot.windowTitle)",
            untrusted: snapshot.text,
            tools: prepared.tools,
            ownRequest: true
        ) else { return }
        plan.actions = plan.actions.compactMap { action in
            guard let spec = prepared.tools.first(where: { $0.name == action.tool }) ?? allTools.first(where: { $0.name == action.tool }) else { return nil }
            var copy = action
            copy.input = ActionGate.normalized(action.input, schema: spec.schema)
            return copy
        }

        let split = FollowUps.split(plan.text)
        var body = split.body
        let bare = body.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        if bare == "NONE" || bare.hasPrefix("NONE") { body = "" }
        guard !body.isEmpty || !plan.actions.isEmpty else { return }

        let line = NudgeFilter.line(body: body, fallback: planSteps(plan.actions).first.map { tr("app.nudge.shall", $0.text) })
        guard !line.isEmpty, !thinkAlong.alreadyOffered(line) else { return }
        // Something that is weeks or a year away (a domain renewal next September) is no reason to interrupt now.
        guard !NudgeFilter.isFarOff(Self.mentionedDates(in: body)) else { return }
        // An offer ("Shall I…?") without an action would do nothing when accepted; only plain tips may go without one.
        guard !NudgeFilter.asksWithoutAction(body, hasActions: !plan.actions.isEmpty) else { return }
        // Only offers about what is on screen: no generic advice, nothing dug up from Nook's own reminders or memory.
        let visible = [snapshot.appName, snapshot.windowTitle, snapshot.text].joined(separator: "\n")
        guard NudgeFilter.isGrounded(body.isEmpty ? line : body, screen: visible) else { return }

        let offer = BrainPlan(text: body, actions: plan.actions)
        let card = nudgeCard(offer, offers: split.offers, bundleID: bundleID, appName: appName)
        guard viewModel.offerNudge(line, card: card) else { return }
        thinkAlong.didOffer(line)
        missedNudge = (line, card, appName, Date())
    }

    /// Dates the offer talks about ("2027-09-20", "next Friday"), as the system's date detector reads them.
    static func mentionedDates(in text: String) -> [Date] {
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return NudgeFilter.numericDates(in: text)
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.date) + NudgeFilter.numericDates(in: text)
    }

    /// Full proposal: what Nook observed, suggested action, with Accept, Dismiss, or Mute in App.
    func nudgeCard(_ plan: BrainPlan, offers: [String], bundleID: String, appName: String) -> NookCard {
        let token = "nudge-" + UUID().uuidString
        let title = plan.text.isEmpty ? tr("app.nudge.title") : String(plan.text.prefix(600))
        let topic = NudgeFilter.line(body: plan.text, fallback: tr("app.nudge.title"))
        // Accepted, the proposal goes on in the chat: the outcome shows there and can be adjusted with a follow-up.
        let shown = BrainPlan(text: title, actions: plan.actions)
        viewModel.register("\(token)#yes") { [weak self] in
            guard let self else { return }
            self.thinkAlong.accepted()
            self.missedNudge = nil
            self.cardReplies[token] = nil
            if !plan.actions.isEmpty { self.continueInChat(shown, title: topic, sources: [appName], offers: offers) }
        }
        viewModel.register("\(token)#no") { [weak self] in
            self?.thinkAlong.declined(topic)
            self?.missedNudge = nil
            self?.cardReplies[token] = nil
        }
        viewModel.register("\(token)#mute") { [weak self] in
            self?.thinkAlong.mute(bundleID: bundleID, name: appName)
            self?.missedNudge = nil
            self?.cardReplies[token] = nil
        }
        registerCardReply(token) { [weak self] in
            guard let self else { return }
            self.thinkAlong.accepted()
            self.missedNudge = nil
            self.continueInChat(shown, title: topic, sources: [appName], offers: offers, run: false)
        }

        let steps = planSteps(plan.actions)
        let long = title.count > 140
        let lines = min(8, max(1, Int(ceil(Double(title.count) / (long ? 62.0 : 46.0)))))
        var height = 150 + CGFloat(lines) * (long ? 21 : 24)
        if !steps.isEmpty { height += CGFloat(steps.count * 30) + 14 }
        if !offers.isEmpty { height += 40 }

        let no = CardAction(label: tr("app.no"), outcome: .callback("\(token)#no", ""))
        return NookCard(
            id: token,
            mood: .seen,
            context: tr("app.nudge.context"),
            title: title,
            detail: steps.isEmpty ? .none : .steps(steps),
            primary: CardAction(label: plan.actions.isEmpty ? tr("app.nudge.handy") : tr("app.nudge.doIt"), outcome: .callback("\(token)#yes", "")),
            secondary: no,
            contentHeight: min(470, height),
            input: true,
            extra: [CardAction(label: tr("app.nudge.mute"), outcome: .callback("\(token)#mute", tr("app.nudge.muted", appName)))],
            sources: [appName],
            offers: offers,
            escape: no
        )
    }

    /// One-time post-update banner explaining ThinkAlong and auto-run features.
    func presentThinkAlongIntro() {
        guard settings.brainReady, !settings.autoWatch else { return }
        UserDefaults.standard.set(true, forKey: "thinkAlongIntro")
        let token = "thinkintro"
        viewModel.register("\(token)#all") { [weak self] in
            self?.settings.autoWatch = true
            self?.settings.autoRunSafe = true
        }
        viewModel.register("\(token)#watch") { [weak self] in self?.settings.autoWatch = true }
        let facts = [
            Fact(label: tr("app.intro.alongLabel"), value: tr("app.intro.alongValue")),
            Fact(label: tr("app.intro.smallLabel"), value: tr("app.intro.smallValue")),
            Fact(label: tr("app.intro.askLabel"), value: tr("app.intro.askValue")),
            Fact(label: tr("app.intro.offLabel"), value: tr("app.intro.offValue"))
        ]
        let card = NookCard(
            id: token,
            mood: .seen,
            context: tr("app.intro.context"),
            title: tr("app.intro.title"),
            detail: .facts(facts),
            primary: CardAction(label: tr("app.intro.enable"), outcome: .callback("\(token)#all", tr("app.intro.enabled"))),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: 150 + 2 * 44 + 24,
            extra: [CardAction(label: tr("app.intro.onlyAlong"), outcome: .callback("\(token)#watch", tr("app.intro.enabled")))],
            escape: CardAction(label: tr("button.later"), outcome: .dismiss)
        )
        viewModel.present(card)
    }
}
