import Foundation

/// The sessions known from hooks, saved across restarts of Nook and settled when their agent is gone.
extension AgentHub {
    // MARK: Remembered sessions

    /// What survives a restart of Nook: agents keep running in their terminals, so the sessions known from their hooks
    /// are saved and put back, and listed again straight away instead of waiting for the next hook event.
    private struct SavedRecord: Codable {
        var key: String
        var agentID: String
        var agent: String
        var cwd: String
        var status: String
        var steps: [[String]]
        var file: String
        var lastMessage: String
        var updated: Date
        var started: Date
        var hostBundleID: String
        var home: String
        var sessionID: String
        var transcriptPath: String
        var lastPrompt: String
        var firstPrompt: String?
        var linesAdded: Int
        var linesRemoved: Int
        var turnStarted: Date?
    }

    private nonisolated static var recordsURL: URL { NookPaths.supportDirectory.appendingPathComponent("agent-sessions.json") }


    func scheduleSave() {
        guard !recordsDirty else { return }
        recordsDirty = true
        // After what runs now (a whole hook event, a scan, a prune) is done: all of its writes become one snapshot.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recordsDirty else { return }
                self.recordsDirty = false
                self.saveRecords()
            }
        }
    }

    private func saveRecords() {
        saveWork?.cancel()
        let snapshot = records.map { key, r in
            SavedRecord(key: key, agentID: r.agentID, agent: r.agent, cwd: r.cwd, status: "\(r.status)",
                        steps: r.steps.map { ["\($0.mark)", $0.text] }, file: r.file, lastMessage: r.lastMessage,
                        updated: r.updated, started: r.started, hostBundleID: r.hostBundleID, home: r.home,
                        sessionID: r.sessionID, transcriptPath: r.transcriptPath, lastPrompt: r.lastPrompt,
                        firstPrompt: r.firstPrompt, linesAdded: r.linesAdded, linesRemoved: r.linesRemoved, turnStarted: r.turnStarted)
        }
        // A burst of hook events becomes one write.
        saveWork = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: Self.recordsURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.recordsURL.path)
        }
    }

    func restoreRecords() {
        guard records.isEmpty, let data = try? Data(contentsOf: Self.recordsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([SavedRecord].self, from: data) else { return }
        let now = Date()
        var restored: [String: Record] = [:]
        for item in saved {
            let age = now.timeIntervalSince(item.updated)
            let status: AgentStatus
            switch item.status {
            case "waiting": status = .waiting
            case "failed": status = .failed
            case "done": status = .done
            default: status = .running
            }
            let settled = Self.isSettled(key: item.key, agent: item.agent, sessionID: item.sessionID, cwd: item.cwd,
                                         lastActive: item.updated)
            guard !SessionLiveness.isExpired(done: status == .done || status == .failed, settled: settled, age: age) else { continue }
            let marks: [String: AgentStep.Mark] = ["done": .done, "running": .running, "blocked": .blocked, "failed": .failed, "todo": .todo]
            var record = Record(agentID: item.agentID, agent: item.agent, project: Self.projectName(item.cwd), cwd: item.cwd,
                                status: status, steps: item.steps.compactMap { pair in
                                    guard pair.count == 2, let mark = marks[pair[0]] else { return nil }
                                    return AgentStep(mark: mark, text: pair[1])
                                }, file: item.file, lastMessage: item.lastMessage, updated: item.updated,
                                hostBundleID: item.hostBundleID, diff: [], linesAdded: item.linesAdded, linesRemoved: item.linesRemoved)
            record.home = item.home
            record.sessionID = item.sessionID
            record.transcriptPath = item.transcriptPath
            record.lastPrompt = item.lastPrompt
            // Saved before the first prompt was kept: the prompt known then is the oldest one there is.
            record.firstPrompt = item.firstPrompt ?? item.lastPrompt
            record.started = item.started
            record.turnStarted = status == .done ? nil : item.turnStarted
            restored[item.key] = record
        }
        unconfirmed = Set(restored.keys)
        records = restored
        rebuild()
    }

    /// A restored session that still read as busy while its agent ended with Nook closed is settled as done, the way
    /// `settleStale` settles one whose agent quits while Nook runs. It stays in the list: a restart never takes away a
    /// chat you have not handled. Agents the scanner does not know (apps, custom tools) are left to `settleStale`.
    func settleEndedRestored(_ found: [DetectedAgent]) {
        guard !unconfirmed.isEmpty else { return }
        let scannable = Set(LocalAgentScanner.agentNames)
        var running: [String: Int] = [:]
        for agent in found { running["\(agent.name)|\(agent.cwd)", default: 0] += 1 }
        var changed = false
        for key in unconfirmed.sorted() {
            // A hook event since launch already proves the session is alive.
            guard var record = records[key], record.updated < launchedAt else { continue }
            guard scannable.contains(record.agent), record.status == .running || record.status == .waiting else { continue }
            let id = "\(record.agent)|\(record.cwd)"
            if let count = running[id], count > 0 {
                running[id] = count - 1
            } else {
                record.status = .done
                record.turnStarted = nil
                Self.complete(&record, as: .done)
                Self.push(&record, .done, "session closed")
                records[key] = record
                changed = true
            }
        }
        unconfirmed = []
        if changed { rebuild() }
    }


    static func scanned(_ found: [DetectedAgent]) -> [(pid: Int32, name: String, cwd: String)] {
        found.map { (pid: $0.pid, name: $0.name, cwd: $0.cwd) }
    }

    /// Settles sessions that still read as busy while their turn has ended or their agent has quit, when the hook that
    /// should have said so never came (see `SessionLiveness`).
    func settleStale(_ found: [DetectedAgent]) async {
        let scannable = Set(LocalAgentScanner.agentNames)
        let busy = records.filter { $0.value.status == .running || $0.value.status == .waiting }
        missingScans = missingScans.filter { busy[$0.key] != nil }
        let running = Self.scanned(found)
        for (key, record) in records where record.pid == nil && !record.lineage.isEmpty {
            // Assigning nil again would still trigger `records`' didSet, and with it a save of the whole file.
            if let pid = SessionLiveness.agentProcess(agent: record.agent, lineage: record.lineage, in: running) {
                records[key]?.pid = pid
            }
        }
        guard !busy.isEmpty else { return }
        for key in busy.keys {
            guard let record = records[key] else { continue }
            let gone = scannable.contains(record.agent)
                && !SessionLiveness.isRunning(agent: record.agent, cwd: record.cwd, pid: record.pid, in: running)
            missingScans[key] = gone ? (missingScans[key] ?? 0) + 1 : 0
        }
        let paths = busy.filter { $0.value.status == .running }.mapValues(\.transcriptPath)
        let turns = await Task.detached(priority: .utility) {
            paths.compactMapValues { SessionLiveness.readTurn(path: $0) }
        }.value

        let now = Date()
        var changed = false
        for (key, seen) in busy {
            // A hook event while the transcript was read wins.
            guard var record = records[key], record.updated == seen.updated, record.status == seen.status else { continue }
            if pendingApprovals.values.contains(where: { $0.request.sessionKey == key })
                || pendingQuestions.values.contains(where: { $0.request.sessionKey == key }) { continue }
            let read = turns[key]
            guard let verdict = SessionLiveness.verdict(
                working: record.status == .running, lastEvent: record.updated, turn: read?.turn ?? .unknown,
                transcriptModified: read?.modified, missingScans: missingScans[key] ?? 0, now: now
            ) else { continue }
            record.status = .done
            Self.complete(&record, as: .done)
            Self.push(&record, .done, verdict == .processGone ? "session closed" : "done")
            records[key] = record
            missingScans[key] = nil
            changed = true
            Log.agents.info("Settled stale session \(key, privacy: .public): \(String(describing: verdict), privacy: .public)")
        }
        if changed { rebuild() }
    }

    /// You settled a session that still reads as busy: its turn hangs (a `Stop` that never came, a turn that stays open in
    /// the transcript), so Nook believes you and shows it as done, in the conversation and the notch alike. A question or
    /// approval still open in the notch keeps it waiting; the next prompt or tool call makes it work again.
    func settleByUser(_ key: String) {
        guard var record = records[key], record.status == .running || record.status == .waiting, !isAsking(key) else { return }
        record.status = .done
        record.turnStarted = nil
        Self.complete(&record, as: .done)
        Self.push(&record, .done, "settled by you")
        records[key] = record
        missingScans[key] = nil
        rebuild()
    }
}
