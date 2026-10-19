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
        let wrapped = wrapTimeout(source, seconds: max(1, Int(ceil(timeout))))

        // Fast path: if scriptQueue is free, execute in-process via NSAppleScript (~5ms overhead).
        // If scriptQueue is already busy running another connector's script, run in parallel via osascript
        // so concurrent chat lookups (Mail + Notes + Browser) never serialize behind each other.
        if scriptQueueBusy.tryAcquire() {
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var text: String?
                var errorNumber: Int?
            }
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)

            scriptQueue.async {
                defer { scriptQueueBusy.release() }
                guard let script = NSAppleScript(source: wrapped) else {
                    semaphore.signal()
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                box.lock.lock()
                if let error {
                    box.errorNumber = error[NSAppleScript.errorNumber] as? Int
                } else {
                    box.text = result.stringValue
                }
                box.lock.unlock()
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                return (nil, -1712) // errAETimeout
            }
            box.lock.lock()
            defer { box.lock.unlock() }
            return (box.text, box.errorNumber)
        } else {
            return runOsaScript(wrapped, timeout: timeout)
        }
    }

    /// Wraps `tell application` blocks in `with timeout of N seconds` so macOS aborts stalled AppleEvents at the Mach level.
    private nonisolated static func wrapTimeout(_ source: String, seconds: Int) -> String {
        guard source.contains("tell application"), !source.contains("with timeout") else { return source }
        return "with timeout of \(seconds) seconds\n\(source)\nend timeout"
    }

    /// Parallel out-of-process AppleScript runner with hard process termination on timeout.
    private nonisolated static func runOsaScript(_ source: String, timeout: TimeInterval) -> (text: String?, errorNumber: Int?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (nil, nil)
        }

        final class DataBox: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let dataBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            dataBox.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            dataBox.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (nil, -1712)
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            var text = String(data: dataBox.out, encoding: .utf8) ?? ""
            if text.hasSuffix("\n") { text.removeLast() }
            return (text, nil)
        } else {
            let errText = String(data: dataBox.err, encoding: .utf8) ?? ""
            if errText.contains("-1743") { return (nil, -1743) }
            if errText.contains("-1712") { return (nil, -1712) }
            if let range = errText.range(of: #"\(-?\d+\)"#, options: .regularExpression) {
                let numStr = errText[range].dropFirst().dropLast()
                if let code = Int(numStr) { return (nil, code) }
            }
            return (nil, Int(process.terminationStatus))
        }
    }

    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false
        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if busy { return false }
            busy = true
            return true
        }
        func release() {
            lock.lock()
            busy = false
            lock.unlock()
        }
    }

    private static let scriptQueueBusy = AtomicFlag()
    private static let scriptQueue = DispatchQueue(label: "nl.imdigital.nook.applescript", qos: .userInitiated)

    /// Runs an executable with arguments, without a shell, and returns the output. Hard-terminates if `timeout` elapses.
    nonisolated static func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 15.0) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()

        final class OutputBox: @unchecked Sendable {
            var data = Data()
        }
        let box = OutputBox()
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            sema.signal()
        }
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw NookError("The program took too long to respond.")
        }
        process.waitUntilExit()
        let text = String(data: box.data, encoding: .utf8) ?? ""
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
        if (try? runProcess("/usr/bin/open", ["-a", clean])) != nil { return }
        // Not by that name: the installed app it is closest to, also by its name in your language ("Rekenmachine").
        let apps = installedApps()
        guard let match = Fuzzy.best(clean, in: Array(apps.keys)), let path = apps[match] else {
            throw NookError("No app named \(clean) found on this Mac.")
        }
        _ = try runProcess("/usr/bin/open", [path])
    }

    /// Installed apps by their shown (localized) name and their file name, to their path.
    static func installedApps() -> [String: String] {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var apps: [String: String] = [:]
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let path = folder + "/" + name
                apps[String(name.dropLast(4))] = path
                apps[FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")] = path
            }
        }
        return apps
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
