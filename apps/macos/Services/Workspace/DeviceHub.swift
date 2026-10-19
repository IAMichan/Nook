import Foundation

// The iOS Simulator: expo-device-hub (with serve-sim) runs on this Mac on a loopback port, streams the
// screen as MJPEG and takes touches, buttons, keys and rotation over a WebSocket; agent-device lets agents drive the app
// (snapshot, click, fill). This is the part without AppKit or networking: versions and paths, command lines, the hub's
// answers, the input frames and the coordinate rules. Foundation only, so tests can use it.

enum DeviceHub {
    /// The pinned versions.
    static let hubPackage = "expo-device-hub"
    static let hubVersion = "0.15.3"
    static let agentPackage = "agent-device"
    static let agentVersion = "0.21.25"

    // MARK: Install and launch

    /// `<root>/<package>/<version>`: one folder per version, complete once its sentinel says so.
    static func installFolder(root: URL, package: String, version: String) -> URL {
        root.appendingPathComponent(package, isDirectory: true).appendingPathComponent(version, isDirectory: true)
    }

    static func hubEntry(_ folder: URL) -> URL {
        folder.appendingPathComponent("node_modules/expo-device-hub/dist/server/cli.mjs")
    }

    static func agentEntry(_ folder: URL) -> URL {
        folder.appendingPathComponent("node_modules/agent-device/bin/agent-device.mjs")
    }

    static let sentinelName = ".install-complete"

    static func sentinel(version: String) -> String { version + "\n" }

    static func npmInstallArguments(prefix: String, package: String, version: String) -> [String] {
        ["install", "--prefix", prefix, "--no-fund", "--no-audit", "\(package)@\(version)"]
    }

    static func hubArguments(entry: String, port: Int) -> [String] {
        [entry, "--port", String(port), "--host", "127.0.0.1", "--hide-sidebar", "--hide-boot-device"]
    }

    static let quietEnvironment = ["FORCE_COLOR": "0", "NO_COLOR": "1"]

    /// After the hub exits: 1 s, doubling up to 30 s; back to the start once it had run a minute.
    static func restartDelay(previous: TimeInterval, upFor: TimeInterval) -> TimeInterval {
        if upFor >= 60 { return 1 }
        return previous <= 0 ? 1 : min(30, previous * 2)
    }

    // MARK: Hub answers

    struct Device: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var version: String
        var booted: Bool
    }

    /// `GET /api/devices`: the iOS simulators, and the hub's own complaints joined.
    static func devices(_ data: Data) -> (devices: [Device], problem: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        let devices = ((object["simulators"] as? [[String: Any]]) ?? []).compactMap { raw -> Device? in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String, (raw["physical"] as? Bool) != true else { return nil }
            return Device(id: id, name: name, version: (raw["version"] as? String) ?? "", booted: (raw["booted"] as? Bool) == true)
        }
        let problems = ((object["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
        return (devices, problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }

    enum BootFailure: String, Equatable { case diskSpace, timeout, launchFailed }

    static func bootFailure(_ message: String) -> BootFailure {
        let text = message.lowercased()
        if text.range(of: #"insufficient.*(disk|space)|not enough.*(disk|space)|no space left"#, options: .regularExpression) != nil { return .diskSpace }
        if text.range(of: #"timed? out|timeout"#, options: .regularExpression) != nil { return .timeout }
        return .launchFailed
    }

    static func avccPath(udid: String) -> String { "/vendor/serve-sim/helper/\(escaped(udid))/stream.avcc" }
    static func mjpegPath(udid: String) -> String { "/vendor/serve-sim/helper/\(escaped(udid))/stream.mjpeg" }
    static func inputPath(udid: String) -> String { "/vendor/serve-sim/helper/ws?device=\(escaped(udid))" }
    static func screenshotPath(udid: String) -> String { "/vendor/serve-sim/api/screenshot?device=\(escaped(udid))" }
    static let startPath = "/vendor/serve-sim/grid/api/start"
    static let shutdownPath = "/vendor/serve-sim/grid/api/shutdown"
    static let bootPath = "/api/devices/boot"
    static let devicesPath = "/api/devices"
    static let readyPath = "/readyz"

    private static func escaped(_ udid: String) -> String {
        udid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? udid
    }

    // MARK: Input

    enum Orientation: String, CaseIterable, Sendable {
        case portrait
        case landscapeLeft = "landscape_left"
        case portraitUpsideDown = "portrait_upside_down"
        case landscapeRight = "landscape_right"

        /// The rotate button: portrait, landscape left, upside down, landscape right, and round again.
        var next: Orientation {
            let all = Orientation.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }

        /// How the picture is turned on screen.
        var degrees: Double {
            switch self {
            case .portrait: return 0
            case .landscapeLeft: return 90
            case .landscapeRight: return -90
            case .portraitUpsideDown: return 180
            }
        }
    }

    enum Touch: String { case begin, move, end }
    enum Button: String { case home, appSwitcher = "app_switcher", lock }

    static func touchFrame(_ phase: Touch, x: Double, y: Double) -> Data {
        frame(0x03, ["type": phase.rawValue, "x": clamp(x), "y": clamp(y)])
    }

    static func buttonFrame(_ button: Button) -> Data { frame(0x04, ["button": button.rawValue]) }

    static func keyFrame(down: Bool, usage: Int) -> Data { frame(0x06, ["type": down ? "down" : "up", "usage": usage]) }

    static func orientationFrame(_ orientation: Orientation) -> Data { frame(0x07, ["orientation": orientation.rawValue]) }

    private static func frame(_ tag: UInt8, _ payload: [String: Any]) -> Data {
        var data = Data([tag])
        data.append((try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8))
        return data
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }

    struct ScreenConfig: Equatable, Sendable {
        var width: Double
        var height: Double
        var orientation: Orientation
        var inputUnavailable: Bool

        /// Width over height of the picture as shown (turned in landscape); 9/19.5 before the first config.
        var aspect: Double {
            let long = max(width, height), short = min(width, height)
            guard short > 0 else { return 9 / 19.5 }
            return orientation == .landscapeLeft || orientation == .landscapeRight ? long / short : short / long
        }
    }

    enum ServerMessage: Equatable {
        case config(ScreenConfig)
        case admitted
        case other
    }

    static func serverMessage(_ data: Data) -> ServerMessage {
        guard let tag = data.first else { return .other }
        switch tag {
        case 0x83: return .admitted
        case 0x82:
            guard let object = (try? JSONSerialization.jsonObject(with: data.dropFirst())) as? [String: Any],
                  let width = (object["width"] as? NSNumber)?.doubleValue, let height = (object["height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return .other }
            let orientation = (object["orientation"] as? String).flatMap(Orientation.init(rawValue:)) ?? .portrait
            return .config(ScreenConfig(width: width, height: height, orientation: orientation,
                                        inputUnavailable: (object["inputUnavailable"] as? Bool) == true))
        default: return .other
        }
    }

    /// A point on the picture as shown (0…1 each way) to the device's own portrait framebuffer, which is what serve-sim
    /// takes. Only when the framebuffer is portrait (width ≤ height); otherwise it passes as it is.
    static func devicePoint(x: Double, y: Double, config: ScreenConfig?) -> (x: Double, y: Double) {
        let x = clamp(x), y = clamp(y)
        guard let config, config.width <= config.height else { return (x, y) }
        switch config.orientation {
        case .portrait: return (x, y)
        case .landscapeLeft: return (y, 1 - x)
        case .landscapeRight: return (1 - y, x)
        case .portraitUpsideDown: return (1 - x, 1 - y)
        }
    }

    /// HID usages by macOS virtual key code (the physical key maps `KeyboardEvent.code`): letters, digits,
    /// punctuation, editing keys, arrows and modifiers. Other keys are not sent.
    static let hidUsage: [UInt16: Int] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C,
        0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15,
        0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30,
        0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, 0x75: 0x4C,
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,
        0x3B: 0xE0, 0x38: 0xE1, 0x3A: 0xE2, 0x37: 0xE3, 0x3E: 0xE4, 0x3C: 0xE5, 0x3D: 0xE6, 0x36: 0xE7,
    ]

    /// Keys pressed with ⌘ stay with Nook (copy, quit…), except ⌘R, which reloads a React Native app: its R goes through.
    static func forwardsKey(keyCode: UInt16, command: Bool) -> Bool {
        guard hidUsage[keyCode] != nil else { return false }
        if keyCode == 0x37 || keyCode == 0x36 { return false }
        return !command || keyCode == 0x0F
    }

    /// A scroll on the trackpad as a swipe: serve-sim has no scroll, so it becomes a drag from the middle.
    static func swipe(dx: Double, dy: Double, from point: (x: Double, y: Double) = (0.5, 0.5), steps: Int = 6) -> [(x: Double, y: Double)] {
        (0...steps).map { step in
            let t = Double(step) / Double(steps)
            return (clamp(point.x + dx * t), clamp(point.y + dy * t))
        }
    }

    // MARK: agent-device

    /// A short stable id (FNV-1a, 64-bit, hex) for agent-device sessions and config files.
    static func stableID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }

    static func agentSession(runID: String, deviceID: String) -> String { "nook-" + stableID(runID + "|" + deviceID) }

    static func agentConfig(port: Int, token: String) -> String {
        let object: [String: Any] = ["daemonBaseUrl": "http://127.0.0.1:\(port)", "daemonAuthToken": token]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func agentEnvironment(stateDir: String) -> [String: String] {
        ["AGENT_DEVICE_STATE_DIR": stateDir, "AGENT_DEVICE_DAEMON_SERVER_MODE": "http", "AGENT_DEVICE_DAEMON_IDLE_TIMEOUT_MS": "0",
         "AGENT_DEVICE_NO_UPDATE_NOTIFIER": "1", "FORCE_COLOR": "0", "NO_COLOR": "1"]
    }

    /// `daemon.json`: the port and token of the running agent-device daemon.
    static func daemon(_ data: Data) -> (port: Int, token: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = (object["httpPort"] as? NSNumber)?.intValue, let token = object["token"] as? String, port > 0 else { return nil }
        return (port, token)
    }

    /// The command agents run: refuses to work without the --config and --session that device_open hands out.
    static func shimScript(node: String, launcher: String) -> String {
        "#!/bin/sh\nexec \(quote(node)) \(quote(launcher)) \"$@\"\n"
    }

    static func launcherScript(node: String, entry: String) -> String {
        """
        import { spawn } from "node:child_process";
        const args = process.argv.slice(2);
        const help = args.length === 1 && ["help", "--help", "-h", "--version", "version"].includes(args[0]);
        const value = (flag) => { const i = args.indexOf(flag); return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : undefined; };
        if (!help && (!value("--config") || !value("--session"))) {
          console.error("Call device_open first and include its --config and --session flags.");
          process.exit(1);
        }
        const env = { ...process.env };
        delete env.AGENT_DEVICE_DAEMON_BASE_URL; delete env.AGENT_DEVICE_DAEMON_AUTH_TOKEN; delete env.AGENT_DEVICE_CONFIG;
        const child = spawn(\(json(node)), [\(json(entry)), ...args], { stdio: "inherit", env });
        child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
        """
    }

    /// What device_open tells the agent: a quick start.
    static func quickStart(device: String, version: String, command: String, targetArgs: [String]) -> String {
        let x = shellQuote(command)
        let t = targetArgs.map(shellQuote).joined(separator: " ")
        return [
            "The user is watching \(device) (\(version)) in Nook's Simulator page.",
            "Drive it with \(x). Use this exact executable path; login shells may reset PATH. Always pass \(t).",
            "Typical loop:",
            "  \(x) open <bundle-id> \(t)     # or: open <app> <deep-link-url>",
            "  \(x) snapshot -i \(t)     # accessibility tree with @eN refs",
            "  \(x) click @e3 \(t)",
            "  \(x) fill @e5 \"text\" \(t)",
            "  \(x) screenshot /tmp/shot.png \(t)     # or call device_screenshot",
            "  \(x) install <app> <path-to-.app> \(t)",
            "Prefer snapshot refs over coordinates. Run \(x) help for workflow guides and \(x) <command> --help for flags.",
            "Prefer agent-device for driving this device. simctl and xcrun remain available for anything it does not cover.",
            "Keep the returned --config and --session flags on every command.",
            "First use builds an XCTest runner and can take a couple of minutes; later commands are fast.",
        ].joined(separator: "\n")
    }

    static func shellQuote(_ text: String) -> String {
        text.range(of: #"^[a-zA-Z0-9_./:-]+$"#, options: .regularExpression) != nil ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func json(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) } ?? "\"\""
    }

    /// Width and height of a PNG, from its header.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func u32(_ offset: Int) -> Int { data[data.startIndex + offset ..< data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (u32(16), u32(20))
    }
}

/// Cuts an MJPEG stream (multipart/x-mixed-replace) into its JPEG pictures: each runs from its start marker (FF D8) to
/// its end marker (FF D9), whatever the part headers and boundary say.
struct MjpegParser {
    private var buffer = Data()
    private static let start = Data([0xFF, 0xD8])
    private static let end = Data([0xFF, 0xD9])
    /// More than this without a complete picture is not a stream worth keeping.
    static let maxBuffer = 16 * 1024 * 1024

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let begin = buffer.range(of: Self.start) {
            guard let finish = buffer.range(of: Self.end, in: begin.upperBound..<buffer.endIndex) else {
                // Keep from the start marker on: the picture is still coming.
                if begin.lowerBound > buffer.startIndex { buffer = Data(buffer[begin.lowerBound...]) }
                break
            }
            frames.append(Data(buffer[begin.lowerBound..<finish.upperBound]))
            buffer = Data(buffer[finish.upperBound...])
        }
        if buffer.range(of: Self.start) == nil { buffer = Data(buffer.suffix(1)) }
        if buffer.count > Self.maxBuffer { buffer = Data() }
        return frames
    }
}

/// One piece of serve-sim's H.264 stream (`stream.avcc`): `[u32 big-endian length][tag][payload]`.
struct AvccChunk: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        /// The decoder setup: an avcC record (SPS and PPS).
        case description = 1
        /// A frame that decodes on its own, then the ones that build on it (AVCC length-prefixed NAL units).
        case keyframe = 2
        case delta = 3
        /// A JPEG still to show until the first frame is decoded.
        case seed = 4
    }

    var kind: Kind
    var payload: Data
}

/// Cuts the AVCC stream into its chunks as bytes arrive; unknown tags are skipped.
struct AvccDemuxer {
    private var buffer = Data()
    static let maxChunk = 32 * 1024 * 1024

    mutating func push(_ data: Data) -> [AvccChunk] {
        buffer.append(data)
        var chunks: [AvccChunk] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = buffer[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxChunk else {
                buffer = Data()
                return chunks
            }
            guard buffer.endIndex - offset - 4 >= length else { break }
            if length >= 1, let kind = AvccChunk.Kind(rawValue: buffer[offset + 4]) {
                chunks.append(AvccChunk(kind: kind, payload: Data(buffer[(offset + 5)..<(offset + 4 + length)])))
            }
            offset += 4 + length
        }
        if offset > buffer.startIndex { buffer = Data(buffer[offset...]) }
        return chunks
    }

    mutating func reset() { buffer = Data() }
}

/// The decoder setup in an avcC record (ISO 14496-15): the parameter sets and how long each NAL unit's length prefix is.
struct AvcConfiguration: Equatable, Sendable {
    var sps: [Data]
    var pps: [Data]
    var nalLengthSize: Int

    init?(_ record: Data) {
        let bytes = [UInt8](record)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        var index = 5
        /// `count` parameter sets, each a 16-bit length and its bytes, from `index` on.
        func sets(_ count: Int) -> [Data]? {
            var result: [Data] = []
            for _ in 0..<count {
                guard index + 2 <= bytes.count else { return nil }
                let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                index += 2
                guard length > 0, index + length <= bytes.count else { return nil }
                result.append(Data(bytes[index..<index + length]))
                index += length
            }
            return result
        }
        let spsCount = Int(bytes[5] & 0x1F)
        index = 6
        guard let sps = sets(spsCount), !sps.isEmpty, index < bytes.count else { return nil }
        let ppsCount = Int(bytes[index])
        index += 1
        guard let pps = sets(ppsCount), !pps.isEmpty else { return nil }
        self.sps = sps
        self.pps = pps
        nalLengthSize = Int(bytes[4] & 0x03) + 1
    }

    /// "avc1.64001f": the codec from profile, compatibility and level.
    static func codecString(_ record: Data) -> String {
        let bytes = [UInt8](record)
        guard bytes.count >= 4 else { return "avc1" }
        return "avc1." + bytes[1...3].map { String(format: "%02x", $0) }.joined()
    }
}
