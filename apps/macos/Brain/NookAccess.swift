import Foundation

/// How much Nook may do by itself from the chat and the Double Tap field, chosen in their composer (⇧Tab moves to the
/// next level) the way an agent's access is chosen in its own composer.
///
/// Whatever the level, an action only runs without a click when the user's own words ask for it
/// (`AppModel.request(_:asksFor:)`): text from the screen, a mail or a web page is never enough. Mail and messages, links,
/// commands, shortcuts, webhooks, settings and deleting always wait for a click, and every action that runs is in the audit log.
enum NookAccess: String, CaseIterable, Identifiable, Codable {
    /// Every action waits for a click.
    case ask
    /// Small, easily reversed things right away: music, volume, an app, a reminder, a to-do.
    case small
    /// Also what stays with you and nobody else receives (a calendar event without invitations, a note), and a whole
    /// task Nook takes over with mouse and keyboard (`TakeoverPolicy`): a step that pays, orders, sends, deletes, books
    /// or signs still waits for the user's yes in the notch.
    case more

    var id: String { rawValue }

    /// What `small` runs without a click.
    static let smallTools: Set<String> = ["media_control", "set_volume", "open_app", "add_open_loop", "create_reminder",
                                          "complete_open_loop", "open_settings"]
    /// What `more` runs without a click besides the small things.
    static let moreTools: Set<String> = smallTools.union(["create_event", "create_note", TakeoverPolicy.toolName])

    /// The tools this level runs without asking.
    var tools: Set<String> {
        switch self {
        case .ask: return []
        case .small: return Self.smallTools
        case .more: return Self.moreTools
        }
    }

    func allows(_ tool: String) -> Bool { tools.contains(tool) }

    /// ⇧Tab in the composer: ask → small → more → ask.
    var next: NookAccess {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var label: String { tr("nookAccess.\(rawValue)") }
    /// A shorter text for a narrow composer.
    var short: String { tr("nookAccess.\(rawValue).short") }
    var detail: String { tr("nookAccess.\(rawValue).detail") }

    var symbol: String {
        switch self {
        case .ask: return "lock"
        case .small: return "hand.tap"
        case .more: return "lock.open"
        }
    }

    /// A task to take over is the user's own: most of its words come from what they typed, so a task planted by text on
    /// screen or in a mail never starts without a click.
    static func grounded(task: String, in request: String) -> Bool {
        let words = { (text: String) in
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
        }
        let needed = words(task)
        guard !needed.isEmpty else { return false }
        let said = words(request)
        return Double(needed.filter(said.contains).count) / Double(needed.count) >= 0.6
    }

    /// The level from before it could be chosen in the composer: the "small things right away" switch.
    static func migrated(stored: String?, autoRunSafe: Bool) -> NookAccess {
        if let stored, let access = NookAccess(rawValue: stored) { return access }
        return autoRunSafe ? .small : .ask
    }
}
