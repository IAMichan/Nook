import SwiftUI
import AVKit

/// A chat's video or photo shown over the whole of Nook's main window, from where its bubble was: in a window that is
/// split with another app (or already full screen) it fills exactly that window's part of the screen, never the whole
/// display. For a video, its full-screen button takes an ordinary window full screen, and closing the video brings it
/// back. Every chat app's videos come here, the ones sent as files and the ones a link points at (`VideoTile`), and so
/// does every picture that is enlarged (`ImageModal`). The notch's panel has a stage for pictures only
/// (`NotchPanelStage`): a video opens big in a window of its own (`VideoWindow`), and a card shows a photo over itself.
@MainActor
final class ChatMediaStage: ObservableObject {
    struct Video: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let time: CMTime
    }

    struct Photo: Identifiable {
        let id = UUID()
        let url: URL
        let preview: NSImage
        let name: String
        /// Shows the photo in its app (Quick Look); the stage closes first.
        let open: () -> Void
    }

    @Published var video: Video?
    @Published var photo: Photo?
    /// Whether videos play here too; where they do not, they open in `VideoWindow`.
    let playsVideos: Bool

    init(playsVideos: Bool = true) {
        self.playsVideos = playsVideos
    }

    /// Whether a video or photo is on the stage.
    var isShowing: Bool { video != nil || photo != nil }

    func show(_ url: URL, name: String, at time: CMTime) {
        withAnimation(NookTheme.reveal) {
            photo = nil
            video = Video(url: url, name: name, time: time)
        }
    }

    func show(photo url: URL, preview: NSImage, name: String, open: @escaping () -> Void) {
        withAnimation(NookTheme.reveal) {
            video = nil
            photo = Photo(url: url, preview: preview, name: name, open: open)
        }
    }

    func close() {
        withAnimation(NookTheme.reveal) {
            video = nil
            photo = nil
        }
    }
}

extension EnvironmentValues {
    /// Where a chat's video or a picture goes big: the stage of the window or the notch's panel; nil on a notch card.
    @Entry var chatMediaStage: ChatMediaStage?
}

extension View {
    /// Lets the chats in this window show their videos and photos over all of it. Add it once, at the window's root.
    func chatMediaStage(_ stage: ChatMediaStage) -> some View {
        environment(\.chatMediaStage, stage)
            .overlay { ChatMediaStageOverlay(stage: stage) }
    }
}

/// The notch's panel with a stage for pictures. It is closed with the panel, so a picture never waits for the next time.
struct NotchPanelStage<Content: View>: View {
    @StateObject private var stage = ChatMediaStage(playsVideos: false)
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .chatMediaStage(stage)
            .onDisappear { stage.close() }
    }
}

private struct ChatMediaStageOverlay: View {
    @ObservedObject var stage: ChatMediaStage

    var body: some View {
        ZStack {
            if let video = stage.video {
                ChatVideoStageView(video: video, onClose: stage.close)
                    .id(video.id)
                    .transition(.opacity)
            } else if let photo = stage.photo {
                ImageModal(url: photo.url, preview: photo.preview, name: photo.name, fills: true,
                           onClose: stage.close,
                           onOpen: { stage.close(); photo.open() })
                    .id(photo.id)
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

/// The video itself over the window or panel: the system's player with its controls, and buttons to exit full screen and to close
/// (Escape closes too).
private struct ChatVideoStageView: View {
    let video: ChatMediaStage.Video
    let onClose: () -> Void
    /// Waits for a file still coming in and says so when it cannot be played (`ChatVideoPlayback`).
    @StateObject private var playback: ChatVideoPlayback

    init(video: ChatMediaStage.Video, onClose: @escaping () -> Void) {
        self.video = video
        self.onClose = onClose
        _playback = StateObject(wrappedValue: ChatVideoPlayback(url: video.url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            switch playback.phase {
            case .ready:
                StagePlayer(player: playback.player)
                    .accessibilityLabel(video.name)
            case .loading:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(tr("card.video.loading"))
            case .failed:
                ChatVideoFailure(url: video.url, retry: playback.retry)
            }
            HStack(spacing: NookTheme.Spacing.xs) {
                stageButton("arrow.down.right.and.arrow.up.left",
                            label: tr("card.video.exitFullScreen"),
                            action: onClose)
                stageButton("xmark", label: tr("button.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(NookTheme.Spacing.md)
        }
        .onAppear { playback.start(at: video.time) }
        .onDisappear {
            playback.stop()
        }
    }

    private func stageButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: symbol)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.paper)
                .frame(width: 30, height: 30)
                .background(Circle().fill(NookTheme.ink.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.nookPlain)
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
