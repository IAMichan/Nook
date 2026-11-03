import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A chat's video readied for the system's player, the same for every chat app (WhatsApp, Messages, Telegram, Slack,
/// Signal, Instagram, Messenger…) and every place it plays (the bubble, the stage, the video window, a GIF that came as
/// a video). A bridge hands over a file the moment it exists, often while its app or helper is still writing it; the
/// player then fails on it at once and never tries again. Here the file is waited for until it is complete and
/// AVFoundation can play it, and a file without a name it recognizes ("dbe80cq9", "video.bin") is told what it holds.
enum ChatVideoAsset {
    /// The waits between tries while a file is still coming in: about 25 seconds in all.
    static let waits: [Double] = [0, 0.4, 0.8, 1.5, 2.5, 4, 6, 10]

    /// The video ready to play, or nil when it is still no video AVFoundation can play once the waits are over.
    static func load(_ url: URL, waits: [Double] = Self.waits) async -> AVURLAsset? {
        var lastSize: Int?
        for wait in waits {
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            if Task.isCancelled { return nil }
            if url.isFileURL {
                // A file that is missing, empty or still growing is not tried yet; the last try takes it as it is.
                guard let size = fileSize(url), size > 0 else { continue }
                defer { lastSize = size }
                if let lastSize, lastSize != size { continue }
                if lastSize == nil, !ChatMedia.isSettled(url), wait != waits.last { continue }
            }
            let asset = AVURLAsset(url: url, options: options(url))
            guard (try? await asset.load(.isPlayable)) == true,
                  let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { continue }
            return asset
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// For a file whose name says nothing AVFoundation knows, what its first bytes say it is.
    private static func options(_ url: URL) -> [String: Any]? {
        guard url.isFileURL else { return nil }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) { return nil }
        guard let mime = sniffedType(url) else { return nil }
        return [AVURLAssetOverrideMIMETypeKey: mime]
    }

    /// The MIME type of a video file by its first bytes (`ChatMedia.videoMIMEType`).
    static func sniffedType(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 12)).flatMap(ChatMedia.videoMIMEType(head:))
    }
}

/// A chat video playing: waits for its file (`ChatVideoAsset`), tries once more when the player fails on it anyway (a
/// file replaced while it played, a decoder that gave up), and otherwise says it cannot be played, so a view shows a
/// way out instead of the player's crossed-out play button.
@MainActor
final class ChatVideoPlayback: ObservableObject {
    enum Phase: Equatable {
        case loading, ready, failed
    }

    let url: URL
    let player = AVPlayer()
    @Published private(set) var phase: Phase = .loading
    private var task: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []
    private var retried = false

    init(url: URL) {
        self.url = url
    }

    /// Plays the video from `time` as soon as its file is ready.
    func start(at time: CMTime = .zero, autoplay: Bool = true) {
        task?.cancel()
        watching = []
        phase = .loading
        task = Task { [weak self, url] in
            let asset = await ChatVideoAsset.load(url)
            guard let self, !Task.isCancelled else { return }
            guard let asset else {
                self.phase = .failed
                return
            }
            self.play(AVPlayerItem(asset: asset), at: time, autoplay: autoplay)
        }
    }

    /// Tried anew from the start, also after it failed twice.
    func retry() {
        retried = false
        start(at: .zero)
    }

    func pause() {
        player.pause()
    }

    func stop() {
        task?.cancel()
        watching = []
        player.pause()
    }

    var currentTime: CMTime { player.currentTime() }

    private func play(_ item: AVPlayerItem, at time: CMTime, autoplay: Bool) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .failed { self?.failed() }
            }
            .store(in: &watching)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.failed() }
            .store(in: &watching)
        player.replaceCurrentItem(with: item)
        phase = .ready
        if time.isValid, time.seconds > 0 {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay { player.play() }
    }

    /// The player gave up on the video: once more from where it was, then it says so.
    private func failed() {
        guard phase != .failed else { return }
        let time = player.currentTime()
        player.replaceCurrentItem(with: nil)
        if retried {
            watching = []
            phase = .failed
            return
        }
        retried = true
        start(at: time)
    }
}

/// What stands where a chat video could not be played, in every place one plays: why, a button to try again, and one
/// that opens the file in the Mac's own app for it.
struct ChatVideoFailure: View {
    let url: URL
    let retry: () -> Void

    var body: some View {
        VStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper.opacity(0.85))
            Text(tr("card.video.unplayable"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.paper)
                .multilineTextAlignment(.center)
            HStack(spacing: NookTheme.Spacing.xs) {
                button("arrow.clockwise", tr("card.video.retry"), action: retry)
                if url.isFileURL || url.scheme == "https" {
                    button("arrow.up.forward.app", tr("card.video.openElsewhere")) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NookTheme.ink.opacity(0.55))
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, NookTheme.Spacing.sm)
                .padding(.vertical, NookTheme.Spacing.xxs)
                .background(Capsule().fill(NookTheme.ink.opacity(0.6)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
