import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Files and the generic cards (answer, error, setup, welcome).
extension AppModel {
    // MARK: Files

    /// Shelf file: reads extracted text locally and answers user questions about it.
    /// Gives the chat a piece of text to ask about (an open web page), like dropping a file.
    func attachText(name: String, text: String) {
        attachment = (name, text, Date())
        var message = ChatMessage(role: .nook, text: tr("chat.attached", name))
        message.sources = [name]
        chat.append(message)
    }

    func askAbout(_ url: URL) {
        do {
            let text = try FileText.read(url)
            attachment = (url.lastPathComponent, text, Date())
            var message = ChatMessage(role: .nook, text: tr("app.file.read", url.lastPathComponent))
            message.sources = ["Bestand"]
            chat.append(message)
            showChat()
        } catch {
            viewModel.show(.card(errorCard(error.localizedDescription)))
        }
    }

    // MARK: Cards

    func presentLoop(_ loop: OpenLoop) {
        let token = "loop-" + loop.id
        viewModel.register("\(token)#done") { [weak self] in
            self?.store.completeLoop(id: loop.id)
            self?.reloadLoops()
        }
        let card = NookCard(
            id: token,
            mood: .remind,
            context: tr("app.loop.since", NookDates.short(loop.created)),
            title: loop.title,
            detail: .none,
            primary: CardAction(label: tr("app.loop.done"), outcome: .callback("\(token)#done", tr("app.loop.checked"))),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: 130
        )
        viewModel.show(.card(card))
    }

    /// ⌥⌘ Space shortcut: immediately focus chat input from anywhere.
    func openAsk() {
        warmUp()
        showChat(focus: true)
    }

    /// Opens the first-run flow in the main window.
    func startOnboarding() {
        openWindow()
        showOnboarding = true
    }

    /// First-run onboarding card: leads into the 3-step setup in the main window.
    func presentWelcome() {
        let token = "welcome"
        viewModel.register("\(token)#setup") { [weak self] in self?.startOnboarding() }
        viewModel.register("\(token)#later") { [weak self] in self?.settings.onboardingDone = true }
        let facts = [
            Fact(label: tr("app.welcome.brain"), value: settings.brainReady ? tr("app.welcome.ready") : tr("app.welcome.chooseBrain")),
            Fact(label: tr("app.welcome.screen"), value: CGPreflightScreenCaptureAccess() ? tr("app.welcome.on") : tr("app.welcome.allow")),
            Fact(label: tr("app.welcome.calendar"), value: calendar.hasEventAccess ? tr("app.welcome.connected") : tr("app.welcome.allow")),
            Fact(label: tr("app.welcome.connections"), value: tr("app.welcome.connectionsValue"))
        ]
        let card = NookCard(
            id: token,
            mood: .seen,
            context: tr("onboarding.title"),
            title: tr("app.welcome.title"),
            detail: .facts(facts),
            primary: CardAction(label: tr("app.welcome.setup"), outcome: .callback("\(token)#setup", "")),
            secondary: CardAction(label: tr("button.later"), outcome: .callback("\(token)#later", "")),
            contentHeight: 150 + 2 * 44 + 24
        )
        viewModel.present(card)
    }

    /// Attaches a Shelf file to a new email draft in Mail.app. Requires user to send.
    func mailFile(_ url: URL) {
        let path = ScriptText.quote(url.path)
        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {visible:true, subject:\(ScriptText.quote(url.lastPathComponent))}
            tell content of m to make new attachment with properties {file name:(POSIX file \(path) as alias)} at after last paragraph
            activate
        end tell
        """
        Task {
            let result = await ScriptText.run(script)
            if result.errorNumber == -1743 {
                viewModel.present(errorCard(tr("app.mail.permission")))
            } else {
                store.audit(tool: "mail_file", args: url.lastPathComponent, result: "concept geopend")
                viewModel.finish(tr("app.mail.draftReady", url.lastPathComponent))
            }
        }
    }

    func thinkingCard(context: String, title: String) -> NookCard {
        NookCard(
            id: "thinking",
            mood: .think,
            context: context,
            title: title,
            detail: .none,
            primary: CardAction(label: tr("app.hide"), outcome: .dismiss),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 130
        )
    }

    func answerCard(_ text: String, offers: [String] = []) -> NookCard {
        let body = text.isEmpty ? tr("app.noAnswer") : String(text.prefix(4000))
        let lines = min(9, max(1, Int(ceil(Double(body.count) / 46.0))))
        let token = "answer-" + UUID().uuidString
        return NookCard(
            id: token,
            mood: .seen,
            context: "Nook",
            title: body,
            detail: .none,
            primary: CardAction(label: tr("app.ok"), outcome: .dismiss),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: 140 + CGFloat(lines) * 24 + (offers.isEmpty ? 0 : 40),
            input: true,
            offers: offers
        )
    }

    func errorCard(_ message: String) -> NookCard {
        let lines = max(1, Int(ceil(Double(message.count) / 46.0)))
        let token = "error-" + UUID().uuidString
        viewModel.register("\(token)#settings") { [weak self] in self?.openSettings() }
        return NookCard(
            id: token,
            mood: .worry,
            context: tr("app.error.context"),
            title: String(message.prefix(240)),
            detail: .none,
            primary: CardAction(label: tr("app.ok"), outcome: .dismiss),
            secondary: CardAction(label: tr("app.settings"), outcome: .callback("\(token)#settings", "")),
            contentHeight: 90 + CGFloat(lines) * 24
        )
    }

    func presentSetupCard() {
        // Local brain without a model: propose the one that suits this Mac instead of sending the user to Settings.
        if settings.isLocalBrain {
            presentLocalSetupCard()
            return
        }
        let token = "setup-" + UUID().uuidString
        viewModel.register("\(token)#open") { [weak self] in self?.openSettings() }
        let card = NookCard(
            id: token,
            mood: .waiting,
            context: tr("app.setup.context"),
            title: tr("app.setup.title"),
            detail: .none,
            primary: CardAction(label: tr("app.setup.open"), outcome: .callback("\(token)#open", "")),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: 138
        )
        viewModel.show(.card(card))
    }
}
