import Foundation

// Android devices next to your sessions: emulators and phones `adb` sees, and the virtual devices that can be started.
// Agents drive them with `adb` in their own shell; Nook shows the screen and takes pictures. Without the Android SDK none of
// this shows. The parsing is Foundation only, tested on its own.

struct AndroidDevice: Equatable, Identifiable, Sendable {
    /// `android:<adb serial>` for a running device, `android-avd:<name>` for a virtual device that is off.
    var id: String
    var name: String
    var running: Bool
    /// The adb serial while it runs.
    var serial: String? = nil
}

enum AndroidDevices {
    static let idPrefix = "android"

    static func isAndroid(_ id: String) -> Bool { id.hasPrefix(idPrefix + ":") || id.hasPrefix(idPrefix + "-avd:") }

    /// The running devices in `adb devices -l`. One that is offline or asks for authorization cannot be used yet.
    static func parseRunning(_ output: String) -> [AndroidDevice] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return AndroidDevice(id: idPrefix + ":" + parts[0], name: model ?? parts[0], running: true, serial: parts[0])
        }
    }

    /// The virtual devices in `emulator -list-avds`, without those already running (`runningNames`). Its log lines are skipped.
    static func parseVirtual(_ output: String, runningNames: Set<String> = []) -> [AndroidDevice] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil && !runningNames.contains($0) }
            .map { AndroidDevice(id: idPrefix + "-avd:" + $0, name: $0.replacingOccurrences(of: "_", with: " "), running: false) }
    }

    /// Where the SDK can be: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or Android Studio's default.
    static func sdkFolders(environment: [String: String], home: String) -> [String] {
        [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func tool(_ relative: String) -> String? {
        sdkFolders(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
            .map { $0 + "/" + relative }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var adb: String? { tool("platform-tools/adb") }
    static var emulator: String? { tool("emulator/emulator") }

    /// Every device there is, running ones first. Synchronous: call off the main thread.
    static func all() -> [AndroidDevice] {
        guard let adb else { return [] }
        let running = (try? ProcessRunner.run(adb, ["devices", "-l"], timeout: 10)).map { parseRunning($0.stdout) } ?? []
        let names = Set(running.compactMap { device in
            device.serial.flatMap { serial in
                (try? ProcessRunner.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 5))?.stdout
                    .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        })
        let virtual = emulator.flatMap { try? ProcessRunner.run($0, ["-list-avds"], timeout: 10) }
            .map { parseVirtual($0.stdout, runningNames: names) } ?? []
        return running + virtual
    }

    /// Starts a virtual device; it keeps running after Nook quits, as it does from Android Studio.
    static func boot(avd: String) throws {
        guard let emulator else { throw NookError("The Android emulator is not installed.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulator)
        process.arguments = ["-avd", avd]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// A PNG of the screen, without touching the phone's storage.
    static func screenshot(serial: String) -> Data? {
        guard let adb else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A device that hangs must not hold the page or the agent: ending adb ends the read below.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    static func shutdown(serial: String) {
        guard let adb else { return }
        _ = try? ProcessRunner.run(adb, ["-s", serial, "emu", "kill"], timeout: 10)
    }

    /// What an agent gets when it opens a device.
    static func quickStart(serial: String) -> String {
        "Drive it with adb in your own shell: adb -s \(serial) shell input tap X Y, shell input text, install app.apk, logcat. device_screenshot shows you the screen."
    }
}
