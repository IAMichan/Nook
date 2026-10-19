import SwiftUI

/// The calls the Notetaker noted, as a source for the chat: "wat spraken we af met Lisa?", "welke to-do's kwamen uit de
/// call van vanochtend?". Read-only, on this Mac.
@MainActor
final class CallNotesConnector: ContextSource {
    let id = "callnotes"
    let title = "Gesprekken"
    let symbol = "waveform.badge.mic"
    let accent = Color(hex: 0xFF7A59)
    private(set) var status = ConnectorStatus()

    var isActive: Bool { ConnectorToggle.isOn(id) && !NoteTaker.shared.notes.isEmpty }
    var iconDomain: String? { nil }

    func refresh() async {
        let count = NoteTaker.shared.notes.count
        status = count == 0
            ? ConnectorStatus(state: .off, detail: tr("notes.connector.empty"))
            : ConnectorStatus(state: .ok, headline: tr("notes.connector.count", count), detail: tr("notes.connector.detail"), updated: Date())
    }

    func contextLines() -> [String] {
        let recent = NoteTaker.shared.notes.filter { $0.status == .ready && Date().timeIntervalSince($0.start) < 3 * 86_400 }.prefix(3)
        guard !recent.isEmpty else { return [] }
        return ["Recent calls noted by Nook (read with read_call_note):\n" + recent.map(NoteBuilder.overview).joined(separator: "\n")]
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_call_notes",
                description: "Searches the calls and meetings Nook recorded and noted (title, summary, key points, to-dos and the full transcript). Without query: the most recent ones. Returns note ids; read one in full with read_call_note.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Keywords or a name. Optional."]
                ]],
                kind: .read,
                summarize: { input in "Gesprekken zoeken: \(AppData.string(input["query"]))" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let found = NoteBuilder.search(NoteTaker.shared.notes.filter { $0.status == .ready }, query: AppData.string(input["query"]))
                    guard !found.isEmpty else { return "No noted calls found for \"\(AppData.string(input["query"]))\"." }
                    return found.prefix(8).map(NoteBuilder.overview).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "read_call_note",
                description: "Reads one noted call in full: summary, key points, to-dos and the transcript with who said what. Give the id from search_call_notes.",
                schema: ["type": "object", "properties": [
                    "id": ["type": "string", "description": "The note id."]
                ], "required": ["id"]],
                kind: .read,
                summarize: { _ in "Gesprek lezen" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let raw = AppData.string(input["id"]).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                    guard let id = UUID(uuidString: raw), let note = NoteTaker.shared.note(id) else {
                        throw NookError("This note is not found. Search with search_call_notes first.")
                    }
                    return String(NoteTaker.shared.markdown(note).prefix(60_000))
                }
            )
        ]
    }
}
