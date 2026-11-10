import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A local server a session started: a process working in the session's folder that listens on a TCP port.
struct DevServer: Equatable, Identifiable, Sendable {
    var pid: Int32
    var command: String
    var port: Int
    /// Started by Nook: from one of its terminals or by an agent it runs. Only such a server gets a Stop button.
    var startedByNook = false
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

/// Whether Nook may stop a dev server: only one it started itself, from one of its terminals or through an agent it runs.
/// A server you started in another terminal app is yours to stop there. Matched by pid and process group only, never by
/// name, and checked again right before the stop, so a pid the system gave to another program meanwhile is never hit.
enum DevServerOwnership {
    /// What Nook started: its own process, the shells of its terminals, and the process groups its agents run in.
    struct Roots: Equatable, Sendable {
        var processes: Set<Int32>
        var groups: Set<Int32>

        /// Nook itself, the terminal `shells` and the agents' groups (`ProcessGroupLedger`).
        static func current(shells: [Int32]) -> Roots {
            var groups: Set<Int32> = []
            for entry in ProcessGroupLedger.current?.entries() ?? [] { groups.insert(entry.groupID) }
            return Roots(processes: Set(shells.filter { $0 > 0 }).union([getpid()]), groups: groups)
        }
    }

    /// `pid` runs below one of the roots, or in an agent's process group (a server an agent left running after its shell
    /// ended is handed to launchd, but keeps its group).
    static func startedByNook(pid: Int32, group: Int32?, roots: Roots, parent: (Int32) -> Int32?) -> Bool {
        guard pid > 1 else { return false }
        if let group, roots.groups.contains(group) { return true }
        return ProcessTree.descends(pid, from: roots.processes, parent: parent)
    }

    /// Marks each server Nook started.
    static func mark(_ servers: [DevServer], roots: Roots) -> [DevServer] {
        servers.map { server in
            var server = server
            server.startedByNook = startedByNook(pid: server.pid, group: ProcessTree.group(of: server.pid), roots: roots,
                                                 parent: ProcessTree.parent(of:))
            return server
        }
    }

    /// Stops a server Nook started, with the processes in its group (a wrapper's workers). When that group must live on
    /// (Nook's own, an agent's, a terminal's shell), the server and the processes it started stop instead. False when it is
    /// not (or no longer) Nook's.
    @discardableResult
    static func stop(_ server: DevServer, roots: Roots) -> Bool {
        let group = ProcessTree.group(of: server.pid)
        guard startedByNook(pid: server.pid, group: group, roots: roots, parent: ProcessTree.parent(of:)) else { return false }
        let protected = protectedGroups(roots)
        let target = ProcessTree.stopTarget(pid: server.pid, group: group, protectedGroups: protected)
        if case .process = target {
            for child in ProcessTree.descendants(of: server.pid, children: ProcessTree.children(of:)).reversed() {
                ProcessTree.stop(.process(child))
            }
        }
        ProcessTree.stop(target)
        return true
    }

    /// The groups a stop never takes down: Nook's, the agents', and each terminal shell's (a shell leads its own group).
    static func protectedGroups(_ roots: Roots) -> Set<Int32> {
        roots.groups.union(roots.processes).union([getpgrp()])
    }
}

/// Keeps only the listeners that serve a page, so a database, debugger or language server working in the folder is not
/// offered as something to open. Only ports that already belong to the session's folder
/// are asked, never an unknown port: some servers that speak their own protocol fall over on a stray HTTP request.
enum DevServerProbe {
    /// A page: a redirect that says where to (a login, `/` → `/app`), or a 2xx answer with HTML. A 204/205 is no page, nor
    /// JSON or plain text (an API).
    static func isWebPage(status: Int, contentType: String?, location: String?) -> Bool {
        if (300..<400).contains(status) { return !(location ?? "").isEmpty }
        guard (200..<300).contains(status), status != 204, status != 205 else { return false }
        let type = (contentType ?? "").lowercased()
        return type.contains("text/html") || type.contains("application/xhtml+xml")
    }

    /// The servers that answer as a page. A server the project names itself (`pid` 0, its `previewUrl`) is kept as is.
    static func pages(_ servers: [DevServer]) async -> [DevServer] {
        var kept: [DevServer] = []
        for server in servers {
            if server.pid == 0 { kept.append(server); continue }
            if await cache.isPage(server) { kept.append(server) }
        }
        return kept
    }

    private static let cache = ProbeCache()

    /// Answers are kept for 15 seconds per process and port, so the scan every few seconds does not knock on every port.
    private actor ProbeCache {
        private var answers: [String: (page: Bool, at: Date)] = [:]

        func isPage(_ server: DevServer) async -> Bool {
            let key = "\(server.pid):\(server.port)"
            if let hit = answers[key], Date().timeIntervalSince(hit.at) < 15 { return hit.page }
            var page = await DevServerProbe.ask(URL(string: "http://127.0.0.1:\(server.port)/")!)
            if !page { page = await DevServerProbe.ask(URL(string: "https://localhost:\(server.port)/")!) }
            answers[key] = (page, Date())
            if answers.count > 64 { answers = answers.filter { Date().timeIntervalSince($0.value.at) < 15 } }
            return page
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1.5
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    fileprivate static func ask(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        return await withCheckedContinuation { continuation in
            session.dataTask(with: request) { _, response, _ in
                guard let http = response as? HTTPURLResponse else { return continuation.resume(returning: false) }
                continuation.resume(returning: isWebPage(status: http.statusCode,
                                                         contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                                         location: http.value(forHTTPHeaderField: "Location")))
            }.resume()
        }
    }
}
