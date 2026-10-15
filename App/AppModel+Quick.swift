import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Quick commands recognised without calling the brain.
extension AppModel {
    // MARK: Quick Commands

    func handleLocalIntent(_ intent: LocalIntent) {
        spokenRequest = false
        switch intent {
        case .media(let action):
            let command: NowPlayingService.Command
            let message: String
            switch action {
            case "next": command = .next; message = tr("app.quick.next")
            case "previous": command = .previous; message = tr("app.quick.previous")
            default: command = .playPause; message = nowPlaying.current?.isPlaying == true ? tr("app.quick.paused") : tr("app.quick.resumed")
            }
            nowPlaying.control(command)
            viewModel.finish(message)
        case .volume(let level):
            proposeQuick(tool: "set_volume", input: ["level": level])
        case .volumeStep(let step):
            let current = Int(SystemControl.appleScript("output volume of (get volume settings)") ?? "") ?? 50
            proposeQuick(tool: "set_volume", input: ["level": max(0, min(100, current + step))])
        case .openApp(let name):
            proposeQuick(tool: "open_app", input: ["name": name])
        case .showTab(let tab):
            viewModel.show(.panel(tab))
        case .weekRecap:
            showWeekRecap()
        case .time:
            let text = tr("app.quick.time", NookDates.time(Date()))
            viewModel.show(.card(answerCard(text)))
            if settings.speakAnswers { speech.speak(text, language: settings.language) }
        }
    }

    /// Quick commands resolved immediately in chat without card UI. Nil: present standard card.
    func quickReplyInChat(_ intent: LocalIntent) -> String? {
        switch intent {
        case .media(let action):
            let command: NowPlayingService.Command
            let message: String
            switch action {
            case "next": command = .next; message = tr("app.quick.next") + "."
            case "previous": command = .previous; message = tr("app.quick.previous") + "."
            default: command = .playPause; message = nowPlaying.current?.isPlaying == true ? tr("app.quick.paused") + "." : tr("app.quick.resumed") + "."
            }
            nowPlaying.control(command)
            return message
        case .time:
            return tr("app.quick.time", NookDates.time(Date()))
        default:
            return nil
        }
    }

    /// Deterministically recognized action: prepared directly as an action plan without calling the brain.
    func proposeQuick(tool: String, input: [String: Any]) {
        let plan = BrainPlan(text: "", actions: [PlannedAction(tool: tool, input: input)])
        // Recognized word for word from the user's own command, so it counts as asked for.
        if settings.autoRunSafe, Self.safeTools.contains(tool) {
            execute(plan)
            return
        }
        viewModel.show(.card(planCard(plan, context: tr("app.quick.context"))))
    }
}
