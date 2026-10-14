import SwiftUI

/// Startpunt: Nooks top-3 met één knop per punt.
struct TodayTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var question = ""

    var body: some View {
        let items = app.todayItems
        VStack(alignment: .leading, spacing: 0) {
            Text(items.isEmpty ? Greeting.quiet() : Greeting.line(count: items.count))
                .font(NookTheme.font(20, .semibold))
                .foregroundStyle(NookTheme.paper)

            awareness
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    TodayRow(item: item) { open(item) }
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 10)

            suggestions
                .padding(.bottom, 8)

            askField
        }
    }

    /// In één regel waar Nook nu bij kan: zo weet je meteen dat je er alles aan kunt vragen.
    private var awareness: some View {
        let _ = app.connectors.revision
        var parts: [String] = []
        let screen = app.screenContext
        if !screen.windows.isEmpty {
            parts.append("\(screen.windows.count) vensters" + (screen.displayCount > 1 ? " op \(screen.displayCount) schermen" : ""))
        }
        for source in app.connectors.active.prefix(4) where source.status.state == .ok && !source.status.headline.isEmpty {
            parts.append("\(source.title.lowercased()): \(source.status.headline.lowercased())")
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(parts.isEmpty ? NookTheme.textTertiary : NookTheme.mint)
                .frame(width: 6, height: 6)
            Text(parts.isEmpty ? "Ik zie nog niets. Geef me toegang bij Instellingen, dan help ik je met alles." : "Ik zie " + parts.joined(separator: " · "))
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
        }
    }

    /// Vragen die je met één klik stelt; ze passen zich aan aan wat er gekoppeld is.
    private var suggestions: some View {
        var questions = ["Wat staat er op mijn schermen?", "Vat mijn dag samen"]
        let ids = Set(app.connectors.active.map { $0.id })
        if ids.contains("mail") { questions.append("Welke mail moet ik beantwoorden?") }
        if ids.contains("github") { questions.append("Wat wacht er op mij op GitHub?") }
        if !ids.contains("mail") && !ids.contains("github") { questions.append("Wanneer ben ik vrij deze week?") }
        return HStack(spacing: 6) {
            ForEach(questions.prefix(4), id: \.self) { question in
                Button { app.handleUserText(question) } label: {
                    Text(question)
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(NookTheme.smoke))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ item: TodayItem) {
        switch item.target {
        case .card(let scene):
            viewModel.show(.card(DemoContent.card(for: scene)))
        case .agent(let id):
            viewModel.selectedAgentID = id
            viewModel.show(.panel(.agents))
        case .action(let run):
            run()
        case .none:
            break
        }
    }

    private var askField: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $question,
                prompt: Text("Vraag Nook iets…").foregroundStyle(NookTheme.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(NookTheme.font(14))
            .foregroundStyle(NookTheme.paper)
            .onSubmit {
                let text = question
                question = ""
                app.handleUserText(text)
            }
            Text("⌥⌘ spatie")
                .font(NookTheme.mono(11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(NookTheme.field))
    }
}

private struct TodayRow: View {
    let item: TodayItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle().fill(item.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NookTheme.font(14.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                    Text(item.subtitle)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                Spacer()
                if !item.action.isEmpty {
                    Text(item.action)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(Color(hex: 0xC9C7D2))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(hovering ? NookTheme.field : Color.clear)
            .overlay(alignment: .top) { Rectangle().fill(NookTheme.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
