import AppKit
import SwiftUI

/// Tells VoiceOver how the session on screen gets on (`AgentAnnouncements`, Settings › Sessions › Screen reader
/// announcements): the step the agent is on, the replies it finishes, a question or approval waiting on you. Only while
/// VoiceOver runs, and only from a window that is on screen; another session, or turning it on, starts silent again.
@MainActor
final class AgentAnnouncer {
    private var key: String?
    private var memory: AgentAnnouncements.Memory?
    /// The window the conversation is in; nothing is said while it is not on screen.
    weak var window: NSWindow?
    private lazy var pacer = AnnouncementPacer { [weak self] text in self?.post(text) }

    /// Whether anything can be said now: VoiceOver runs and the setting is not off. Snapshots are only built then.
    static var listening: Bool {
        NSWorkspace.shared.isVoiceOverEnabled && WorkspaceSettings.shared.screenReaderAnnouncements != .off
    }

    func update(key: String, author: String, snapshot: AgentAnnouncementSnapshot) {
        if key != self.key {
            self.key = key
            reset()
        }
        let level = WorkspaceSettings.shared.screenReaderAnnouncements
        guard Self.listening, onScreen else {
            // Nothing is kept while nobody listens: coming back starts from a new silent baseline.
            reset()
            return
        }
        let next = AgentAnnouncements.next(memory, snapshot, level: level, author: author)
        memory = next.memory
        pacer.say(next.messages)
        if level != .everything || next.memory.step == nil {
            pacer.step(nil)
        } else if let step = next.step {
            pacer.step(step)
        }
    }

    func reset() {
        memory = nil
        pacer.reset()
    }

    private var onScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    private func post(_ text: String) {
        guard Self.listening, onScreen else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// The step as it is said, from what the live line shows; nil for what is no step of its own (it starts, writes
    /// its answer, or looks at a result). Its thinking is never read: only that it thinks.
    static func spokenStep(_ activity: AgentActivity) -> String? {
        switch activity {
        case .starting, .writing, .reviewing: return nil
        case .thinking: return tr("ws.activity.thinking")
        case .running, .verifying, .reading, .editing, .searching, .browsing, .delegating, .planning, .screen, .using,
             .recovering, .compacting:
            return AgentActivityText.headline(activity)
        }
    }
}

private struct AgentProgressAnnouncements: ViewModifier {
    let key: String
    let author: String
    let snapshot: AgentAnnouncementSnapshot
    @State private var announcer = AgentAnnouncer()

    func body(content: Content) -> some View {
        content
            .background(WindowReader { announcer.window = $0 })
            // Only when what is told changes, never on a timer: a step waits on a single one-shot delay in the pacer.
            .onChange(of: snapshot, initial: true) { _, now in announcer.update(key: key, author: author, snapshot: now) }
            .onChange(of: key) { _, now in announcer.update(key: now, author: author, snapshot: snapshot) }
            .onDisappear { announcer.reset() }
    }
}

extension View {
    /// Speaks the session's progress to VoiceOver while it is on screen (`AgentAnnouncer`). `key` names the session;
    /// build `snapshot` only when `AgentAnnouncer.listening`, and pass `.idle` otherwise.
    func announcesAgentProgress(key: String, author: String, snapshot: AgentAnnouncementSnapshot) -> some View {
        modifier(AgentProgressAnnouncements(key: key, author: author, snapshot: snapshot))
    }
}
