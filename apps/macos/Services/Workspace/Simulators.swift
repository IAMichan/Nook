import Foundation

// The iOS Simulator next to your sessions: the simulators that are
// running, from `xcrun simctl list devices booted -j`, and a picture of the screen, refreshed while you look.
// Foundation only, so tests can use the parsing.

struct SimulatorDevice: Equatable, Identifiable, Sendable {
    var udid: String
    var name: String
    /// "iOS 18.2", from the runtime identifier.
    var runtime: String

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
