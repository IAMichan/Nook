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
        if manual {
            viewModel.show(.card(thinkingCard(context: "Ik kijk even mee…", title: "Ik lees wat er op je scherm staat.")))
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
                    context: "Ik zag in \(snapshot.appName)"
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
        aanpak voor wat hij nu doet? Roep bij een actie meteen de tool aan. Begin je tekst met één korte vraag of tip van hooguit \
        acht woorden, zoals "Zal ik dit in je agenda zetten?" of "Tip: dit kan ook in één keer", daarna hooguit twee zinnen uitleg. \
        Alleen als het hem echt tijd scheelt of voorkomt dat hij iets vergeet; samenvattingen, complimenten of wat hij al doet tellen niet. \
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

        let line = Self.nudgeLine(body: body, fallback: planSteps(plan.actions).first.map { "Zal ik dit doen? \($0.text)" })
        guard !line.isEmpty, !thinkAlong.alreadyOffered(line) else { return }

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
        viewModel.register("\(token)#yes") { [weak self] in
            guard let self else { return }
            self.thinkAlong.accepted()
            self.missedNudge = nil
            if !plan.actions.isEmpty { self.execute(plan) }
        }
        viewModel.register("\(token)#no") { [weak self] in
            self?.thinkAlong.declined()
            self?.missedNudge = nil
        }
        viewModel.register("\(token)#mute") { [weak self] in
            self?.thinkAlong.mute(bundleID: bundleID, name: appName)
            self?.missedNudge = nil
        }

        let steps = planSteps(plan.actions)
        let title = plan.text.isEmpty ? "Zal ik dit voor je doen?" : String(plan.text.prefix(600))
        let long = title.count > 140
        let lines = min(8, max(1, Int(ceil(Double(title.count) / (long ? 62.0 : 46.0)))))
        var height = 150 + CGFloat(lines) * (long ? 21 : 24)
        if !steps.isEmpty { height += CGFloat(steps.count * 30) + 14 }
        if !offers.isEmpty { height += 40 }

        let no = CardAction(label: "Nee", outcome: .callback("\(token)#no", ""))
        return NookCard(
            id: token,
            mood: .seen,
            context: "Ik dacht mee",
            title: title,
            detail: steps.isEmpty ? .none : .steps(steps),
            primary: CardAction(label: plan.actions.isEmpty ? "Handig" : "Doe maar", outcome: .callback("\(token)#yes", "")),
            secondary: no,
            contentHeight: min(470, height),
            input: true,
            extra: [CardAction(label: "Niet in deze app", outcome: .callback("\(token)#mute", "Ik denk niet meer mee in \(appName)"))],
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
            Fact(label: "meedenken", value: "ik bied zelf hulp aan"),
            Fact(label: "kleine dingen zelf doen", value: "muziek, volume, apps"),
            Fact(label: "altijd eerst vragen", value: "agenda, mail, links"),
            Fact(label: "uitzetten", value: "Instellingen › Assistent")
        ]
        let card = NookCard(
            id: token,
            mood: .seen,
            context: "Nieuw in Nook",
            title: "Zal ik meedenken terwijl je werkt? Zie ik iets wat ik voor je kan doen, dan bied ik het aan.",
            detail: .facts(facts),
            primary: CardAction(label: "Zet aan", outcome: .callback("\(token)#all", "Ik denk vanaf nu mee")),
            secondary: CardAction(label: "Later", outcome: .dismiss),
            contentHeight: 150 + 2 * 44 + 24,
            extra: [CardAction(label: "Alleen meedenken", outcome: .callback("\(token)#watch", "Ik denk vanaf nu mee"))],
            escape: CardAction(label: "Later", outcome: .dismiss)
        )
        viewModel.present(card)
    }
}
