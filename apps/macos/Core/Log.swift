import Foundation
import os
import OSLog

/// Structured logging per area, visible in Console.app (subsystem nl.imdigital.nook). Never log keys, tokens or message text.
enum Log {
    private static let subsystem = "nl.imdigital.nook"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let brain = Logger(subsystem: subsystem, category: "brain")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let agents = Logger(subsystem: subsystem, category: "agents")
    static let connectors = Logger(subsystem: subsystem, category: "connectors")
    static let actions = Logger(subsystem: subsystem, category: "actions")
    static let autocomplete = Logger(subsystem: subsystem, category: "autocomplete")
    /// How hard the Mac is pressed and what Nook does about it (`AgentGovernor`, `EnergyMonitor`): the readings behind each
    /// change, so the thresholds can be checked against a real slowdown with
    /// `log show --predicate 'subsystem == "nl.imdigital.nook" AND category == "resources"' --info --last 1d`.
    static let resources = Logger(subsystem: subsystem, category: "resources")
}

extension Log {
    /// What this Nook logged since `since` (not debug lines), for a diagnostics export (`DiagnosticsLog`), with private
    /// values left out (`DiagnosticsLog.message`). Reads the system's log store for this process only; slow enough to
    /// call off the main thread.
    static func recentEntries(since: Date) -> [DiagnosticsLog.Entry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since),
                                                  matching: NSPredicate(format: "subsystem == %@", subsystem)) else { return [] }
        return entries.compactMap { entry -> DiagnosticsLog.Entry? in
            guard let log = entry as? OSLogEntryLog, log.level != .debug else { return nil }
            let level: String
            switch log.level {
            case .fault: level = "fault"
            case .error: level = "error"
            case .notice: level = "notice"
            case .info: level = "info"
            default: level = "log"
            }
            // Rebuilt from its pieces: `composedMessage` shows private values within this process.
            let pieces = log.components.map { part -> DiagnosticsLog.Piece in
                let number: Bool
                switch part.argumentCategory {
                case .int64, .uInt64, .double: number = true
                default: number = false
                }
                return DiagnosticsLog.Piece(text: part.formatSubstring, placeholder: part.placeholder, isNumber: number,
                                            value: number ? part.argumentNumberValue?.stringValue : part.argumentStringValue)
            }
            return DiagnosticsLog.Entry(date: log.date, category: log.category, level: level,
                                        message: DiagnosticsLog.message(pieces))
        }
    }
}
