import SwiftUI
import AVKit

/// A chat's video shown over the whole of Nook's main window, from where its bubble was: in a window that is split
/// with another app (or already full screen) it fills exactly that window's part of the screen, never the whole display.
/// In an ordinary window its full-screen button takes the window full screen, and closing the video brings it back.
/// Every chat app's videos come here, the ones sent as files and the ones a link points at (`VideoTile`). In the notch
/// there is no stage, and a video opens big in a window of its own (`VideoWindow`).
@MainActor
final class ChatVideoStage: ObservableObject {
    struct Video: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let time: CMTime
    }

    @Published var video: Video?

    func show(_ url: URL, name: String, at time: CMTime) {
        withAnimation(NookTheme.reveal) { video = Video(url: url, name: name, time: time) }
    }

    func close() {
        withAnimation(NookTheme.reveal) { video = nil }
    }
}

extension EnvironmentValues {
    /// Where a chat's video goes big: the main window's stage; nil in the notch.
    @Entry var chatVideoStage: ChatVideoStage?
}

extension View {
    /// Lets the chats in this window show their videos over all of it. Add it once, at the window's root.
    func chatVideoStage(_ stage: ChatVideoStage) -> some View {
        environment(\.chatVideoStage, stage)
            .overlay { ChatVideoStageOverlay(stage: stage) }
    }
}

private struct ChatVideoStageOverlay: View {
    @ObservedObject var stage: ChatVideoStage

    var body: some View {
        if let video = stage.video {
            ChatVideoStageView(video: video, onClose: stage.close)
                .id(video.id)
                .transition(.opacity)
        }
    }
}

/// The video itself over the window: the system's player with its controls, and buttons for full screen and to close
/// (Escape closes too).
private struct ChatVideoStageView: View {
    let video: ChatVideoStage.Video
    let onClose: () -> Void
    @State private var player: AVPlayer
    @State private var window: NSWindow?
    /// The window fills its screen or its part of a split screen.
    @State private var fullScreen = false
    /// The window went full screen for this video, so it comes back out when the video closes.
    @State private var enteredFullScreen = false

    init(video: ChatVideoStage.Video, onClose: @escaping () -> Void) {
        self.video = video
        self.onClose = onClose
        _player = State(initialValue: AVPlayer(url: video.url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StagePlayer(player: player)
                .ignoresSafeArea()
                .accessibilityLabel(video.name)
            HStack(spacing: NookTheme.Spacing.xs) {
                // Split with another app the window is already full screen, in its own part: it stays that way.
                if !fullScreen || enteredFullScreen {
                    stageButton(fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: tr(fullScreen ? "card.video.exitFullScreen" : "card.video.fullScreen"),
                                action: toggleFullScreen)
                }
                stageButton("xmark", label: tr("button.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(NookTheme.Spacing.md)
        }
        .background(StageWindowReader { window = $0 })
        .onChange(of: window) { _, window in fullScreen = window?.styleMask.contains(.fullScreen) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === window else { return }
            fullScreen = false
            enteredFullScreen = false
        }
        .onAppear {
            if video.time.isValid, video.time.seconds > 0 {
                player.seek(to: video.time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        }
        .onDisappear {
            player.pause()
            if enteredFullScreen, let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    private func toggleFullScreen() {
        guard let window else { return }
        enteredFullScreen = !fullScreen
        window.toggleFullScreen(nil)
    }

    private func stageButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.paper)
                .frame(width: 30, height: 30)
                .background(Circle().fill(NookTheme.ink.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The system's player at the size of the window, the picture whole.
private struct StagePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // Its own full screen would take the whole display, also out of a split screen: the stage's button does it.
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Reports the window the stage is in.
private struct StageWindowReader: NSViewRepresentable {
    let changed: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowView)?.changed = changed
    }

    private final class WindowView: NSView {
        var changed: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // Not while SwiftUI is still updating the view that holds this one.
            DispatchQueue.main.async { [weak self] in self?.changed?(window) }
        }
    }
}
