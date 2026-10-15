import Foundation
import os

/// Structured logging per area, visible in Console.app (subsystem nl.imdigital.nook). Never log keys, tokens or message text.
enum Log {
    private static let subsystem = "nl.imdigital.nook"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let brain = Logger(subsystem: subsystem, category: "brain")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let agents = Logger(subsystem: subsystem, category: "agents")
    static let connectors = Logger(subsystem: subsystem, category: "connectors")
    static let actions = Logger(subsystem: subsystem, category: "actions")
}
