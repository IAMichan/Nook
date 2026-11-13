import SwiftUI

// The one scroll view every conversation on the phone reads in: a session, a chat with Nook, and a chat in your apps.
//
// It keeps what you read where it is. It opens at the newest message and follows what arrives only while you are at the
// end; once you scroll up it holds still, however much the agent writes, and an arrow over the composer brings you back.
// What floats over the end (the arrow, "Working for 12s") is an overlay, so it never changes the room the conversation
// has: a floating control that took room in the layout moved the text each time it came and went, and with the end
// tracked by distance that could flip back and forth while you read.

/// What a conversation's content and dock may ask of its scroll view.
@MainActor
struct ConversationScrollControl {
    fileprivate let proxy: ScrollViewProxy
    fileprivate let follow: () -> Void

    /// To the newest message, and following again from there (after you send something, for instance).
    func scrollToEnd(animated: Bool = true) {
        follow()
        if animated {
            withAnimation(Theme.reveal) { proxy.scrollTo(ConversationScrollEnd.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(ConversationScrollEnd.id, anchor: .bottom)
        }
    }

    /// A row by its id, without animation: after an older page came in above it, so it stays where you read it.
    func scrollTo(_ id: some Hashable, anchor: UnitPoint = .top) {
        proxy.scrollTo(id, anchor: anchor)
    }
}

enum ConversationScrollEnd {
    static let id = "conversation-end"
    /// Closer than this to the end counts as reading the end again.
    static let near: CGFloat = 32
    /// Farther than this, you left it to read; in between nothing changes, so the state never flickers.
    static let far: CGFloat = 120
}

/// A conversation that stays put while you read it (see the top of this file).
struct ConversationScroll<Content: View, Floating: View, Dock: View>: View {
    /// Changes whenever something new arrives at the end: a message, a step, text that streams in.
    let followKey: AnyHashable
    /// Room kept free under the last message for what floats over the end.
    var floatingRoom: CGFloat = 0
    @ViewBuilder var content: (ConversationScrollControl) -> Content
    /// Over the end of the conversation, beside the arrow back to it: "Working for 12s", for instance.
    @ViewBuilder var floating: () -> Floating
    /// Under the conversation: the composer, or what waits on you.
    @ViewBuilder var dock: (ConversationScrollControl) -> Dock

    @State private var atEnd = true
    /// Before iOS 18: the bottom of the part of the scroll view you see (`LegacyEndTracker`).
    @State private var visibleBottom: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            let control = ConversationScrollControl(proxy: proxy) { atEnd = true }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(control)
                    Color.clear
                        .frame(height: max(1, floatingRoom))
                        .id(ConversationScrollEnd.id)
                }
                .modifier(LegacyEndTracker(atEnd: $atEnd, visibleBottom: visibleBottom))
            }
            .coordinateSpace(name: LegacyEndTracker.space)
            .background {
                if #unavailable(iOS 18) {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { visibleBottom = geometry.size.height - geometry.safeAreaInsets.bottom }
                            .onChange(of: geometry.size.height - geometry.safeAreaInsets.bottom) { _, bottom in visibleBottom = bottom }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(EndAnchor(atEnd: atEnd))
            .modifier(EndTracker(atEnd: $atEnd))
            .onAppear { proxy.scrollTo(ConversationScrollEnd.id, anchor: .bottom) }
            // New at the end: followed only while you are there, without an animation that would wobble while text
            // streams in. Scrolled up, nothing moves.
            .onChange(of: followKey) { _, _ in
                guard atEnd else { return }
                proxy.scrollTo(ConversationScrollEnd.id, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: Theme.Spacing.md) {
                    floating()
                    if !atEnd {
                        ScrollToEndButton { control.scrollToEnd() }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, Theme.Spacing.md)
                .animation(Theme.reveal, value: atEnd)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock(control) }
        }
    }
}

/// The round arrow back to the newest message.
struct ScrollToEndButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: "arrow.down")
                .font(Theme.font(14, .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 40, height: 40)
                .floatingGlass(Circle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel("Scroll to end")
    }
}

/// Where the conversation stays when its size changes (iOS 18): at the end while you read the end, so new text pushes
/// the older text up; at what you read once you scrolled up, so text that arrives below never moves it. It opens at the
/// end either way. Before iOS 18 the scroll view keeps its offset, and `onAppear` opens it at the end.
private struct EndAnchor: ViewModifier {
    let atEnd: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(atEnd ? .bottom : .top, for: .sizeChanges)
        } else {
            content
        }
    }
}

/// How far the end is (iOS 18), with room between "at the end" and "left it" so the state does not flicker. Only your
/// own scrolling leaves the end: a long answer that arrives makes the content taller before the scroll view has
/// followed it, and that must not count as you scrolling away.
private struct EndTracker: ViewModifier {
    @Binding var atEnd: Bool
    @State private var scrolling = false

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onScrollPhaseChange { _, phase in
                    scrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: EndDistance.self) { geometry in
                    let visible = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                    if geometry.contentSize.height <= visible { return .near }
                    let maxOffset = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
                    return EndDistance(maxOffset - geometry.contentOffset.y)
                } action: { _, distance in
                    switch distance {
                    case .near where !atEnd: atEnd = true
                    case .far where atEnd && scrolling: atEnd = false
                    default: break
                    }
                }
        } else {
            content
        }
    }
}

/// Before iOS 18: the same distance, from where the content's bottom sits in the scroll view.
private struct LegacyEndTracker: ViewModifier {
    static let space = "conversation-scroll"
    @Binding var atEnd: Bool
    let visibleBottom: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
        } else {
            content
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ContentBottom.self, value: geometry.frame(in: .named(Self.space)).maxY)
                })
                .onPreferenceChange(ContentBottom.self) { bottom in
                    guard visibleBottom > 0 else { return }
                    switch EndDistance(bottom - visibleBottom) {
                    case .near where !atEnd: atEnd = true
                    case .far where atEnd: atEnd = false
                    default: break
                    }
                }
        }
    }
}

private enum EndDistance: Equatable {
    case near, between, far

    init(_ distance: CGFloat) {
        if distance < ConversationScrollEnd.near {
            self = .near
        } else if distance > ConversationScrollEnd.far {
            self = .far
        } else {
            self = .between
        }
    }
}

private struct ContentBottom: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
