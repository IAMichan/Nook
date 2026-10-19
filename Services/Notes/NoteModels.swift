// The Notetaker's notes: a call's transcript, summary, key points and to-dos, and how the transcript is built from the two
// recordings. Foundation only, tested in Tests/NookTests/NoteTests.swift.
//
// Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md). Without Parakeet the microphone is you and the Mac's sound is "the others"; with it, the diarizer tells the others apart.

import Foundation


/// Someone in a call. You are always "me"; the others get "Person 2", "Person 3"… until renamed.
struct NoteSpeaker: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Index in the window's speaker colors.
    var color: Int
    var isMe = false
}

/// One turn of speech.
struct NoteLine: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var speaker: String
    /// Seconds from the start of the recording.
    var start: Double
    var end: Double
    var text: String
    /// The words as the speech recognition heard them, kept when the line was corrected (by Nook or by you).
    var raw: String? = nil
}

struct NoteTodo: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var owner: String?
    var due: String?
    var done = false
}

/// A call noted by the Notetaker.
struct Note: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording, processing, ready, failed
    }

    var id = UUID()
    var title: String
    /// Set once you rename the note: the summary then keeps your title.
    var titleEdited: Bool?
    var start: Date
    var end: Date?
    /// The call app seen when the recording started ("Zoom", "Google Chrome").
    var app: String?
    var status: Status = .recording
    var speakers: [NoteSpeaker] = []
    var lines: [NoteLine] = []
    var summary: String?
    var keyPoints: [String] = []
    var todos: [NoteTodo] = []
    var error: String?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    func speaker(_ id: String) -> NoteSpeaker? { speakers.first { $0.id == id } }

    /// Each speaker's share of the talking, from the length of their lines.
    var shares: [String: Double] {
        var time: [String: Double] = [:]
        for line in lines { time[line.speaker, default: 0] += max(0.1, line.end - line.start) }
        let total = time.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return time.mapValues { $0 / total }
    }
}

/// A word with its place in the audio.
struct TimedWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A stretch of audio where one voice speaks, from the diarizer.
struct SpeakerTurn: Hashable, Sendable {
    var speaker: String
    var start: Double
    var end: Double
    /// The voice's fingerprint on this stretch (empty when unknown).
    var embedding: [Float] = []
}

/// Builds the transcript of a call from the two recordings (Tests/NookTests/NoteTests.swift): the microphone is you,
/// the Mac's sound is the others.
enum NoteBuilder {
    /// Words further apart than this start a new line.
    static let pause = 1.4
    /// A line never gets longer than this, so the transcript stays readable.
    static let maxLineSeconds = 40.0

    static let meID = "me"

    /// Consecutive words of the same speaker, close in time, make one line.
    static func lines(from words: [(speaker: String, word: TimedWord)]) -> [NoteLine] {
        var out: [NoteLine] = []
        for (speaker, word) in words {
            if var last = out.last, last.speaker == speaker, word.start - last.end < pause,
               word.end - last.start < maxLineSeconds {
                last.text += " " + word.text
                last.end = word.end
                out[out.count - 1] = last
            } else {
                out.append(NoteLine(speaker: speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return out
    }

    /// Without headphones, the others' voices come out of the speakers and into the microphone too.
    /// A line of yours whose words the others' recording also has, at the same moment, is that echo.
    static func removingEcho(mine: [NoteLine], others: [NoteLine]) -> [NoteLine] {
        mine.filter { line in
            let words = tokens(line.text)
            guard words.count >= 2 else {
                // A lone word: echo only if the others said exactly it at that moment.
                return !others.contains { overlaps($0, line, margin: 0.8) && tokens($0.text).contains(words.first ?? "") }
            }
            let near = others.filter { overlaps($0, line, margin: 1.5) }.flatMap { tokens($0.text) }
            guard !near.isEmpty else { return true }
            let pool = Set(near)
            let shared = words.filter { pool.contains($0) }.count
            return Double(shared) / Double(words.count) < 0.6
        }
    }

    private static func overlaps(_ a: NoteLine, _ b: NoteLine, margin: Double) -> Bool {
        a.start < b.end + margin && b.start < a.end + margin
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The echo found word by word: three or more of your words in a row that the others said in
    /// the same order at the same moment (one word heard differently, or missed, does not break it).
    /// Catches what the audio check lets through, when the speakers are very loud.
    static func removingEchoWords(_ mine: [TimedWord], others: [TimedWord],
                                  window: Double = 1.2, minRun: Int = 3) -> [TimedWord] {
        let a = mine.map { tokens($0.text).joined() }
        let b = others.map { tokens($0.text).joined() }
        var echo = [Bool](repeating: false, count: mine.count)
        var i = 0
        while i < mine.count {
            var span = 0
            if !a[i].isEmpty {
                for j in others.indices where b[j] == a[i] && abs(others[j].start - mine[i].start) <= window {
                    var x = i + 1, y = j + 1, run = 1
                    while x < mine.count && y < others.count {
                        if a[x] == b[y] {
                            run += 1; x += 1; y += 1
                        } else if y + 1 < others.count && a[x] == b[y + 1] {
                            y += 1          // a word the microphone missed
                        } else if x + 1 < mine.count && a[x + 1] == b[y] {
                            x += 1          // a word the microphone heard in more
                        } else if x + 1 < mine.count && y + 1 < others.count && a[x + 1] == b[y + 1] {
                            x += 1; y += 1  // a word heard differently
                        } else {
                            break
                        }
                    }
                    guard run >= minRun else { continue }
                    // The rest of their sentence, heard too differently to match, is the echo as well:
                    // your words that follow without a pause while they are still speaking.
                    var k = max(j, y - 1)
                    while k + 1 < others.count && others[k + 1].start - others[k].end < 0.6 { k += 1 }
                    let until = others[min(k, others.count - 1)].end + 0.3
                    while x < mine.count && mine[x].start <= until && mine[x].start - mine[x - 1].end < 0.6 { x += 1 }
                    span = max(span, x - i)
                }
            }
            if span > 0 {
                for k in i..<(i + span) { echo[k] = true }
                i += span
            } else {
                i += 1
            }
        }
        return zip(mine, echo).filter { !$0.1 }.map(\.0)
    }

    // MARK: - Markdown

    /// The note as Markdown: title, date, summary, key points, to-dos, then the transcript.
    static func markdown(_ note: Note, labels: MarkdownLabels) -> String {
        var out = "# \(note.title)\n\n"
        let date = note.start.formatted(date: .complete, time: .shortened)
        let minutes = max(1, Int((note.duration / 60).rounded()))
        out += "_\(date) · \(minutes) min_"
        if !note.speakers.isEmpty {
            out += "  \n_" + note.speakers.map(\.name).joined(separator: ", ") + "_"
        }
        out += "\n\n"
        if let summary = note.summary, !summary.isEmpty {
            out += "## \(labels.summary)\n\n\(summary)\n\n"
        }
        if !note.keyPoints.isEmpty {
            out += "## \(labels.keyPoints)\n\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !note.todos.isEmpty {
            out += "## \(labels.todos)\n\n"
            out += note.todos.map { todo in
                var line = "- [\(todo.done ? "x" : " ")] \(todo.text)"
                let extra = [todo.owner, todo.due].compactMap { $0 }.filter { !$0.isEmpty }
                if !extra.isEmpty { line += " (\(extra.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n") + "\n\n"
        }
        if !note.lines.isEmpty {
            out += "## \(labels.transcript)\n\n"
            out += note.lines.map { line in
                let name = note.speaker(line.speaker)?.name ?? line.speaker
                return "**\(name)** (\(clock(line.start))) : \(line.text)"
            }.joined(separator: "\n\n") + "\n"
        }
        return out
    }

    struct MarkdownLabels: Sendable {
        var summary: String
        var keyPoints: String
        var todos: String
        var transcript: String
    }

    /// 75 → "1:15", 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The transcript as plain text for the summary: "Name: words" per line.
    static func plainTranscript(_ note: Note) -> String {
        note.lines.map { line in
            "\(note.speaker(line.speaker)?.name ?? line.speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Summary

    struct Summary: Sendable, Equatable {
        var title: String?
        var summary: String
        var keyPoints: [String]
        var todos: [NoteTodo]
    }

    /// Reads the model's JSON answer ({"title", "summary", "key_points", "todos": [{"text", "owner", "due"}]}),
    /// even wrapped in a code block or with text around it. nil when there is no JSON in it.
    static func parseSummary(_ reply: String) -> Summary? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let data = String(reply[open...close]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let points = (json["key_points"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        let todos: [NoteTodo] = (json["todos"] as? [Any] ?? []).compactMap { item in
            if let text = item as? String, !text.isEmpty { return NoteTodo(text: text) }
            guard let dict = item as? [String: Any], let text = dict["text"] as? String, !text.isEmpty else { return nil }
            func field(_ key: String) -> String? {
                guard let v = dict[key] as? String, !v.isEmpty, v.lowercased() != "null" else { return nil }
                return v
            }
            return NoteTodo(text: text, owner: field("owner"), due: field("due"))
        }
        guard !summary.isEmpty || !points.isEmpty || !todos.isEmpty else { return nil }
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Summary(title: title?.isEmpty == true ? nil : title, summary: summary, keyPoints: points, todos: todos)
    }
}

// MARK: - Nook additions

extension NoteBuilder {
    /// What the brain gets to write the notes. Asked for JSON so the to-dos can become reminders.
    static let summaryInstructions = """
    You write the notes of a meeting from its transcript. Each line is "Name: words".
    Write in the language of the transcript. Invent nothing that was not said.
    The transcript comes from speech recognition: a word that makes no sense was probably misheard, understand it from the context.
    Reply ONLY with JSON, no code block, in this exact shape:
    {"title": "a short title, 6 words at most", "summary": "2 to 4 sentences: what was decided and why", "key_points": ["up to 6 short points"], "todos": [{"text": "the task", "owner": "the person's name as written in the transcript, or null", "due": "the deadline as said, or null"}]}
    """

    /// Words from the recognizer's segments, placed in the recording: `offset` is where the chunk started.
    static func words(_ segments: [(text: String, start: Double, duration: Double)], offset: Double) -> [TimedWord] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return TimedWord(text: text, start: offset + segment.start, end: offset + segment.start + max(segment.duration, 0.05))
        }
    }

    /// The whole transcript from the two sides: your lines without the echo of the others, in time order.
    static func build(mine: [TimedWord], others: [TimedWord], meName: String, othersName: String) -> (speakers: [NoteSpeaker], lines: [NoteLine]) {
        let myLines = lines(from: mine.map { (speaker: meID, word: $0) })
        let theirLines = lines(from: others.map { (speaker: "others", word: $0) })
        let all = (removingEcho(mine: myLines, others: theirLines) + theirLines).sorted { $0.start < $1.start }
        var speakers: [NoteSpeaker] = []
        if all.contains(where: { $0.speaker == meID }) { speakers.append(NoteSpeaker(id: meID, name: meName, color: 0, isMe: true)) }
        if all.contains(where: { $0.speaker == "others" }) { speakers.append(NoteSpeaker(id: "others", name: othersName, color: 1)) }
        return (speakers, all)
    }

    /// Notes that match the words, best first: a word in the title or summary counts more than in the transcript.
    static func search(_ notes: [Note], query: String) -> [Note] {
        let words = tokens(query).filter { $0.count >= 2 }
        guard !words.isEmpty else { return notes.sorted { $0.start > $1.start } }
        let scored = notes.compactMap { note -> (Note, Int)? in
            let head = Set(tokens(note.title + " " + (note.summary ?? "") + " " + note.keyPoints.joined(separator: " ")
                + " " + note.todos.map(\.text).joined(separator: " ")))
            let body = Set(tokens(note.lines.map(\.text).joined(separator: " ")))
            let score = words.reduce(0) { $0 + (head.contains($1) ? 3 : 0) + (body.contains($1) ? 1 : 0) }
            return score > 0 ? (note, score) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.start > $1.0.start }.map(\.0)
    }

    /// One line per note for the brain: id, date, title and summary.
    static func overview(_ note: Note) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let minutes = max(1, Int((note.duration / 60).rounded()))
        var line = "- [\(note.id.uuidString)] \(format.string(from: note.start)) (\(minutes) min) \(note.title)"
        if let summary = note.summary, !summary.isEmpty { line += ": " + summary }
        if !note.todos.isEmpty { line += " To-dos: " + note.todos.map(\.text).joined(separator: "; ") }
        return line
    }
}

// MARK: - Speakers (with Parakeet's diarizer)

extension NoteBuilder {
    /// The others' words, each given to the voice speaking at that moment (or the nearest one).
    static func assign(_ words: [TimedWord], to turns: [SpeakerTurn], fallback: String) -> [(speaker: String, word: TimedWord)] {
        words.map { word -> (speaker: String, word: TimedWord) in
            let mid = (word.start + word.end) / 2
            if let turn = turns.first(where: { mid >= $0.start && mid <= $0.end }) {
                return (speaker: turn.speaker, word: word)
            }
            let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
            if let nearest, distance(mid, nearest) < 2 { return (speaker: nearest.speaker, word: word) }
            return (speaker: fallback, word: word)
        }
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }

    /// A voice heard only in short bits ("Yeah.", "Sure.", the end of a sentence) is almost always
    /// someone already there: such bits are too short for the diarizer to recognise the voice, and
    /// it makes a new person of them. Each bit goes to the closest real voice (by fingerprint,
    /// else the nearest in time). A voice is real once it speaks 3 s in a row, or long enough overall.
    static let fragmentLongest = 3.0

    static func mergingFragments(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var total: [String: Double] = [:], longest: [String: Double] = [:]
        for turn in turns {
            let length = turn.end - turn.start
            total[turn.speaker, default: 0] += length
            longest[turn.speaker] = max(longest[turn.speaker] ?? 0, length)
        }
        guard total.count > 1 else { return turns }
        let all = total.values.reduce(0, +)
        let solid = Set(total.keys.filter { (longest[$0] ?? 0) >= fragmentLongest || (total[$0] ?? 0) >= max(20, all * 0.1) })
        guard !solid.isEmpty, solid.count < total.count else { return turns }

        // Each real voice's fingerprint: the mean of its turns', longer turns counting more.
        var centroids: [String: [Float]] = [:]
        for speaker in solid {
            var sum: [Float] = []
            for turn in turns where turn.speaker == speaker && !turn.embedding.isEmpty {
                let unit = normalized(turn.embedding)
                let weight = Float(turn.end - turn.start)
                if sum.isEmpty { sum = [Float](repeating: 0, count: unit.count) }
                guard unit.count == sum.count else { continue }
                for k in sum.indices { sum[k] += unit[k] * weight }
            }
            if !sum.isEmpty { centroids[speaker] = normalized(sum) }
        }
        let solidTurns = turns.filter { solid.contains($0.speaker) }
        return turns.map { turn in
            guard !solid.contains(turn.speaker) else { return turn }
            var turn = turn
            if !turn.embedding.isEmpty, centroids.count == solid.count {
                let unit = normalized(turn.embedding)
                if let best = centroids.max(by: { dot(unit, $0.value) < dot(unit, $1.value) }) {
                    turn.speaker = best.key
                    return turn
                }
            }
            let mid = (turn.start + turn.end) / 2
            if let nearest = solidTurns.min(by: { distance(mid, $0) < distance(mid, $1) }) {
                turn.speaker = nearest.speaker
            }
            return turn
        }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// The whole transcript: your lines (echo removed) and the others', in time order, with the
    /// speakers named in the order they first speak.
    static func build(mine: [TimedWord], others: [TimedWord], turns: [SpeakerTurn],
                      meName: String, personName: (Int) -> String) -> (speakers: [NoteSpeaker], lines: [NoteLine]) {
        let myLines = lines(from: mine.map { (speaker: meID, word: $0) })
        let theirLines = lines(from: assign(others, to: turns, fallback: "others"))
        let all = (removingEcho(mine: myLines, others: theirLines) + theirLines).sorted { $0.start < $1.start }
        var speakers: [NoteSpeaker] = []
        if !myLines.isEmpty || others.isEmpty {
            speakers.append(NoteSpeaker(id: meID, name: meName, color: 0, isMe: true))
        }
        var ids: [String: String] = [:]
        var renamed: [NoteLine] = []
        for var line in all {
            if line.speaker != meID {
                if let id = ids[line.speaker] {
                    line.speaker = id
                } else {
                    let number = speakers.filter { !$0.isMe }.count + 2
                    let id = "p\(number)"
                    ids[line.speaker] = id
                    speakers.append(NoteSpeaker(id: id, name: personName(number), color: number - 1))
                    line.speaker = id
                }
            }
            renamed.append(line)
        }
        return (speakers, renamed)
    }

}
