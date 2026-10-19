import Foundation

/// A local server a session started: a process working in the session's folder that listens on a TCP port.
struct DevServer: Equatable, Identifiable, Sendable {
    var pid: Int32
    var command: String
    var port: Int
    var id: Int { port }
    /// Always opened on localhost: a server listening on all addresses answers there too.
    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Finds the dev servers of a folder: every listening TCP socket on this Mac (`lsof`), kept
/// when the process works in the folder (or below it). No network traffic; `lsof` only reads this Mac's own table.
enum DevServerScanner {
    /// Ports that are never a page to open (databases, caches, debuggers).
    private static let skippedPorts: Set<Int> = [22, 53, 3306, 5432, 6379, 9229, 9222, 27017, 11211]

    static func scan(folder: String) -> [DevServer] {
        let root = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        guard !root.isEmpty, root != "/" else { return [] }
        guard let listing = run(["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return [] }
        let listeners = parseListeners(listing)
        guard !listeners.isEmpty else { return [] }
        let pids = Set(listeners.map(\.pid)).map(String.init).joined(separator: ",")
        let folders = run(["-a", "-d", "cwd", "-p", pids, "-F", "pn"]).map(parseFolders) ?? [:]
        return listeners.filter { server in
            guard let cwd = folders[server.pid] else { return false }
            return cwd == root || cwd.hasPrefix(root + "/")
        }
    }

    /// `lsof -F pcn` output: `p<pid>`, `c<command>`, then `n<address>` per socket. One server per port (IPv4 and IPv6
    /// listeners of the same process are the same server), sorted by port.
    static func parseListeners(_ output: String) -> [DevServer] {
        var servers: [Int: DevServer] = [:]
        var pid: Int32?
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
                      !skippedPorts.contains(port), servers[port] == nil else { continue }
                servers[port] = DevServer(pid: pid, command: command, port: port)
            default:
                continue
            }
        }
        return servers.values.sorted { $0.port < $1.port }
    }

    /// `lsof -a -d cwd -F pn` output: the working folder per process.
    static func parseFolders(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int32(value) } else if tag == "n", let pid { result[pid] = value }
        }
        return result
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
