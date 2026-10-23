import SwiftUI

/// Search everything (⌘K or ⇧⌘F, or the magnifying glass in the panel header): one field over conversations with Nook, agent
/// sessions and their transcripts, chats, call notes, memories, notices, settings and actions. Typing ranks as you go;
/// a chip (or Tab) keeps one kind; ↑/↓ move, Return opens the hit right where it matched, Esc closes. With nothing
/// typed it shows your recent searches and how to search more precisely (see `SearchQuery` for the query language).
struct SearchPanel: View {
    @EnvironmentObject private var app: AppModel
    /// Shows a tab in the surface that holds the panel (the notch or the main window).
    let select: (PanelTab) -> Void
    let close: () -> Void

    @StateObject private var center = SearchCenter()
    /// Contact photos for chat results, as the Chats tab shows them.
    @ObservedObject private var photos = ContactPhotos.shared
    @State private var text = ""
    @State private var kind: SearchKind?
    @State private var index = 0
    @FocusState private var focused: Bool

    /// What a row is: a hit, or asking Nook what you typed.
    private enum Row: Identifiable {
        case hit(SearchHit, top: Bool)
        case ask(String)

        var id: String {
            switch self {
            case .hit(let hit, let top): return (top ? "top:" : "") + hit.id
            case .ask: return "ask"
            }
        }
    }

    /// The kinds in chip order.
    private static let kinds: [SearchKind] = [.conversation, .session, .chat, .note, .memory, .notice, .setting, .action]

    private var visible: [SearchHit] {
        guard let kind else { return center.hits }
        return center.hits.filter { $0.document.kind == kind }
    }

    private var rows: [Row] {
        let hits = visible
        var rows: [Row] = []
        if let top = hits.first, kind == nil, hits.count > 1 { rows.append(.hit(top, top: true)) }
        let rest = kind == nil && hits.count > 1 ? Array(hits.dropFirst()) : hits
        for group in Self.kinds {
            rows += rest.filter { $0.document.kind == group }.map { Row.hit($0, top: false) }
        }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, center.query.hasText || center.query.isEmpty { rows.append(.ask(typed)) }
        return rows
    }

    var body: some View {
        let list = rows
        VStack(spacing: 0) {
            NookSearchField(prompt: tr("search.placeholder"), text: $text, style: .large, focus: $focused,
                            onSubmit: { open(list) }, onEscape: close)
                .padding(.horizontal, NookTheme.Spacing.xs)
            if !text.isEmpty { chips.padding(.horizontal, NookTheme.Spacing.lg).padding(.bottom, NookTheme.Spacing.md) }
            NookDivider()
            Group {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    start
                } else {
                    results(list)
                }
            }
            .frame(maxHeight: 440)
            NookDivider()
            footer
        }
        .frame(width: 640)
        .cardBackground(NookTheme.graphite, stroke: NookTheme.line2, radius: NookTheme.Radius.sheet, style: .continuous)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .onAppear {
            focused = true
            center.load(app)
            photos.refresh()
        }
        .onDisappear { center.cancel() }
        .onChange(of: text) { _, value in
            index = 0
            center.search(value)
        }
        .onChange(of: kind) { _, _ in index = 0 }
        .onChange(of: center.hits) { _, _ in index = min(index, max(0, rows.count - 1)) }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.tab) { cycleKind(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    // MARK: Kinds

    private var chips: some View {
        let counts = Dictionary(grouping: center.hits, by: \.document.kind).mapValues(\.count)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NookTheme.Spacing.sm) {
                NookFilterChip(title: tr("search.kind.all"), count: center.hits.isEmpty ? nil : center.hits.count, selected: kind == nil) {
                    kind = nil
                }
                ForEach(Self.kinds.filter { counts[$0] != nil || $0 == kind }, id: \.self) { value in
                    NookFilterChip(title: Self.title(value), count: counts[value] ?? 0, selected: kind == value) {
                        kind = kind == value ? nil : value
                    }
                }
            }
            .padding(.vertical, NookTheme.Spacing.xxs)
        }
    }

    /// Tab: the next kind that has hits, then back to all.
    private func cycleKind() {
        let present = Self.kinds.filter { value in center.hits.contains { $0.document.kind == value } }
        guard !present.isEmpty else { kind = nil; return }
        if let kind, let at = present.firstIndex(of: kind) {
            self.kind = at + 1 < present.count ? present[at + 1] : nil
        } else {
            kind = present[0]
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ list: [Row]) -> some View {
        if list.allSatisfy({ if case .ask = $0 { return true } else { return false } }), center.searched == text, !center.indexing {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                ListEmptyNote(tr("search.none"))
                Text(tr("search.noneDetail")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                ForEach(Array(list.enumerated()), id: \.element.id) { offset, row in
                    rowView(row, selected: offset == index).onTapGesture { index = offset; open(list) }
                }
            }
            .padding(NookTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { offset, row in
                            if let label = sectionLabel(list, at: offset) {
                                NookSectionLabel(label, inset: NookTheme.Spacing.md)
                                    .padding(.top, offset == 0 ? 0 : NookTheme.Spacing.md)
                                    .padding(.bottom, NookTheme.Spacing.xxs)
                            }
                            rowView(row, selected: offset == index)
                                .id(row.id)
                                .onTapGesture { index = offset; open(list) }
                        }
                    }
                    .padding(NookTheme.Spacing.sm)
                }
                .onChange(of: index) { _, value in
                    guard list.indices.contains(value) else { return }
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(list[value].id) }
                }
            }
        }
    }

    /// A label over the first row of each group: the top hit, then each kind.
    private func sectionLabel(_ list: [Row], at offset: Int) -> String? {
        func group(_ row: Row) -> String {
            switch row {
            case .hit(_, let top) where top: return tr("search.top")
            case .hit(let hit, _): return Self.title(hit.document.kind)
            case .ask: return ""
            }
        }
        let current = group(list[offset])
        guard !current.isEmpty, kind == nil else { return nil }
        return offset == 0 || group(list[offset - 1]) != current ? current : nil
    }

    @ViewBuilder
    private func rowView(_ row: Row, selected: Bool) -> some View {
        switch row {
        case .hit(let hit, _): hitRow(hit, selected: selected)
        case .ask(let typed): askRow(typed, selected: selected)
        }
    }

    private func hitRow(_ hit: SearchHit, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            face(hit.document, selected: selected)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(Self.marked(hit.document.title, hit.titleRanges, font: NookTheme.TextStyle.body, bold: NookTheme.TextStyle.strong))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if hit.document.flags.contains("unread") {
                        Circle().fill(NookTheme.iris).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Spacer(minLength: NookTheme.Spacing.md)
                    if hit.matches > 1 {
                        Text(tr("search.matches", hit.matches)).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textMuted)
                    }
                    if let date = hit.passage?.date ?? hit.document.date {
                        Text(NookDates.ago(date)).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
                    }
                }
                if let line = detail(hit) {
                    Text(line)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(selected ? NookTheme.smoke : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A chat's photo (or initials) with its app's badge, an agent's logo, else the kind's symbol; all in the same slot so
    /// the titles line up.
    @ViewBuilder
    private func face(_ document: SearchDocument, selected: Bool) -> some View {
        switch document.icon {
        case .chat(let app, let name, let avatar, let handle):
            ChatsAvatar(name: name, app: app, photo: photo(avatar: avatar, handle: handle, name: name), size: Self.faceSize)
        case .agent(let agent):
            AgentLogo(agent: agent, size: Self.faceSize - 4).frame(width: Self.faceSize, height: Self.faceSize)
        case nil:
            NookSymbol(Self.symbol(document), size: 13)
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(selected ? NookTheme.iris : NookTheme.textTertiary)
                .frame(width: Self.faceSize, height: 18)
        }
    }

    private static let faceSize: CGFloat = 26

    /// The chat's own picture from its app, else its photo in Contacts.
    private func photo(avatar: String?, handle: String?, name: String) -> NSImage? {
        // Straight to the image cache, without a disk lookup per hit on every redraw; a missing file gives no image.
        if let avatar, let image = ChatMediaImages.image(URL(fileURLWithPath: avatar), side: 96) {
            return image
        }
        return photos.photo(handle: handle, name: name)
    }

    /// The line under a hit: who said what matched, else where it lives.
    private func detail(_ hit: SearchHit) -> AttributedString? {
        let snippet = hit.snippet.isEmpty ? hit.document.subtitle : hit.snippet
        guard !snippet.isEmpty else { return nil }
        var line = AttributedString()
        if let author = hit.passage?.author, !author.isEmpty, hit.document.kind != .setting {
            var who = AttributedString((author == "me" ? tr("search.author.me") : author == "nook" ? "Nook" : author) + ": ")
            who.font = NookTheme.TextStyle.label
            who.foregroundColor = NookTheme.textStrong
            line += who
        }
        let ranges = hit.snippet.isEmpty ? [] : hit.snippetRanges
        line += Self.marked(snippet, ranges, font: NookTheme.TextStyle.detail, bold: NookTheme.font(12, .semibold))
        if !hit.snippet.isEmpty, !hit.document.subtitle.isEmpty, hit.document.kind != .conversation {
            var place = AttributedString("  ·  " + hit.document.subtitle)
            place.font = NookTheme.TextStyle.detail
            place.foregroundColor = NookTheme.textTertiary
            line += place
        }
        return line
    }

    private func askRow(_ typed: String, selected: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "sparkles")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.iris)
                .frame(width: 18)
            Text(tr("search.ask", typed)).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(selected ? NookTheme.smoke : .clear))
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Start

    /// Before you type: recent searches, and the words that make a search precise.
    private var start: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                if !center.recent.isEmpty {
                    HStack {
                        NookSectionLabel(tr("search.recent"), inset: NookTheme.Spacing.md)
                        Spacer()
                        SmallGhostButton(title: tr("search.clearRecent")) { center.clearRecent() }
                    }
                    ForEach(center.recent, id: \.self) { recent in
                        Button { text = recent } label: {
                            HStack(spacing: NookTheme.Spacing.md) {
                                Image(systemName: "clock.arrow.circlepath").font(NookTheme.font(12, .medium))
                                    .foregroundStyle(NookTheme.textTertiary).frame(width: 18)
                                Text(recent).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textStrong).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, NookTheme.Spacing.md)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, NookTheme.Spacing.md)
                }
                NookSectionLabel(tr("search.tips"), inset: NookTheme.Spacing.md)
                ForEach(Self.tips, id: \.example) { tip in
                    Button {
                        if !tip.insert.isEmpty { text = tip.insert }
                        focused = true
                    } label: {
                        HStack(spacing: NookTheme.Spacing.lg) {
                            Text(tip.example).font(NookTheme.TextStyle.code).foregroundStyle(NookTheme.paper)
                                .frame(width: 210, alignment: .leading)
                            Text(tr(tip.key)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, NookTheme.Spacing.md)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(NookTheme.Spacing.sm)
        }
    }

    /// The query language, by example; a click starts a search with it.
    private struct Tip: Hashable {
        let example: String
        let key: String
        let insert: String

        init(_ example: String, _ key: String, _ insert: String) {
            self.example = example
            self.key = key
            self.insert = insert
        }
    }

    private static let tips: [Tip] = [
        Tip("\"exact words\"", "search.tip.phrase", "\""),
        Tip("-word", "search.tip.exclude", "-"),
        Tip("a OR b", "search.tip.or", ""),
        Tip("in:agents  in:chats", "search.tip.in", "in:"),
        Tip("from:me  from:anna", "search.tip.from", "from:"),
        Tip("after:2026-10-01  before:7d", "search.tip.date", "after:"),
        Tip("is:unread  is:running", "search.tip.is", "is:"),
        Tip("app:  project:  branch:", "search.tip.facet", "project:"),
        Tip("/regex/", "search.tip.regex", "/"),
    ]

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Text(tr("search.footer")).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
            Spacer(minLength: NookTheme.Spacing.md)
            if center.indexing {
                ProgressView().controlSize(.small)
                Text(tr("search.indexing")).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            } else if !text.isEmpty {
                Text(tr("search.results", visible.count)).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .frame(height: 30)
    }

    // MARK: Opening

    private func open(_ list: [Row]) {
        guard list.indices.contains(index) else { return }
        center.remember(text)
        switch list[index] {
        case .hit(let hit, _):
            close()
            if let tab = app.openSearchHit(hit) { select(tab) }
        case .ask(let typed):
            close()
            app.askFromSearch(typed)
            select(.chat)
        }
    }

    // MARK: Look

    static func title(_ kind: SearchKind) -> String { tr("search.kind.\(kind.rawValue)") }

    static func symbol(_ document: SearchDocument) -> String {
        switch document.kind {
        case .action:
            switch document.id {
            case "action:newChat": return "square.and.pencil"
            case "action:newSession": return "plus.bubble"
            case "action:pullRequests": return PullRequestIcon.generic
            case "action:usage": return "chart.bar"
            case "action:terminals": return "terminal"
            case "action:browser": return "globe"
            case "action:worktrees": return "arrow.triangle.branch"
            case "action:recordCall": return "waveform.badge.mic"
            case "action:window": return "macwindow"
            default: return "gearshape"
            }
        case .setting: return "gearshape"
        case .conversation: return "bubble.left"
        case .session: return "bubble.left.and.text.bubble.right"
        case .chat: return "message"
        case .note: return "waveform"
        case .memory: return "brain"
        case .notice: return "bell"
        }
    }

    /// A text with what matched in a heavier weight on a soft accent fill.
    static func marked(_ text: String, _ ranges: [Range<Int>], font: Font, bold: Font) -> AttributedString {
        var out = AttributedString()
        for piece in SearchHighlight.segments(text, ranges: ranges) {
            var part = AttributedString(piece.text)
            part.font = piece.marked ? bold : font
            if piece.marked {
                part.foregroundColor = NookTheme.paper
                part.backgroundColor = NookTheme.iris.opacity(0.22)
            }
            out += part
        }
        return out
    }
}
