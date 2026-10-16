import SwiftUI
import AppKit

// MARK: Apple Notes (Notities)

/// Toegang tot Apple Notities op je Mac via AppleScript (bliksemsnel en volledig lokaal).
@MainActor
final class NotesConnector: ContextSource {
    struct NoteSummary: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var date: String
        var folder: String
    }

    struct CachedNote: Sendable {
        var id: String
        var name: String
        var date: String
        var folder: String
        var body: String
        var cachedAt: Date
    }

    let id = "notes"
    let title = "Notities"
    let symbol = "note.text"
    let accent = Color(hex: 0xF5C518)
    private(set) var status = ConnectorStatus()
    private var recentNotes: [NoteSummary] = []
    private var totalCount = 0
    private var loadedAt: Date?
    private static var bodyCache: [String: CachedNote] = [:]

    var isActive: Bool { ConnectorToggle.isOn(id) && (ScriptText.isRunning("com.apple.Notes") || !recentNotes.isEmpty) }
    var canLookUp: Bool { ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 120 }
    var isFresh: Bool { loadedAt.map { Date().timeIntervalSince($0) < 90 } ?? false }

    /// Zorgt dat Notities draait indien nodig voor een zoekactie.
    static func ensureRunning() async throws {
        guard !ScriptText.isRunning("com.apple.Notes") else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
            throw NookError("Apple Notities staat niet op deze Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<50 where !ScriptText.isRunning("com.apple.Notes") {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func refresh() async {
        guard ScriptText.isRunning("com.apple.Notes") else {
            status = ConnectorStatus(state: .ok, headline: "Notities beschikbaar", detail: "Wordt doorzocht op aanvraag", updated: Date())
            return
        }

        let script = """
        tell application "Notes"
            set total to count of notes
            set n to total
            if n > 20 then set n to 20
            set out to (total as string) & linefeed
            repeat with i from 1 to n
                set notitem to note i
                set nname to name of notitem
                set nid to id of notitem
                set ndate to ((modification date of notitem) as «class isot» as string)
                set nfolder to ""
                try
                    set nfolder to name of container of notitem
                end try
                set out to out & nid & "|||" & nname & "|||" & ndate & "|||" & nfolder & linefeed
            end repeat
            return out
        end tell
        """

        let result = await ScriptText.run(script, timeout: 5)
        if result.errorNumber == -1743 {
            status = ConnectorStatus(state: .error("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering."))
            return
        }
        guard let text = result.text else {
            status = ConnectorStatus(state: .error("Notities gaf geen antwoord."))
            return
        }

        var lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        totalCount = Int(lines.first ?? "") ?? 0
        if !lines.isEmpty { lines.removeFirst() }

        recentNotes = lines.compactMap { line in
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 3 else { return nil }
            return NoteSummary(
                id: parts[0],
                name: parts[1],
                date: parts[2],
                folder: parts.count > 3 ? parts[3] : ""
            )
        }
        loadedAt = Date()

        status = ConnectorStatus(
            state: .ok,
            headline: totalCount == 0 ? "Geen notities" : "\(totalCount) notities",
            detail: recentNotes.first.map { "Laatste: \($0.name)" } ?? "",
            items: recentNotes.prefix(5).map {
                ConnectorItem(
                    id: $0.id,
                    title: $0.name,
                    subtitle: $0.folder.isEmpty ? String($0.date.prefix(10)) : "\($0.folder) · \(String($0.date.prefix(10)))"
                )
            },
            updated: Date()
        )
    }

    func contextLines() -> [String] {
        guard !recentNotes.isEmpty else { return [] }
        var lines = ["Notities (Apple Notities, \(totalCount) notities in totaal):"]
        for note in recentNotes.prefix(8) {
            let folder = note.folder.isEmpty ? "" : " [map: \(note.folder)]"
            lines.append("- \(note.name)\(folder) | gewijzigd \(String(note.date.prefix(10))) | id \(note.id)")
        }
        return lines
    }

    private static func formatNoteList(_ summaries: [NoteSummary]) -> String {
        guard !summaries.isEmpty else { return "Geen notities gevonden in Apple Notities." }
        var outputLines: [String] = ["Recente notities in Apple Notities:"]
        var refs: [String] = []
        for (index, item) in summaries.enumerated() {
            let folder = item.folder.isEmpty ? "" : " (\(item.folder))"
            outputLines.append("- \(item.name)\(folder) — gewijzigd \(String(item.date.prefix(10))) [id: \(item.id)]")
            if index < 10 {
                refs.append(ReferenceParser.line(title: item.name, url: nil, detail: "\(item.folder.isEmpty ? "Notities" : item.folder) · \(String(item.date.prefix(10)))"))
            }
        }
        return (outputLines + refs).joined(separator: "\n")
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "list_notes",
                description: "Geeft de meest recente notities uit Apple Notities met hun titel, map, wijzigingsdatum en ID. Gebruik dit voor vragen als 'welke notities heb ik' of 'wat heb ik recent opgeschreven'.",
                schema: ["type": "object", "properties": [
                    "limit": ["type": "integer", "description": "Aantal notities (standaard 15, max 30)."] as [String: Any]
                ]],
                kind: .read,
                summarize: { _ in "Notities bekijken" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    let limit = min(30, max(1, (input["limit"] as? Int) ?? 15))
                    if let self, self.isFresh, self.recentNotes.count >= min(limit, max(1, self.totalCount)) {
                        return Self.formatNoteList(Array(self.recentNotes.prefix(limit)))
                    }
                    try await NotesConnector.ensureRunning()
                    let script = """
                    tell application "Notes"
                        set total to count of notes
                        set n to total
                        if n > \(limit) then set n to \(limit)
                        set out to ""
                        repeat with i from 1 to n
                            set notitem to note i
                            set nname to name of notitem
                            set nid to id of notitem
                            set ndate to ((modification date of notitem) as «class isot» as string)
                            set nfolder to ""
                            try
                                set nfolder to name of container of notitem
                            end try
                            set out to out & nid & "|||" & nname & "|||" & ndate & "|||" & nfolder & linefeed
                        end repeat
                        return out
                    end tell
                    """
                    let result = await ScriptText.run(script, timeout: 6)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return "Geen notities gevonden in Apple Notities."
                    }
                    let summaries = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.compactMap { line -> NoteSummary? in
                        let parts = line.components(separatedBy: "|||")
                        guard parts.count >= 3 else { return nil }
                        return NoteSummary(id: parts[0], name: parts[1], date: parts[2], folder: parts.count > 3 ? parts[3] : "")
                    }
                    return Self.formatNoteList(summaries)
                }
            ),
            ToolSpec(
                name: "search_notes",
                description: "Zoekt in ALLE notities van Apple Notities op trefwoorden in de titel en de hele inhoud. Geef een of meer losse trefwoorden (geen hele zin); notities met de meeste treffers komen eerst. Geeft per notitie het begin van de tekst en het id: lees een relevante notitie daarna volledig met read_note.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Een of meer trefwoorden, gescheiden door spaties, bijvoorbeeld \"verbouwing offerte\"."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Notities zoeken naar \"\((input["query"] as? String) ?? "")\"" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    try await NotesConnector.ensureRunning()
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let allWords = Research.words(of: query).isEmpty ? [query] : Research.words(of: query)
                    // Cap search words in AppleScript filter to the 4 most distinctive terms so Apple Events stay fast.
                    let scriptWords = Array(allWords.sorted { $0.count > $1.count }.prefix(4))
                    let nameFilter = scriptWords.map { "name contains \(ScriptText.quote($0))" }.joined(separator: " or ")
                    let bodyFilter = scriptWords.map { "body contains \(ScriptText.quote($0))" }.joined(separator: " or ")
                    let plainFilter = scriptWords.map { "plaintext contains \(ScriptText.quote($0))" }.joined(separator: " or ")

                    // Fast two-stage AppleScript:
                    // 1. Instant indexed title lookup (`whose name contains ...`).
                    // 2. For full-text search, use `plaintext` when note count <= 200, or indexed `body` column when note count > 200,
                    //    fetching up to 15,000 chars so `read_note` can be served from memory in 0ms.
                    let script = """
                    tell application "Notes"
                        set total to count of notes
                        set found to (notes whose \(nameFilter))
                        if (count of found) < 15 then
                            if total <= 200 then
                                set bodyHits to (notes whose \(plainFilter))
                            else
                                set bodyHits to (notes whose \(bodyFilter))
                            end if
                            repeat with b in bodyHits
                                if (count of found) >= 22 then exit repeat
                                set end of found to contents of b
                            end repeat
                        end if
                        set n to count of found
                        if n > 22 then set n to 22
                        set seenIDs to {}
                        set out to ""
                        repeat with i from 1 to n
                            set notitem to item i of found
                            set nid to id of notitem
                            if seenIDs does not contain nid then
                                set end of seenIDs to nid
                                set nname to name of notitem
                                set ndate to ((modification date of notitem) as «class isot» as string)
                                set nfolder to ""
                                try
                                    set nfolder to name of container of notitem
                                end try
                                set nbody to ""
                                try
                                    set nbody to plaintext of notitem
                                end try
                                if (length of nbody) > 15000 then set nbody to text 1 thru 15000 of nbody
                                set out to out & "<<<NOTE>>>" & nid & "|||" & nname & "|||" & ndate & "|||" & nfolder & linefeed & nbody & linefeed
                            end if
                        end repeat
                        return out
                    end tell
                    """
                    let result = await ScriptText.run(script, timeout: 7)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    if result.errorNumber == -1712 {
                        throw NookError("Notities doorzoeken duurde te lang. Probeer een specifieker trefwoord.")
                    }
                    let raw = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return "Geen notities gevonden voor \"\(query)\"." }

                    struct Found { var header: [String]; var fullBody: String; var snippet: String }
                    let now = Date()
                    let notes = raw.components(separatedBy: "<<<NOTE>>>").compactMap { chunk -> Found? in
                        let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                        let header = String(lines.first ?? "").components(separatedBy: "|||")
                        guard header.count >= 3 else { return nil }
                        let fullBody = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                        let cached = CachedNote(
                            id: header[0],
                            name: header[1],
                            date: header[2],
                            folder: header.count > 3 ? header[3] : "",
                            body: fullBody,
                            cachedAt: now
                        )
                        NotesConnector.bodyCache[header[0]] = cached
                        NotesConnector.bodyCache[header[1].lowercased()] = cached
                        let snippet = fullBody.count > 800 ? String(fullBody.prefix(800)) : fullBody
                        return Found(header: header, fullBody: fullBody, snippet: snippet)
                    }
                    let terms = Research.Terms(words: allWords)
                    let ranked = Research.best(notes, terms: terms, keep: 10, title: { $0.header[1] }, text: \.fullBody)
                    var blocks: [String] = []
                    var refs: [String] = []
                    for note in ranked {
                        let header = note.header
                        let folder = header.count > 3 && !header[3].isEmpty ? " [map: \(header[3])]" : ""
                        blocks.append("### \(header[1])\(folder) | \(String(header[2].prefix(10))) [id: \(header[0])]\n\(note.snippet)")
                        refs.append(ReferenceParser.line(title: header[1], url: nil, detail: "\(header.count > 3 ? header[3] : "Notities") · \(String(header[2].prefix(10)))"))
                    }
                    return (blocks + refs).joined(separator: "\n\n")
                }
            ),
            ToolSpec(
                name: "read_note",
                description: "Leest de volledige tekst van een specifieke notitie uit Apple Notities op basis van de titel of notitie-ID.",
                schema: ["type": "object", "properties": [
                    "identifier": ["type": "string", "description": "De exacte of gedeeltelijke titel van de notitie, of het notitie-ID."]
                ], "required": ["identifier"]],
                kind: .read,
                summarize: { input in "Notitie lezen: \((input["identifier"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let idOrTitle = ((input["identifier"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !idOrTitle.isEmpty else { throw NookError("Titel of ID van de notitie ontbreekt.") }

                    // Fast path: 0ms in-memory hit if already fetched during search_notes (<120s old).
                    if let cached = NotesConnector.bodyCache[idOrTitle] ?? NotesConnector.bodyCache[idOrTitle.lowercased()],
                       Date().timeIntervalSince(cached.cachedAt) < 120 {
                        var body = cached.body
                        if body.count > 15_000 { body = String(body.prefix(15_000)) + "\n… (ingekort: de eerste 15.000 tekens)" }
                        let date = String(cached.date.prefix(10))
                        return "## Notitie: \(cached.name) (\(date))\n\n\(body)\n\n" + ReferenceParser.line(title: cached.name, url: nil, detail: "Notities · \(date)")
                    }

                    try await NotesConnector.ensureRunning()
                    let q = ScriptText.quote(idOrTitle)
                    let script = """
                    tell application "Notes"
                        set target to missing value
                        try
                            set target to note id \(q)
                            -- A reference by id is only resolved when it is used: check that the note is really there.
                            get name of target
                        on error
                            set target to missing value
                        end try
                        if target is missing value then
                            -- A note in another account or folder is not always found by its reference, but by its id.
                            try
                                set matches to (notes whose id is \(q))
                                if (count of matches) > 0 then set target to item 1 of matches
                            end try
                        end if
                        if target is missing value then
                            set matches to (notes whose name is \(q))
                            if (count of matches) > 0 then set target to item 1 of matches
                        end if
                        if target is missing value then
                            set matches to (notes whose name contains \(q))
                            if (count of matches) > 0 then set target to item 1 of matches
                        end if
                        if target is missing value then return "NOT_FOUND"
                        set nid to id of target
                        set nname to name of target
                        set ndate to ((modification date of target) as «class isot» as string)
                        set nbody to plaintext of target
                        return nid & "|||" & nname & "|||" & ndate & linefeed & nbody
                    end tell
                    """
                    let result = await ScriptText.run(script, timeout: 6)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    guard let raw = result.text, raw != "NOT_FOUND" else {
                        throw NookError("Notitie \"\(idOrTitle)\" niet gevonden.")
                    }
                    let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let header = String(lines.first ?? "").components(separatedBy: "|||")
                    var body = lines.count > 1 ? String(lines[1]) : ""
                    if body.count > 15_000 { body = String(body.prefix(15_000)) + "\n… (ingekort: de eerste 15.000 tekens)" }
                    let nid = header.first ?? idOrTitle
                    let title = header.count > 1 ? header[1] : idOrTitle
                    let fullDate = header.count > 2 ? header[2] : ""
                    let date = String(fullDate.prefix(10))
                    let cached = CachedNote(id: nid, name: title, date: fullDate, folder: "", body: body, cachedAt: Date())
                    NotesConnector.bodyCache[nid] = cached
                    NotesConnector.bodyCache[title.lowercased()] = cached
                    return "## Notitie: \(title) (\(date))\n\n\(body)\n\n" + ReferenceParser.line(title: title, url: nil, detail: "Notities · \(date)")
                }
            ),
            ToolSpec(
                name: "create_note",
                description: "Maakt een nieuwe notitie aan in Apple Notities met een titel en inhoud.",
                schema: ["type": "object", "properties": [
                    "title": ["type": "string", "description": "Titel van de notitie."],
                    "body": ["type": "string", "description": "De inhoud van de notitie."],
                    "folder": ["type": "string", "description": "Optionele mapnaam waarin de notitie geplaatst moet worden."]
                ], "required": ["title", "body"]],
                kind: .action,
                summarize: { input in "Notitie maken: \((input["title"] as? String) ?? "Nieuwe notitie")" },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    try await NotesConnector.ensureRunning()
                    let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = ((input["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, !body.isEmpty else { throw NookError("Titel of inhoud ontbreekt.") }
                    let folder = (input["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    let fullText = "\(title)\n\n\(body)"
                    let qText = ScriptText.quote(fullText)
                    let folderClause: String
                    if let folder, !folder.isEmpty {
                        folderClause = "in folder \(ScriptText.quote(folder))"
                    } else {
                        folderClause = ""
                    }

                    let script = """
                    tell application "Notes"
                        make new note \(folderClause) with properties {body:\(qText)}
                        return "OK"
                    end tell
                    """
                    let result = await ScriptText.run(script)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    guard result.text == "OK" else {
                        throw NookError("Notitie kon niet worden aangemaakt in Notities.")
                    }
                    self?.loadedAt = nil
                    return "Notitie \"\(title)\" succesvol aangemaakt in Apple Notities."
                }
            )
        ]
    }
}
