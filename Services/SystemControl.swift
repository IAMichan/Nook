import Foundation
import AppKit

/// Small, deliberate control actions on your Mac. Every action listed here is also registered as a tool with a risk level.
enum SystemControl {
    /// Runs AppleScript and returns the string result. Safe to call from a background thread.
    @discardableResult
    nonisolated static func appleScript(_ source: String, timeout: TimeInterval = 4.0) -> String? {
        appleScriptResult(source, timeout: timeout).text
    }

    /// Like `appleScript`, but also returns the error number. -1743 means: macOS has not granted Nook permission.
    nonisolated static func appleScriptResult(_ source: String, timeout: TimeInterval = 4.0) -> (text: String?, errorNumber: Int?) {
        let semaphore = DispatchSemaphore(value: 0)
        var text: String?
        var errorNum: Int?

        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else {
                semaphore.signal()
                return
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                errorNum = error[NSAppleScript.errorNumber] as? Int
            } else {
                text = result.stringValue
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return (nil, -1712) // errAETimeout
        }
        return (text, errorNum)
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
        // Read data before waitUntilExit to avoid pipe buffer deadlocks
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
