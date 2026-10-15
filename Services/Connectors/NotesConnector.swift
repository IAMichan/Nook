import SwiftUI
import AppKit

// MARK: Apple Notes (Notities)

/// Toegang tot Apple Notities op je Mac via AppleScript (bliksemsnel en volledig lokaal).
@MainActor
final class NotesConnector: ContextSource {
    struct NoteSummary: Identifiable, Equatable {
        var id: String
        var name: String
        var date: String
        var folder: String
    }

    let id = "notes"
    let title = "Notities"
    let symbol = "note.text"
    let accent = Color(hex: 0xF5C518)
    private(set) var status = ConnectorStatus()
    private var recentNotes: [NoteSummary] = []
    private var totalCount = 0

    var isActive: Bool { ConnectorToggle.isOn(id) && (ScriptText.isRunning("com.apple.Notes") || recentNotes.count > 0) }
    var canLookUp: Bool { ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 120 }

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
        for _ in 0..<30 where !ScriptText.isRunning("com.apple.Notes") {
            try? await Task.sleep(nanoseconds: 100_000_000)
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
            if n > 8 then set n to 8
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

        let result = await ScriptText.run(script)
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
                run: { input in
                    try await NotesConnector.ensureRunning()
                    let limit = min(30, max(1, (input["limit"] as? Int) ?? 15))
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
                    let result = await ScriptText.run(script)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return "Geen notities gevonden in Apple Notities."
                    }
                    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    var outputLines: [String] = ["Recente notities in Apple Notities:"]
                    var refs: [String] = []
                    for (index, line) in lines.enumerated() {
                        let parts = line.components(separatedBy: "|||")
                        guard parts.count >= 3 else { continue }
                        let folder = parts.count > 3 && !parts[3].isEmpty ? " (\(parts[3]))" : ""
                        outputLines.append("- \(parts[1])\(folder) — gewijzigd \(String(parts[2].prefix(10))) [id: \(parts[0])]")
                        if index < 10 {
                            refs.append(ReferenceParser.line(title: parts[1], url: nil, detail: "\(parts.count > 3 ? parts[3] : "Notities") · \(String(parts[2].prefix(10)))"))
                        }
                    }
                    return (outputLines + refs).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "search_notes",
                description: "Zoekt in Apple Notities op trefwoorden in de titel of inhoud van notities. Geeft de gevonden notities met het begin van de tekst.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Zoekterm(en) waarnaar gezocht moet worden."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Notities zoeken naar \"\((input["query"] as? String) ?? "")\"" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    try await NotesConnector.ensureRunning()
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let q = ScriptText.quote(query)
                    let script = """
                    tell application "Notes"
                        set found to (notes whose name contains \(q) or plaintext contains \(q))
                        set n to count of found
                        if n > 10 then set n to 10
                        set out to ""
                        repeat with i from 1 to n
                            set notitem to item i of found
                            set nname to name of notitem
                            set nid to id of notitem
                            set ndate to ((modification date of notitem) as «class isot» as string)
                            set nfolder to ""
                            try
                                set nfolder to name of container of notitem
                            end try
                            set nbody to ""
                            try
                                set nbody to plaintext of notitem
                            end try
                            if (length of nbody) > 600 then set nbody to text 1 thru 600 of nbody
                            set out to out & "<<<NOTE>>>" & nid & "|||" & nname & "|||" & ndate & "|||" & nfolder & linefeed & nbody & linefeed
                        end repeat
                        return out
                    end tell
                    """
                    let result = await ScriptText.run(script)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    let raw = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return "Geen notities gevonden voor \"\(query)\"." }

                    var blocks: [String] = []
                    var refs: [String] = []
                    for chunk in raw.components(separatedBy: "<<<NOTE>>>") where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                        let header = String(lines.first ?? "").components(separatedBy: "|||")
                        guard header.count >= 3 else { continue }
                        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                        let folder = header.count > 3 && !header[3].isEmpty ? " [map: \(header[3])]" : ""
                        blocks.append("### \(header[1])\(folder) | \(String(header[2].prefix(10)))\n\(body)")
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
                    try await NotesConnector.ensureRunning()
                    let idOrTitle = ((input["identifier"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !idOrTitle.isEmpty else { throw NookError("Titel of ID van de notitie ontbreekt.") }
                    let q = ScriptText.quote(idOrTitle)
                    let script = """
                    tell application "Notes"
                        set target to missing value
                        try
                            set target to note id \(q)
                        end try
                        if target is missing value then
                            set matches to (notes whose name is \(q))
                            if (count of matches) > 0 then set target to item 1 of matches
                        end if
                        if target is missing value then
                            set matches to (notes whose name contains \(q))
                            if (count of matches) > 0 then set target to item 1 of matches
                        end if
                        if target is missing value then return "NOT_FOUND"
                        set nname to name of target
                        set ndate to ((modification date of target) as «class isot» as string)
                        set nbody to plaintext of target
                        return nname & "|||" & ndate & linefeed & nbody
                    end tell
                    """
                    let result = await ScriptText.run(script)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming voor Notities: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    guard let raw = result.text, raw != "NOT_FOUND" else {
                        throw NookError("Notitie \"\(idOrTitle)\" niet gevonden.")
                    }
                    let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let header = String(lines.first ?? "").components(separatedBy: "|||")
                    let body = lines.count > 1 ? String(lines[1]) : ""
                    let title = header.first ?? idOrTitle
                    let date = header.count > 1 ? String(header[1].prefix(10)) : ""
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
                run: { input in
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
                    return "Notitie \"\(title)\" succesvol aangemaakt in Apple Notities."
                }
            )
        ]
    }
}
