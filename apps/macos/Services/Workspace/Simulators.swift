import Foundation

// The iOS Simulator next to your sessions: the simulators that are
// running, from `xcrun simctl list devices booted -j`, and a picture of the screen, refreshed while you look.
// Foundation only, so tests can use the parsing.

struct SimulatorDevice: Equatable, Identifiable, Sendable {
    var udid: String
    var name: String
    /// "iOS 18.2", from the runtime identifier.
    var runtime: String
    var booted = true

    var id: String { udid }
}

enum Simulators {
    static let xcrun = "/usr/bin/xcrun"

    /// The booted devices in `simctl list devices -j`.
    static func parse(_ data: Data) -> [SimulatorDevice] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = object["devices"] as? [String: Any] else { return [] }
        var result: [SimulatorDevice] = []
        for (runtime, list) in devices {
            for raw in (list as? [[String: Any]]) ?? [] {
                guard (raw["state"] as? String) == "Booted", let udid = raw["udid"] as? String,
                      let name = raw["name"] as? String else { continue }
                result.append(SimulatorDevice(udid: udid, name: name, runtime: runtimeName(runtime)))
            }
        }
        return result.sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → "iOS 18.2".
    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    /// The running simulators; empty without Xcode.
    static func booted() -> [SimulatorDevice] {
        guard let output = try? ProcessRunner.run(xcrun, ["simctl", "list", "devices", "booted", "-j"], timeout: 15),
              output.status == 0 else { return [] }
        return parse(Data(output.stdout.utf8))
    }

    /// A PNG of the device's screen.
    static func screenshot(_ udid: String) -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nook-sim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let output = try? ProcessRunner.run(xcrun, ["simctl", "io", udid, "screenshot", "--type=png", file.path], timeout: 15),
              output.status == 0 else { return nil }
        return try? Data(contentsOf: file)
    }
}

/// What you can change on a simulator from Nook, as `xcrun simctl` arguments.
enum SimulatorAction: Equatable, Sendable {
    case appearance(dark: Bool)
    case textSize(SimulatorTextSize)
    case increaseContrast(Bool)
    case location(latitude: Double, longitude: Double)
    case clearLocation
    case permission(SimulatorPermission, decision: SimulatorPermissionDecision, bundleID: String)
    case openURL(String)
    case launch(bundleID: String)
    case terminate(bundleID: String)
    /// A push notification: the payload is written to a file first (simctl reads it from there).
    case push(bundleID: String, payloadFile: String)

    /// The arguments after `xcrun simctl`, with the device inserted after the verb (as simctl wants it).
    func arguments(udid: String) -> [String] {
        switch self {
        case .appearance(let dark): return ["ui", udid, "appearance", dark ? "dark" : "light"]
        case .textSize(let size): return ["ui", udid, "content_size", size.category]
        case .increaseContrast(let on): return ["ui", udid, "increase_contrast", on ? "enabled" : "disabled"]
        case .location(let latitude, let longitude): return ["location", udid, "set", "\(latitude),\(longitude)"]
        case .clearLocation: return ["location", udid, "clear"]
        case .permission(let service, let decision, let bundle): return ["privacy", udid, decision.rawValue, service.rawValue, bundle]
        case .openURL(let url): return ["openurl", udid, url]
        case .launch(let bundle): return ["launch", udid, bundle]
        case .terminate(let bundle): return ["terminate", udid, bundle]
        case .push(let bundle, let file): return ["push", udid, bundle, file]
        }
    }

    /// A bundle id simctl accepts: reverse-DNS letters, digits, dots and dashes, never an option.
    static func isValidBundleID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 255, !text.hasPrefix("-") else { return false }
        return text.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]*$"#, options: .regularExpression) != nil
    }

    /// A push payload must be a JSON object with an `aps` dictionary.
    static func isValidPushPayload(_ text: String) -> Bool {
        guard let object = text.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else { return false }
        return object["aps"] is [String: Any]
    }
}

/// Four text sizes and the iOS content-size categories behind them.
enum SimulatorTextSize: String, CaseIterable, Identifiable, Sendable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    var category: String {
        switch self {
        case .small: return "small"
        case .standard: return "large"
        case .large: return "extra-extra-large"
        case .extraLarge: return "accessibility-large"
        }
    }
}

enum SimulatorPermission: String, CaseIterable, Identifiable, Sendable {
    case camera, microphone, photos, contacts, calendar, reminders, location, motion
    case mediaLibrary = "media-library"
    case faceID = "faceid"

    var id: String { rawValue }
}

enum SimulatorPermissionDecision: String, CaseIterable, Identifiable, Sendable {
    case grant, revoke, reset

    var id: String { rawValue }
}

extension Simulators {
    /// Runs one action on the device; the error text when simctl refuses.
    static func perform(_ action: SimulatorAction, udid: String) -> String? {
        guard let output = try? ProcessRunner.run(xcrun, ["simctl"] + action.arguments(udid: udid), timeout: 30) else {
            return "xcrun simctl could not be started."
        }
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "simctl failed (\(output.status))." : String(message.prefix(300))
        }
        return nil
    }

    static func boot(_ udid: String) -> String? {
        guard let output = try? ProcessRunner.run(xcrun, ["simctl", "boot", udid], timeout: 120) else { return "xcrun simctl could not be started." }
        // Already booted is fine.
        if output.status == 0 || output.stderr.contains("current state: Booted") { return nil }
        return String(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    static func shutdown(_ udid: String) {
        _ = try? ProcessRunner.run(xcrun, ["simctl", "shutdown", udid], timeout: 60)
    }

    /// Every simulator that is installed (booted or not), for the device picker.
    static func all() -> [SimulatorDevice] {
        guard let output = try? ProcessRunner.run(xcrun, ["simctl", "list", "devices", "available", "-j"], timeout: 20),
              output.status == 0 else { return [] }
        return parseAll(Data(output.stdout.utf8))
    }

    static func parseAll(_ data: Data) -> [SimulatorDevice] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = object["devices"] as? [String: Any] else { return [] }
        var result: [SimulatorDevice] = []
        for (runtime, list) in devices where runtime.contains("iOS") {
            for raw in (list as? [[String: Any]]) ?? [] {
                guard (raw["isAvailable"] as? Bool) != false, let udid = raw["udid"] as? String, let name = raw["name"] as? String else { continue }
                var device = SimulatorDevice(udid: udid, name: name, runtime: runtimeName(runtime))
                device.booted = (raw["state"] as? String) == "Booted"
                result.append(device)
            }
        }
        return result.sorted { ($0.booted ? 0 : 1, $0.name, $0.runtime) < ($1.booted ? 0 : 1, $1.name, $1.runtime) }
    }
}
