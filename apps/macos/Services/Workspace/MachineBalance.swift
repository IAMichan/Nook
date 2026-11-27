import Foundation

// "Automatic" under the composer's "Runs on" (t3code's "Auto balance"): Nook picks where a new session of a project runs,
// this Mac or one of your machines over SSH. Foundation only and pure, so the choice is tested apart from the app.
//
// A project is shared with a machine once a session of it ran there: the machine keeps the project's folder there
// (`RemoteMachine.projectFolders`). Among this Mac and the shared machines that answered and have the agent, the place
// with the fewest working sessions for its weight wins. Each place has a level: Prefer (weight 4), Normal (2), Less
// often (1) or Manual only (never picked automatically). A tie goes to this Mac, then to the machine listed first.
// With no place left, the session starts on this Mac.

/// How often a place is picked automatically.
enum BalanceLevel: String, Codable, CaseIterable, Sendable {
    case prefer, normal, lessOften, manualOnly

    /// Its share of the work: a place with twice the weight takes twice the sessions before another is picked.
    var weight: Int {
        switch self {
        case .prefer: return 4
        case .normal: return 2
        case .lessOften: return 1
        case .manualOnly: return 0
        }
    }
}

enum MachineBalance {
    /// One place a session could run: this Mac (`machineID` nil) or a machine.
    struct Candidate: Equatable, Sendable {
        var machineID: String?
        var level: BalanceLevel
        /// Sessions that work there now.
        var active: Int
        /// It answered, has the agent and, for a machine, knows the project's folder.
        var available: Bool
    }

    /// The place to start on: nil is this Mac, else the machine's id. Pure: the caller says what is available.
    static func pick(_ candidates: [Candidate]) -> String? {
        let usable = candidates.enumerated().filter { $0.element.available && $0.element.level.weight > 0 }
        // Fewest sessions for its weight: active / weight, compared without division (a/b < c/d ⇔ a·d < c·b).
        let best = usable.min { a, b in
            let left = a.element.active * b.element.level.weight
            let right = b.element.active * a.element.level.weight
            if left != right { return left < right }
            // A tie: this Mac first, then the order the places were listed in.
            if (a.element.machineID == nil) != (b.element.machineID == nil) { return a.element.machineID == nil }
            return a.offset < b.offset
        }
        return best?.element.machineID
    }

    /// The machines a project is shared with: those that keep a folder for it.
    static func sharedMachines(_ machines: [RemoteMachine], project: String) -> [RemoteMachine] {
        machines.filter { $0.folder(for: project) != nil }
    }
}

extension RemoteMachine {
    /// How often this machine is picked automatically; Normal until you choose.
    var balanceLevel: BalanceLevel { balance ?? .normal }

    /// The project's folder on this machine, when a session of it ran here.
    func folder(for project: String) -> String? {
        let key = (project as NSString).standardizingPath
        guard !key.isEmpty, let folder = projectFolders?[key], !folder.isEmpty else { return nil }
        return folder
    }

    /// Keeps `folder` as the project's folder on this machine.
    mutating func remember(folder: String, for project: String) {
        let key = (project as NSString).standardizingPath
        guard !key.isEmpty, !folder.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var folders = projectFolders ?? [:]
        folders[key] = folder.trimmingCharacters(in: .whitespaces)
        projectFolders = folders
    }
}

/// This Mac's own level, kept with the machines' levels in the defaults.
enum LocalBalance {
    static let defaultsKey = "agents.localBalance"

    static func level(defaults: UserDefaults = .standard) -> BalanceLevel {
        defaults.string(forKey: defaultsKey).flatMap(BalanceLevel.init(rawValue:)) ?? .normal
    }

    static func set(_ level: BalanceLevel, defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: defaultsKey)
    }
}
