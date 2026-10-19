import Foundation

extension ProjectScriptError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyCommand: return tr("agents.panel.script.noCommand")
        case .unreadable: return tr("agents.panel.script.unreadable")
        }
    }
}
