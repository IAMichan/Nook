import SwiftUI
import os

@MainActor
final class CalcomConnector: TokenCloudConnector {
    let id = "calcom"
    let title = "Cal.com"
    let symbol = "calendar.badge.clock"
    let accent = Color(hex: 0x5FD3F3)
    let refreshInterval: TimeInterval = 300
    @Published var status = ConnectorStatus()

    static let keyAccount = "connector.calcom.key"
    static var fields: [ConnectorField] {
        [ConnectorField(account: CalcomConnector.keyAccount, label: tr("connect.field.apiKey"), placeholder: "cal_live_…", secret: true)]
    }
    static var helpText: String { tr("connect.calcom.help") }
    static let signupURL = URL(string: "https://app.cal.com/settings/developer/api-keys")

    private struct Booking {
        let id: String
        let title: String
        let start: Date
        let end: Date?
        let status: String
        let attendee: String?
        let url: URL?

        var needsConfirmation: Bool { status == "pending" || status == "unconfirmed" }
    }

    private var bookings: [Booking] = []
    private var loaded = false

    static var secretAccounts: [String] { [CalcomConnector.keyAccount] }

    func fetchSnapshot(secrets: [String]) async throws {
        apply(try await fetch(key: secrets[0], count: 20))
    }

    func clearSnapshot() {
        bookings = []
        loaded = false
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded else { return [] }
        if bookings.isEmpty { return ["Cal.com: no upcoming bookings."] }
        var lines = ["Cal.com: \(CloudHelp.plural(bookings.count, "upcoming booking", "upcoming bookings"))."]
        for b in bookings.prefix(4) {
            lines.append("Booking: \(line(for: b))")
        }
        let pending = bookings.filter { $0.needsConfirmation }
        if !pending.isEmpty {
            lines.append("Cal.com: \(CloudHelp.plural(pending.count, "booking awaiting", "bookings awaiting")) confirmation.")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "calcom_bookings",
                description: "Fetches upcoming Cal.com bookings for the user: title, time, attendee, status, and link.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read Cal.com" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("Cal.com") }
                    return try await self.overview()
                }
            )
        ]
    }

    private func fetch(key: String, count: Int) async throws -> [Booking] {
        let url = try CloudHelp.url("https://api.cal.com", "/v2/bookings", query: [
            ("status", "upcoming"), ("take", String(count))
        ])
        let raw = try await ConnectorHTTP.json(url, headers: [
            "Authorization": "Bearer \(key)",
            "cal-api-version": "2024-08-13"
        ])
        let skip: Set<String> = ["cancelled", "rejected"]
        return CloudHelp.list(CloudHelp.object(raw)["data"])
            .compactMap { parse($0) }
            .filter { !skip.contains($0.status) }
            .sorted { $0.start < $1.start }
    }

    private func parse(_ b: [String: Any]) -> Booking? {
        guard let start = CloudHelp.date(b["start"]) ?? CloudHelp.date(b["startTime"]) else { return nil }
        let uid = CloudHelp.string(b["uid"])
        let attendee = CloudHelp.list(b["attendees"]).first.flatMap { ($0["name"] as? String) ?? ($0["email"] as? String) }
        return Booking(
            id: uid ?? CloudHelp.string(b["id"]) ?? UUID().uuidString,
            title: (b["title"] as? String) ?? "Appointment",
            start: start,
            end: CloudHelp.date(b["end"]) ?? CloudHelp.date(b["endTime"]),
            status: ((b["status"] as? String) ?? "accepted").lowercased(),
            attendee: attendee,
            url: uid.flatMap { URL(string: "https://app.cal.com/booking/\($0)") }
        )
    }

    private func line(for b: Booking) -> String {
        var text = "'\(CloudHelp.short(b.title, 50))'"
        if let who = b.attendee { text += " with \(who)" }
        text += ", \(NookDates.short(b.start))"
        if b.needsConfirmation { text += " (awaiting confirmation)" }
        return text
    }

    private func apply(_ list: [Booking]) {
        bookings = list
        loaded = true
        let calendar = Calendar.current
        let today = list.count(where: { calendar.isDateInToday($0.start) })
        let pending = list.filter { $0.needsConfirmation }

        let headline: String
        if let next = list.first {
            headline = tr("connect.calcom.next", NookDates.short(next.start, locale: NookDates.appLocale))
        } else {
            headline = tr("connect.calcom.noBookings")
        }
        var detail = "\(today) today · \(list.count) upcoming"
        if !pending.isEmpty { detail += " · \(pending.count) to confirm" }

        let items = list.prefix(8).map { b -> ConnectorItem in
            var subtitle = NookDates.short(b.start)
            if let who = b.attendee { subtitle += " · with \(who)" }
            if b.needsConfirmation { subtitle += " · confirm" }
            return ConnectorItem(id: b.id, title: b.title, subtitle: subtitle,
                                 tone: b.needsConfirmation ? .attention : .neutral, url: b.url)
        }
        status = ConnectorStatus(state: .ok, headline: headline, detail: detail, items: Array(items),
                                 updated: Date(), needsAttention: !pending.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(CalcomConnector.keyAccount) else {
            throw CloudHelp.notSetUp("Cal.com")
        }
        let list = try await fetch(key: key, count: 40)
        apply(list)
        if list.isEmpty { return "No upcoming Cal.com bookings." }
        return list.map { b -> String in
            var text = "- \(line(for: b))"
            if let url = b.url { text += " · \(url.absoluteString)" }
            return text
        }.joined(separator: "\n")
    }
}

extension CalcomConnector: AgendaSource {
    func agendaNames() -> [String] { ["Cal.com bookings"] }

    func agendaEntries(from: Date, to: Date) async throws -> AgendaResult {
        guard let key = CloudHelp.secret(CalcomConnector.keyAccount) else { throw CloudHelp.notSetUp("Cal.com") }
        let list = try await fetch(key: key, count: 100)
        let entries = list.compactMap { booking -> AgendaEntry? in
            let end = booking.end ?? booking.start.addingTimeInterval(1800)
            guard booking.start < to, end > from else { return nil }
            return AgendaEntry(title: booking.title, start: booking.start, end: end, busy: true, calendar: "Cal.com")
        }
        return AgendaResult(entries: entries)
    }
}
