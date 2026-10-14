import SwiftUI

/// Alles waar Nook uit put, in één blik: een tegel per koppeling. Klik een tegel voor de details;
/// een amber stip betekent dat er iets op jou wacht.
struct ConnectTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var selectedID: String?

    private var screen: ScreenContext { app.screenContext }

    var body: some View {
        // `revision` lezen zorgt dat de tab ververst als een koppeling nieuwe gegevens heeft.
        let _ = app.connectors.revision
        let sources = app.connectors.sources.filter { $0.isActive || $0.status.state != .off }
        let selected = sources.first { $0.id == selectedID } ?? sources.first

        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                screenTile
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(sources, id: \.id) { source in
                            ConnectorTile(source: source, selected: source.id == selected?.id) {
                                selectedID = source.id
                            }
                        }
                        addTile
                    }
                }
            }
            .frame(width: 340)

            if let selected {
                ConnectorDetail(source: selected) { app.connectors.refresh(selected) }
            } else {
                emptyState
            }
        }
    }

    /// Wat Nook nu op je schermen ziet.
    private var screenTile: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(screen.windows.isEmpty ? NookTheme.textTertiary : NookTheme.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(screenHeadline)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(screenDetail)
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }

    private var screenHeadline: String {
        guard app.settings.liveScreen else { return "Schermen: uit" }
        guard screen.hasPermission else { return "Schermen: geen toestemming" }
        if screen.windows.isEmpty { return "Schermen: even kijken…" }
        let displays = screen.displayCount
        return "Ik zie \(screen.windows.count) vensters" + (displays > 1 ? " op \(displays) schermen" : "")
    }

    private var screenDetail: String {
        guard app.settings.liveScreen, screen.hasPermission else { return "Aan te zetten bij Instellingen › Assistent" }
        return screen.windows.prefix(4).map(\.app).joined(separator: " · ")
    }

    private var addTile: some View {
        Button { app.openSettings(section: .connections) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Text("Koppel meer")
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                Text("GitHub, Stripe, Notion…")
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(NookTheme.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nog niets gekoppeld")
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text("Geef Nook toegang tot je agenda en herinneringen, open Mail, of koppel GitHub, Stripe en andere diensten. Dan kan hij vragen beantwoorden met alles wat jij weet.")
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConnectorTile: View {
    let source: ContextSource
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let status = source.status
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: source.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(source.accent)
                    Text(source.title)
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    stateDot(status)
                }
                Text(headline(status))
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(detail(status))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? NookTheme.smoke : (hovering ? NookTheme.graphite : NookTheme.field))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? source.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func headline(_ status: ConnectorStatus) -> String {
        switch status.state {
        case .off: return "Uit"
        case .loading: return "Even laden…"
        case .error: return "Lukt niet"
        case .ok: return status.headline.isEmpty ? "Bijgewerkt" : status.headline
        }
    }

    private func detail(_ status: ConnectorStatus) -> String {
        if case .error(let message) = status.state { return message }
        return status.detail
    }

    @ViewBuilder
    private func stateDot(_ status: ConnectorStatus) -> some View {
        let color: Color = {
            switch status.state {
            case .error: return NookTheme.coral
            case .off: return NookTheme.textTertiary
            default: return status.needsAttention ? NookTheme.amber : NookTheme.mint
            }
        }()
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

/// De details van één koppeling: de items, met een link als die er is, en vragen die je erover kunt stellen.
private struct ConnectorDetail: View {
    let source: ContextSource
    let refresh: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let status = source.status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: source.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(source.accent)
                Text(source.title)
                    .font(NookTheme.font(17, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Spacer()
                if let updated = status.updated {
                    Text(Self.ago(updated))
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                NookIconButton(systemName: "arrow.clockwise", label: "Ververs", action: refresh)
            }

            if case .error(let message) = status.state {
                Text(message)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.coralSoft)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !status.detail.isEmpty {
                Text(status.detail)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.top, 4)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(status.items) { item in
                        ItemRow(item: item)
                    }
                }
            }
            .padding(.top, 10)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Self.suggestions(for: source.id), id: \.self) { question in
                    Button { app.handleUserText(question) } label: {
                        Text(question)
                            .font(NookTheme.font(11.5, .medium))
                            .foregroundStyle(NookTheme.paper)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NookTheme.smoke))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "zojuist" }
        if seconds < 3600 { return "\(seconds / 60) min geleden" }
        return "om \(NookDates.time(date))"
    }

    /// Een paar vragen die je met één klik kunt stellen.
    static func suggestions(for id: String) -> [String] {
        switch id {
        case "calendar": return ["Wanneer ben ik vrij deze week?", "Wat staat er morgen?"]
        case "reminders": return ["Wat moet ik vandaag nog doen?"]
        case "mail": return ["Vat mijn ongelezen mail samen", "Welke mail moet ik beantwoorden?"]
        case "browser": return ["Vat mijn open tabbladen samen"]
        case "files": return ["Waar werkte ik gisteren aan?"]
        case "github": return ["Wat wacht er op mij op GitHub?"]
        case "stripe": return ["Hoeveel heb ik vandaag verdiend?"]
        case "vercel": return ["Gaat er iets mis bij Vercel?"]
        case "portfolio": return ["Hoe staat mijn portfolio ervoor?"]
        default: return ["Vat \(id) samen"]
        }
    }
}

private struct ItemRow: View {
    let item: ConnectorItem
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = item.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(item.tone.color).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if item.url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && item.url != nil ? NookTheme.field : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
