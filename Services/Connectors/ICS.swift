import Foundation

// Leest agenda's in het ICS-formaat (RFC 5545): genoeg voor Google Agenda, Outlook, iCloud, Fastmail, Proton en Cal.com.
// Geen netwerk hier; alleen tekst erin, afspraken eruit.

struct ICSEvent {
    var uid: String
    var title: String
    var location: String
    var start: Date
    var end: Date
    var allDay: Bool
    var busy: Bool
    var zone: TimeZone
    var rule: ICSRule?
    var exceptions: Set<Date>
    /// Gevuld bij een los aangepaste herhaling: het oorspronkelijke begin van die herhaling.
    var recurrenceID: Date?
}

struct ICSRule {
    enum Frequency { case daily, weekly, monthly, yearly }

    var frequency: Frequency
    var interval = 1
    var count: Int?
    var until: Date?
    /// Ordinaal 0 = elke; weekdag volgens Calendar (1 = zondag … 7 = zaterdag).
    var byDay: [(ordinal: Int, weekday: Int)] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
}

struct ICSCalendar {
    var name: String?
    var events: [ICSEvent]

    private struct Line {
        let name: String
        let params: [String: String]
        let value: String
    }

    private struct InstanceKey: Hashable {
        let uid: String
        let date: Date
    }

    // MARK: Inlezen

    static func parse(_ text: String) -> ICSCalendar {
        var calendarName: String?
        var events: [ICSEvent] = []
        var current: [Line]?
        var nested = 0

        for raw in unfold(text) {
            guard let line = parseLine(raw) else { continue }
            if line.name == "BEGIN" {
                if line.value.uppercased() == "VEVENT" { current = []; nested = 0 } else if current != nil { nested += 1 }
                continue
            }
            if line.name == "END" {
                if line.value.uppercased() == "VEVENT" {
                    if let lines = current, let event = makeEvent(lines) { events.append(event) }
                    current = nil
                } else if current != nil, nested > 0 {
                    nested -= 1
                }
                continue
            }
            if current != nil {
                if nested == 0 { current?.append(line) }
            } else if line.name == "X-WR-CALNAME", calendarName == nil {
                calendarName = unescape(line.value)
            }
        }
        return ICSCalendar(name: calendarName, events: events)
    }

    /// Plakt regels weer aan elkaar die in het bestand zijn afgebroken (beginnen met een spatie of tab).
    private static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.isEmpty { continue }
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(raw.dropFirst())
            } else {
                lines.append(raw)
            }
        }
        return lines
    }

    private static func parseLine(_ line: String) -> Line? {
        var inQuotes = false
        var colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ":" && !inQuotes {
                colon = index
                break
            }
        }
        guard let colon else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])

        var parts: [String] = []
        var piece = ""
        var quoted = false
        for character in head {
            if character == "\"" {
                quoted.toggle()
                piece.append(character)
            } else if character == ";" && !quoted {
                parts.append(piece)
                piece = ""
            } else {
                piece.append(character)
            }
        }
        parts.append(piece)

        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<equals]).uppercased()
            let parameter = String(part[part.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            params[key] = parameter
        }
        return Line(name: parts[0].uppercased(), params: params, value: value)
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Datums

    /// Outlook gebruikt Windows-namen voor tijdzones.
    private static let windowsZones: [String: String] = [
        "W. Europe Standard Time": "Europe/Amsterdam",
        "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "GMT Standard Time": "Europe/London",
        "E. Europe Standard Time": "Europe/Bucharest",
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles",
        "UTC": "UTC"
    ]

    private static func zone(named name: String?) -> TimeZone {
        guard let name, !name.isEmpty else { return .current }
        if let zone = TimeZone(identifier: name) { return zone }
        if let mapped = windowsZones[name], let zone = TimeZone(identifier: mapped) { return zone }
        return .current
    }

    private static func parseDate(_ line: Line) -> (date: Date, allDay: Bool, zone: TimeZone)? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        guard value.count >= 8,
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.dropFirst(6).prefix(2)) else { return nil }

        let allDay = line.params["VALUE"] == "DATE" || value.count == 8
        var components = DateComponents(year: year, month: month, day: day)
        var zone = TimeZone.current
        if !allDay, value.count >= 15 {
            let hour = Int(value.dropFirst(9).prefix(2)) ?? 0
            let minute = Int(value.dropFirst(11).prefix(2)) ?? 0
            let second = Int(value.dropFirst(13).prefix(2)) ?? 0
            components.hour = hour
            components.minute = minute
            components.second = second
            zone = value.hasSuffix("Z") ? (TimeZone(identifier: "UTC") ?? .current) : Self.zone(named: line.params["TZID"])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        return (date, allDay, zone)
    }

    /// "PT1H30M", "P1D", "P1W"
    private static func parseDuration(_ value: String) -> TimeInterval? {
        var text = value.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1.0
        if text.hasPrefix("-") { sign = -1; text.removeFirst() }
        if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()
        var total = 0.0
        var number = ""
        var inTime = false
        for character in text {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch character {
            case "W": total += amount * 7 * 86_400
            case "D": total += amount * 86_400
            case "H": total += amount * 3_600
            case "M": total += inTime ? amount * 60 : 0
            case "S": total += amount
            default: return nil
            }
        }
        return sign * total
    }

    // MARK: Afspraak bouwen

    private static func makeEvent(_ lines: [Line]) -> ICSEvent? {
        func first(_ name: String) -> Line? { lines.first { $0.name == name } }

        if let status = first("STATUS")?.value.uppercased(), status == "CANCELLED" { return nil }
        guard let startLine = first("DTSTART"), let start = parseDate(startLine) else { return nil }

        var end = start.date
        if let endLine = first("DTEND"), let parsed = parseDate(endLine) {
            end = parsed.date
        } else if let duration = first("DURATION").flatMap({ parseDuration($0.value) }) {
            end = start.date.addingTimeInterval(duration)
        } else if start.allDay {
            end = start.date.addingTimeInterval(86_400)
        }

        var busy = first("TRANSP")?.value.uppercased() != "TRANSPARENT"
        if first("X-MICROSOFT-CDO-BUSYSTATUS")?.value.uppercased() == "FREE" { busy = false }

        var exceptions: Set<Date> = []
        for line in lines where line.name == "EXDATE" {
            for part in line.value.split(separator: ",") {
                var copy = Line(name: line.name, params: line.params, value: String(part))
                if copy.params["VALUE"] == nil, part.count == 8 { copy = Line(name: copy.name, params: ["VALUE": "DATE"], value: copy.value) }
                if let parsed = parseDate(copy) { exceptions.insert(parsed.date) }
            }
        }

        return ICSEvent(
            uid: first("UID")?.value ?? UUID().uuidString,
            title: first("SUMMARY").map { unescape($0.value) } ?? "Zonder titel",
            location: first("LOCATION").map { unescape($0.value) } ?? "",
            start: start.date,
            end: end,
            allDay: start.allDay,
            busy: busy,
            zone: start.zone,
            rule: first("RRULE").flatMap { parseRule($0.value, zone: start.zone) },
            exceptions: exceptions,
            recurrenceID: first("RECURRENCE-ID").flatMap { parseDate($0)?.date }
        )
    }

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    private static func parseRule(_ value: String, zone: TimeZone) -> ICSRule? {
        var parts: [String: String] = [:]
        for piece in value.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0].uppercased()] = pair[1] }
        }
        let frequency: ICSRule.Frequency
        switch parts["FREQ"]?.uppercased() {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default: return nil
        }
        var rule = ICSRule(frequency: frequency)
        rule.interval = max(1, parts["INTERVAL"].flatMap { Int($0) } ?? 1)
        rule.count = parts["COUNT"].flatMap { Int($0) }
        if let until = parts["UNTIL"] {
            let line = Line(name: "UNTIL", params: until.count == 8 ? ["VALUE": "DATE"] : ["TZID": zone.identifier], value: until)
            if let parsed = parseDate(line) {
                // Een UNTIL zonder tijd geldt tot het einde van die dag.
                rule.until = until.count == 8 ? parsed.date.addingTimeInterval(86_399) : parsed.date
            }
        }
        for item in (parts["BYDAY"] ?? "").split(separator: ",") {
            let text = item.uppercased()
            guard text.count >= 2, let weekday = weekdays[String(text.suffix(2))] else { continue }
            let ordinal = Int(text.dropLast(2)) ?? 0
            rule.byDay.append((ordinal, weekday))
        }
        rule.byMonthDay = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        rule.byMonth = (parts["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
        return rule
    }

    // MARK: Herhalingen uitrollen

    /// Alle beginmomenten van een herhalende afspraak tot `limit`.
    private static func starts(of event: ICSEvent, rule: ICSRule, until limit: Date) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.zone
        calendar.firstWeekday = 2

        let time = calendar.dateComponents([.hour, .minute, .second], from: event.start)
        var result: [Date] = []
        var produced = 0
        let cap = 4_000

        /// Geeft false zodra er gestopt moet worden.
        func emit(_ date: Date) -> Bool {
            if date < event.start { return true }
            if date > limit { return false }
            if let until = rule.until, date > until { return false }
            if let count = rule.count, produced >= count { return false }
            produced += 1
            if !event.exceptions.contains(date) { result.append(date) }
            return produced < cap
        }

        func day(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: day, hour: time.hour, minute: time.minute, second: time.second)
            guard let date = calendar.date(from: components), calendar.component(.month, from: date) == month else { return nil }
            return date
        }

        switch rule.frequency {
        case .daily:
            var index = 0
            while index < cap {
                guard let date = calendar.date(byAdding: .day, value: index * rule.interval, to: event.start) else { break }
                index += 1
                if !rule.byDay.isEmpty, !rule.byDay.contains(where: { $0.weekday == calendar.component(.weekday, from: date) }) {
                    if date > limit { break }
                    continue
                }
                if !emit(date) { break }
            }

        case .weekly:
            let startWeekday = calendar.component(.weekday, from: event.start)
            let wanted = rule.byDay.isEmpty ? [startWeekday] : rule.byDay.map { $0.weekday }
            let offsets = Set(wanted.map { ($0 - calendar.firstWeekday + 7) % 7 }).sorted()
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: event.start)?.start else { break }
            var week = 0
            outer: while week < cap {
                guard let base = calendar.date(byAdding: .weekOfYear, value: week * rule.interval, to: weekStart) else { break }
                week += 1
                if base > limit { break }
                for offset in offsets {
                    guard let dayStart = calendar.date(byAdding: .day, value: offset, to: base),
                          let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: dayStart) else { continue }
                    if date < event.start { continue }
                    if !emit(date) { break outer }
                }
            }

        case .monthly, .yearly:
            let startYear = calendar.component(.year, from: event.start)
            let startMonth = calendar.component(.month, from: event.start)
            let startDay = calendar.component(.day, from: event.start)

            func dates(year: Int, month: Int) -> [Date] {
                guard let first = day(year, month, 1) ?? calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let days = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
                var found: [Int] = []
                if !rule.byMonthDay.isEmpty {
                    for value in rule.byMonthDay {
                        let number = value > 0 ? value : days + 1 + value
                        if (1...days).contains(number) { found.append(number) }
                    }
                } else if !rule.byDay.isEmpty {
                    for entry in rule.byDay {
                        let matching = (1...days).filter { number in
                            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: number)) else { return false }
                            return calendar.component(.weekday, from: date) == entry.weekday
                        }
                        if entry.ordinal == 0 {
                            found.append(contentsOf: matching)
                        } else if entry.ordinal > 0, entry.ordinal <= matching.count {
                            found.append(matching[entry.ordinal - 1])
                        } else if entry.ordinal < 0, -entry.ordinal <= matching.count {
                            found.append(matching[matching.count + entry.ordinal])
                        }
                    }
                } else {
                    found.append(startDay)
                }
                return Set(found).sorted().compactMap { day(year, month, $0) }
            }

            var step = 0
            outer: while step < cap {
                var months: [(Int, Int)] = []
                if rule.frequency == .monthly {
                    let total = (startMonth - 1) + step * rule.interval
                    months = [(startYear + total / 12, total % 12 + 1)]
                } else {
                    let year = startYear + step * rule.interval
                    months = (rule.byMonth.isEmpty ? [startMonth] : rule.byMonth.sorted()).map { (year, $0) }
                }
                step += 1
                for (year, month) in months {
                    guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { continue }
                    if first > limit { break outer }
                    for date in dates(year: year, month: month) {
                        if !emit(date) { break outer }
                    }
                }
            }
        }
        return result
    }

    // MARK: Afspraken in een periode

    func entries(from: Date, to: Date, label: String) -> [AgendaEntry] {
        let overridden = Set(events.compactMap { event in event.recurrenceID.map { InstanceKey(uid: event.uid, date: $0) } })
        var out: [AgendaEntry] = []

        func add(_ event: ICSEvent, start: Date, end: Date) {
            guard start < to, max(end, start.addingTimeInterval(1)) > from else { return }
            out.append(AgendaEntry(title: event.title, start: start, end: end, allDay: event.allDay, busy: event.busy,
                                   location: event.location, calendar: label))
        }

        for event in events {
            let length = max(0, event.end.timeIntervalSince(event.start))
            if let rule = event.rule, event.recurrenceID == nil {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = event.zone
                let days = max(1, Int((length / 86_400).rounded()))
                for start in Self.starts(of: event, rule: rule, until: to) {
                    if overridden.contains(InstanceKey(uid: event.uid, date: start)) { continue }
                    let end = event.allDay ? (calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(length)) : start.addingTimeInterval(length)
                    add(event, start: start, end: end)
                }
            } else {
                add(event, start: event.start, end: event.end)
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
