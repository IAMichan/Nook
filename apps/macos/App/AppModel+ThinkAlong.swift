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
                    context: tr("app.look.saw", snapshot.appName)
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
        guard settings.autoWatch, settings.brainReady, !autoBusy, !demoMode,
              !settings.privateSources.contains(SourceCatalog.screen),
              CGPreflightScreenCaptureAccess(), viewModel.state.isResting else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundle = frontApp?.bundleIdentifier ?? ""
        // Window title and contents from live cache; throttled to at most once per 5 minutes without cache.
        let front = screenContext.windows.first { $0.isFront && $0.bundleID == bundle }
        let window = front?.title ?? ""
        let print = front?.fingerprint ?? UInt64(Date().timeIntervalSince1970 / 300)
        guard thinkAlong.shouldLook(bundleID: bundle, window: window, print: print) else { return }
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
        [Meedenken] De gebruiker is nu bezig in \(appName)\(window.isEmpty ? "" : " (venster: \(window.prefix(80)))"). \
        Je kijkt ongevraagd mee. Is er één concreet ding dat jij nu voor hem kunt overnemen met een actie-tool (iets inplannen, \
        een herinnering of open punt, een concept schrijven, een app of link openen), of weet je een duidelijk slimmere of snellere \
        aanpak voor wat hij nu doet? Roep bij een actie meteen de tool aan; bied nooit iets aan ("Zal ik…?") zonder die tool aan te roepen. \
        Begin je tekst met één korte vraag of tip van hooguit acht woorden, zoals "Zal ik hem herinneren aan de deadline van vrijdag?" \
        of "Tip: dit kan ook in één keer", daarna hooguit twee zinnen uitleg. \
        Alleen als het hem echt tijd scheelt of voorkomt dat hij iets vergeet; samenvattingen, complimenten of wat hij al doet tellen niet. \
        Plan of herinner alleen iets als er op het scherm een concrete datum, tijd, deadline of afspraak met iemand staat. \
        Gewoon bezig zijn met werk (code, een pull request, een document, een tool of app) is nooit een reden voor een agendapunt of herinnering. \
        Kijk bij datums van herinneringen en afspraken altijd naar het volledige jaartal en vergelijk met de huidige datum ("Nu"): \
        alleen wat binnen twee dagen valt of al verlopen is, is dichtbij; iets over weken, maanden of een jaar is geen reden om te melden. \
        Twijfel je, antwoord dan alleen NONE.
        """
        let earlier = thinkAlong.recentOffers
        if !earlier.isEmpty {
            request += " You recently offered this; do not repeat it: " + earlier.joined(separator: "; ") + "."
        }
        // The same preparation as a chat answer; thinking along reads the screen, so no lookups up front.
        let prepared = await prepareRun(text: request, scope: .automatic, snapshotText: snapshot.text, ledger: RetrievalLedger(), prefetch: false)

        guard var plan = try? await brain.run(
            userText: request,
            context: prepared.context,
            untrustedLabel: "\(snapshot.appName) — \(snapshot.windowTitle)",
            untrusted: snapshot.text,
            tools: prepared.tools
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

        let line = Self.nudgeLine(body: body, fallback: planSteps(plan.actions).first.map { tr("app.nudge.shall", $0.text) })
        guard !line.isEmpty, !thinkAlong.alreadyOffered(line) else { return }
        // An offer ("Shall I…?") without an action would do nothing when accepted; only plain tips may go without one.
        guard !plan.actions.isEmpty || !line.hasSuffix("?") else { return }

        let offer = BrainPlan(text: body, actions: plan.actions)
        let card = nudgeCard(offer, offers: split.offers, bundleID: bundleID, appName: appName)
        guard viewModel.offerNudge(line, card: card) else { return }
        thinkAlong.didOffer(line)
        missedNudge = (line, card, appName, Date())
    }

    /// Concise teaser beside notch: first sentence of the offer, max ~60 characters.
    static func nudgeLine(body: String, fallback: String?) -> String {
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var line = first
        if let end = first.firstIndex(where: { $0 == "?" || $0 == "." || $0 == "!" }) {
            line = String(first[...end])
        }
        line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if line.isEmpty { line = fallback ?? "" }
        return line.count > 64 ? String(line.prefix(62)) + "…" : line
    }

    /// Full proposal: what Nook observed, suggested action, with Accept, Dismiss, or Mute in App.
    func nudgeCard(_ plan: BrainPlan, offers: [String], bundleID: String, appName: String) -> NookCard {
        let token = "nudge-" + UUID().uuidString
        let title = plan.text.isEmpty ? tr("app.nudge.title") : String(plan.text.prefix(600))
        let topic = Self.nudgeLine(body: plan.text, fallback: tr("app.nudge.title"))
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
            self?.thinkAlong.declined()
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
