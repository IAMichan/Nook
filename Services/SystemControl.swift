import Foundation
import AppKit

/// Kleine, bewuste bedieningsacties op je Mac. Elke actie die hier staat is ook als tool met een risiconiveau geregistreerd.
enum SystemControl {
    /// Draait AppleScript en geeft de tekstuitkomst terug. Mag vanaf een achtergrondthread.
    @discardableResult
    nonisolated static func appleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    /// Zoals `appleScript`, maar geeft ook het foutnummer terug. -1743 betekent: macOS heeft Nook geen toestemming gegeven.
    nonisolated static func appleScriptResult(_ source: String) -> (text: String?, errorNumber: Int?) {
        guard let script = NSAppleScript(source: source) else { return (nil, nil) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorNumber] as? Int)
        }
        return (result.stringValue, nil)
    }

    /// Draait een programma met argumenten, zonder shell, en geeft de uitvoer terug.
    nonisolated static func runProcess(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NookError(text.isEmpty ? "Het programma stopte met een fout." : String(text.prefix(300)))
        }
        return text
    }

    static func openApp(_ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("-"), !clean.contains("/") else {
            throw NookError("Ongeldige appnaam.")
        }
        _ = try runProcess("/usr/bin/open", ["-a", clean])
    }

    static func openURL(_ string: String) throws {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else {
            throw NookError("Alleen web- en mailadressen worden geopend.")
        }
        NSWorkspace.shared.open(url)
    }

    static func setVolume(_ level: Int) {
        let clamped = max(0, min(100, level))
        _ = appleScript("set volume output volume \(clamped)")
    }

    static func runShortcut(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("-") else { throw NookError("Ongeldige shortcut-naam.") }
        return try runProcess("/usr/bin/shortcuts", ["run", clean])
    }
}
