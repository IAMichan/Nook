import SwiftUI
import AppKit

/// The bar above a selection or the card with Nook's answer, whichever `SelectionAskModel` is at, drawn at its own size
/// with room around it for the shadow; the panel follows that size (`SelectionAskController.resized`).
struct SelectionAskRoot: View {
    @ObservedObject var model: SelectionAskModel
    let controller: SelectionAskController

    /// The room around the bar and card for their shadow, inside the panel.
    static let margin = NookTheme.Spacing.lg

    var body: some View {
        Group {
            switch model.stage {
            case .hidden:
                EmptyView()
            case .bar:
                SelectionAskBar(model: model, controller: controller)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            case .card(let conversation):
                SelectionAskCard(model: model, controller: controller, conversation: conversation)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(Self.margin)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.resized($0) }
    }
}

/// Above a selection: Ask Nook first (it answers a question, or says what matters about what is not one), then Explain
/// and Translate, and Quote where the words came from a session's answer. One quiet capsule, Nook's accent on its mark.
private struct SelectionAskBar: View {
    @ObservedObject var model: SelectionAskModel
    let controller: SelectionAskController

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            // With Selection Ask off, words of a session's answer still get the floating Quote on its own.
            if !model.quoteOnly {
                SelectionBarButton(symbol: SelectionAsk.Mode.answer.symbol, title: SelectionAsk.Mode.answer.title, accent: true) {
                    controller.ask(.answer)
                }
                ComposerDivider()
                ForEach([SelectionAsk.Mode.explain, .translate], id: \.self) { mode in
                    SelectionBarButton(symbol: mode.symbol, title: mode.title) { controller.ask(mode) }
                }
            }
            if model.quote != nil {
                if !model.quoteOnly { ComposerDivider() }
                SelectionBarButton(symbol: "text.quote", title: tr("selectionAsk.quote")) { controller.quoteSelection() }
            }
        }
        .padding(NookTheme.Spacing.xs)
        .background(Capsule().fill(NookTheme.surface))
        .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
        .shadow(color: NookTheme.notch.opacity(0.45), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("selectionAsk.bar"))
    }
}

private struct SelectionBarButton: View {
    let symbol: String
    let title: String
    var accent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: symbol)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(accent ? NookTheme.iris : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering || accent ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(title)
    }
}

/// Nook's answer beside the selection: the selected words on top, the answer as the chat draws it (`ChatMessageView`:
/// the same typing line, sources, plan and offers), and a field for a follow-up. The conversation is an ordinary one, so
/// Continue in chat opens it with everything in it.
struct SelectionAskCard: View {
    @ObservedObject var model: SelectionAskModel
    let controller: SelectionAskController
    let conversation: UUID
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var chat: NookChat
    @FocusState private var focused: Bool
    /// `@` in the follow-up: people from your chats by name.
    @StateObject private var mentionModel = ComposerModel()
    /// How tall the conversation is, so the card hugs a short answer and scrolls a long one.
    @State private var contentHeight: CGFloat = 0

    static let maxAnswerHeight: CGFloat = 380

    init(model: SelectionAskModel, controller: SelectionAskController, conversation: UUID) {
        self.model = model
        self.controller = controller
        self.conversation = conversation
        _chat = ObservedObject(wrappedValue: AppModel.shared.chat)
    }

    /// What came after the question the bar asked (that one shows as the quote on top).
    private var messages: [ChatMessage] {
        Array((chat.conversation(conversation)?.messages ?? []).dropFirst())
    }

    private var busy: Bool { chat.isBusy(conversation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            NookDivider()
            answer
            NookDivider()
            SessionComposer(text: $model.draft, prompt: tr("selectionAsk.followUp"), focus: $focused, busy: busy,
                            onStop: { app.stop(conversation: conversation) }, sendLabel: tr("card.send"),
                            onSend: { controller.sendFollowUp() }) { EmptyView() }
                .rich(mentionModel, .mentions())
                .padding(NookTheme.Spacing.md)
        }
        .frame(width: SelectionAskController.cardWidth)
        .composerFocusOnAppear($focused)
        .cardBackground(NookTheme.surface, stroke: NookTheme.line2, radius: NookTheme.Radius.panel, style: .continuous)
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        .shadow(color: NookTheme.notch.opacity(0.5), radius: 14, y: 6)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Image(systemName: "text.quote")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.iris)
                .padding(.top, NookTheme.Spacing.xxs)
            Text(model.selection)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            ToolbarIconButton("arrow.up.forward.square", tr("selectionAsk.openInChat")) { controller.continueInChat() }
            ToolbarIconButton("xmark", tr("selectionAsk.close")) { controller.dismiss() }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
    }

    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                ForEach(messages) { message in
                    switch message.role {
                    case .user:
                        TranscriptUserMessage(text: message.text, date: message.date)
                    case .nook:
                        ChatMessageView(message: message, isNewest: message.id == messages.last?.id, app: app,
                                        onAsk: { app.followUpOnSelection($0, in: conversation) })
                            .equatable()
                    }
                }
            }
            .padding(NookTheme.Spacing.lg)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.automatic)
        .frame(height: min(max(contentHeight, 64), Self.maxAnswerHeight))
    }
}
