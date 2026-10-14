import SwiftUI
import AppKit

/// Het Nook-tabblad: je chat met Nook. Zonder gesprek zie je je dag en een paar vragen om mee te beginnen.
struct NookTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NookChatView(viewModel: viewModel, chat: app.chat)
    }
}

private struct NookChatView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @State private var question = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !chat.history.isEmpty {
                NookList(chat: chat)
                    .frame(width: 168)
            }
            VStack(alignment: .leading, spacing: 0) {
                if chat.isEmpty {
                    start
                } else {
                    thread
                }
                inputBar
                    .padding(.top, 10)
            }
        }
        .onAppear {
            // Even wachten tot het paneel de toetsenbordfocus heeft.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { inputFocused = true }
        }
    }

    // MARK: Zonder gesprek: je dag

    private var start: some View {
        let items = app.todayItems
        return VStack(alignment: .leading, spacing: 0) {
            Text(items.isEmpty ? Greeting.quiet() : Greeting.line(count: items.count))
                .font(NookTheme.font(20, .semibold))
                .foregroundStyle(NookTheme.paper)

            awareness
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(items.prefix(4)) { item in
                    TodayRow(item: item) { open(item) }
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 10)

            suggestions
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

    /// Vragen die je met één klik stelt; ze passen bij wat je nu doet (venster, afspraak, agents, moment van de dag).
    private var suggestions: some View {
        SuggestionRow(questions: app.startSuggestions) { app.handleUserText($0) }
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

    // MARK: Het gesprek

    private var thread: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(chat.messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 2)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: scrollKey) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            if let title = chat.active?.title {
                // De Nook waar je in zit, en hoe je een nieuwe begint.
                HStack(spacing: 6) {
                    Text(title)
                        .font(NookTheme.font(11.5, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                    NookIconButton(systemName: "square.and.pencil", label: "Nieuwe Nook", size: 26) {
                        app.newChat()
                    }
                }
                .padding(.leading, 10)
                .background(Capsule().fill(NookTheme.notch))
                .offset(y: -6)
            }
        }
    }

    /// Verandert zolang het antwoord binnenkomt, zodat de chat meescrollt.
    private var scrollKey: String {
        guard let last = chat.messages.last else { return "" }
        return "\(last.id)-\(last.text.count)-\(last.charts.count)-\(last.mails.count)-\(last.actions.count)-\(last.status)"
    }

    // MARK: Invoer

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $question,
                prompt: Text(chat.isEmpty ? "Vraag Nook iets…" : "Vraag door of reageer…").foregroundStyle(NookTheme.textTertiary),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(NookTheme.font(14))
            .foregroundStyle(NookTheme.paper)
            .lineLimit(1...5)
            .focused($inputFocused)
            .onSubmit(send)

            if chat.busy {
                NookIconButton(systemName: "stop.fill", label: "Stop", size: 28) { app.stopChat() }
            } else {
                NookIconButton(systemName: "mic", label: "Praat met Nook", size: 28) { viewModel.startListening() }
                NookIconButton(systemName: "arrow.up", label: "Verstuur", filled: !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, size: 28, action: send)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 21, style: .continuous).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(NookTheme.line2, lineWidth: 1))
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        app.handleUserText(text)
        inputFocused = true
    }
}

// MARK: Eén bericht

private struct ChatMessageView: View {
    let message: ChatMessage
    @EnvironmentObject private var app: AppModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: user
        case .nook: nook
        }
    }

    private var user: some View {
        HStack {
            Spacer(minLength: 80)
            Text(message.text)
                .font(NookTheme.font(14))
                .foregroundStyle(NookTheme.paper)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NookTheme.smoke))
        }
    }

    private var nook: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.sources.isEmpty {
                HStack(spacing: 5) {
                    ForEach(message.sources.prefix(5), id: \.self) { source in
                        Text(source)
                            .font(NookTheme.font(10.5, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NookTheme.graphite))
                            .lineLimit(1)
                    }
                }
            }

            if message.isError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text)
                        .font(NookTheme.font(13.5))
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    SmallGhostButton(title: "Instellingen") { app.openSettings() }
                }
            } else if !message.text.isEmpty {
                MarkdownView(text: message.text)
            } else if message.streaming && message.charts.isEmpty && message.mails.isEmpty {
                TypingIndicator(status: message.status)
            }

            ForEach(message.charts) { chart in
                ChatChartView(chart: chart)
            }

            ForEach(message.mails) { mail in
                MailDraftView(
                    draft: mail,
                    onSend: { app.sendMail($0) },
                    onOpen: { app.openMail($0) }
                )
                .id(mail.id)
            }

            if !message.actions.isEmpty {
                PlanBlock(message: message)
            }

            // Wat Nook hierna voor je kan doen: één klik en hij gaat aan de slag.
            if !message.streaming && !message.offers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.offers, id: \.self) { offer in
                        Button { app.handleUserText(offer) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(NookTheme.iris)
                                Text(offer)
                                    .font(NookTheme.font(12, .medium))
                                    .foregroundStyle(NookTheme.paper)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NookTheme.smoke))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Nook: \(offer)")
                    }
                }
            }

            if message.streaming && !message.text.isEmpty && !message.status.isEmpty {
                TypingIndicator(status: message.status)
            }

            if !message.streaming && !message.isError && !message.text.isEmpty {
                HStack(spacing: 2) {
                    SmallGhostButton(title: copied ? "Gekopieerd" : "Kopieer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                    }
                }
                .opacity(hovering ? 1 : 0)
                .padding(.top, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Wat Nook wil doen, met Uitvoeren en Annuleren. Er gebeurt niets voordat je klikt.
private struct PlanBlock: View {
    let message: ChatMessage
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(app.planSteps(message.actions)) { step in
                HStack(spacing: 10) {
                    Text("\(step.number)")
                        .font(NookTheme.font(10.5, .bold))
                        .foregroundStyle(color(step.tone))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(color(step.tone), lineWidth: 1.5))
                    Text(step.text)
                        .font(NookTheme.font(13.5))
                        .foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                    if !step.tag.isEmpty {
                        Text(step.tag)
                            .font(NookTheme.font(11.5, .medium))
                            .foregroundStyle(color(step.tone))
                    }
                }
            }

            HStack(spacing: 6) {
                switch message.planState {
                case .pending:
                    SmallPrimaryButton(title: "Uitvoeren", systemName: "checkmark") { app.runPlan(message.id) }
                    SmallGhostButton(title: "Annuleren") { app.cancelPlan(message.id) }
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Bezig…").font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textSecondary)
                case .done(let result):
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(NookTheme.mint)
                    Text(result).font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.mint)
                case .cancelled:
                    Text("Geannuleerd").font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary)
                case .failed(let error):
                    Text(error).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NookTheme.line2, lineWidth: 1))
    }

    private func color(_ tone: StepTone) -> Color {
        switch tone {
        case .good: return NookTheme.mint
        case .neutral: return NookTheme.textSecondary
        case .caution: return NookTheme.amber
        }
    }
}

/// Drie zachte puntjes terwijl Nook nadenkt, met wat hij nu doet.
private struct TypingIndicator: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(NookTheme.iris)
                            .frame(width: 6, height: 6)
                            .opacity(0.35 + 0.65 * abs(sin(t * 3 + Double(i) * 0.6)))
                    }
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel(status.isEmpty ? "Nook denkt na" : status)
    }
}

// MARK: Je Nooks

/// Al je Nooks onder elkaar: elk gesprek is een eigen Nook die aan één ding werkt. Bezig, wacht op jou of klaar
/// zie je aan het stipje. Een nieuwe begin je bovenaan; rechtsklik om er een weg te halen.
private struct NookList: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NewNookButton { app.newChat() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chat.history) { conversation in
                        NookRow(conversation: conversation, selected: conversation.id == chat.activeID) {
                            app.openConversation(conversation.id)
                        }
                        .contextMenu {
                            Button("Verwijder deze Nook", role: .destructive) { chat.delete(conversation.id) }
                        }
                    }
                }
            }
        }
        .padding(.trailing, 12)
        .overlay(alignment: .trailing) { Rectangle().fill(NookTheme.line).frame(width: 1) }
    }
}

private struct NewNookButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("Nieuwe Nook")
                    .font(NookTheme.font(12.5, .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? NookTheme.smoke : NookTheme.graphite))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut("n", modifiers: .command)
        .help("Begin een nieuwe Nook (⌘N)")
    }
}

private struct NookRow: View {
    let conversation: Conversation
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(status: conversation.status)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(NookTheme.font(12.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? NookTheme.paper : Color(hex: 0xC9C7D2))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? NookTheme.smoke : (hovering ? NookTheme.graphite : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(conversation.title), \(subtitle)")
    }

    private var subtitle: String {
        switch conversation.status {
        case .working: return "aan het werk…"
        case .waiting: return "wacht op jou"
        case .unread: return "klaar · " + NookDates.relative(conversation.updated)
        case .idle: return conversation.preview.isEmpty ? NookDates.relative(conversation.updated) : conversation.preview
        }
    }
}

/// Bezig (paars, ademt), wacht op jou (amber), nieuw antwoord (mint) of rustig (grijs).
private struct StatusDot: View {
    let status: Conversation.Status

    var body: some View {
        switch status {
        case .working:
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Circle().fill(NookTheme.iris).frame(width: 7, height: 7)
                    .opacity(0.45 + 0.55 * abs(sin(t * 2.6)))
            }
            .frame(width: 7, height: 7)
        case .waiting:
            Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .unread:
            Circle().fill(NookTheme.mint).frame(width: 7, height: 7)
        case .idle:
            Circle().stroke(NookTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}

// MARK: Hulpjes

/// Vragen om mee te beginnen, als kleine knoppen naast elkaar.
private struct SuggestionRow: View {
    let questions: [String]
    let ask: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(questions, id: \.self) { question in
                Button { ask(question) } label: {
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
