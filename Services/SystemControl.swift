import Foundation
import AppKit

/// Small, deliberate control actions on your Mac. Every action listed here is also registered as a tool with a risk level.
enum SystemControl {
    /// Runs AppleScript and returns the string result. Safe to call from a background thread.
    @discardableResult
    nonisolated static func appleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    /// Like `appleScript`, but also returns the error number. -1743 means: macOS has not granted Nook permission.
    nonisolated static func appleScriptResult(_ source: String) -> (text: String?, errorNumber: Int?) {
        guard let script = NSAppleScript(source: source) else { return (nil, nil) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorNumber] as? Int)
        }
        return (result.stringValue, nil)
    }

    /// Runs an executable with arguments, without a shell, and returns the output.
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
            throw NookError(text.isEmpty ? "The program exited with an error." : String(text.prefix(300)))
        }
        return text
    }

    static func openApp(_ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("-"), !clean.contains("/") else {
            throw NookError("Invalid app name.")
        }
        _ = try runProcess("/usr/bin/open", ["-a", clean])
    }

    static func openURL(_ string: String) throws {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else {
            throw NookError("Only web and email addresses can be opened.")
        }
        NSWorkspace.shared.open(url)
    }

    static func setVolume(_ level: Int) {
        let clamped = max(0, min(100, level))
        _ = appleScript("set volume output volume \(clamped)")
    }

    static func runShortcut(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("-") else { throw NookError("Invalid shortcut name.") }
        return try runProcess("/usr/bin/shortcuts", ["run", clean])
    }
}
