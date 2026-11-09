import AppKit
import CoreImage
import SwiftUI

// Building blocks the Music tab's bar and full player share: artwork, transport, scrubbing, volume.

// MARK: Artwork

/// Downloaded covers, kept so the bar, the full player and the glow behind it show the same image without loading or
/// flickering again when the player unfolds. `NSCache` is thread-safe and drops entries under memory pressure.
final class MusicArtworkStore: @unchecked Sendable {
    static let shared = MusicArtworkStore()
    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    private let tints = NSCache<NSURL, NSArray>()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// The cover's two colours for its glow: the average of its upper-left and of its lower-right half, a little
    /// brighter and more saturated so they read as light on the dark canvas.
    func colors(for url: URL) async -> (NSColor, NSColor)? {
        if let known = tints.object(forKey: url as NSURL) as? [NSColor], known.count == 2 { return (known[0], known[1]) }
        guard let image = await image(for: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let found = await Task.detached(priority: .utility) { Self.averages(of: cg) }.value
        guard let found else { return nil }
        tints.setObject([found.0, found.1] as NSArray, forKey: url as NSURL)
        return found
    }

    private nonisolated static func averages(of image: CGImage) -> (NSColor, NSColor)? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func average(_ rect: CGRect) -> NSColor? {
            guard let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: rect)]),
                  let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return NSColor(hue: hue, saturation: min(1, saturation * 1.25), brightness: max(0.45, min(1, brightness * 1.15)), alpha: 1)
        }
        // Core Image's origin is the bottom left: the upper-left half is the top of the extent.
        let half = CGSize(width: extent.width / 2, height: extent.height / 2)
        guard let first = average(CGRect(origin: CGPoint(x: extent.minX, y: extent.midY), size: half)),
              let second = average(CGRect(origin: CGPoint(x: extent.midX, y: extent.minY), size: half)) else { return nil }
        return (first, second)
    }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard let response = try? await URLSession.shared.data(from: url), let image = NSImage(data: response.0) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A cover: the artwork when the player gives one, otherwise a placeholder whose colours follow `seed`.
struct MusicArtwork: View {
    let url: URL?
    let seed: String
    var symbol = "music.note"
    var cornerRadius: CGFloat = 8
    var showsSymbol = true
    @State private var image: NSImage?

    init(url: URL?, seed: String, symbol: String = "music.note", cornerRadius: CGFloat = 8, showsSymbol: Bool = true) {
        self.url = url
        self.seed = seed
        self.symbol = symbol
        self.cornerRadius = cornerRadius
        self.showsSymbol = showsSymbol
        // Start from the cache, so a cover that is already loaded is there in the very first frame.
        _image = State(initialValue: url.flatMap { MusicArtworkStore.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            MusicCoverPlaceholder(seed: seed, symbol: symbol, showsSymbol: showsSymbol)
                .opacity(image == nil ? 1 : 0)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // A faint edge, so a dark cover keeps its shape on the black canvas.
        .overlay {
            if cornerRadius > 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(NookTheme.paper.opacity(0.08), lineWidth: 1)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = MusicArtworkStore.shared.cached(url) { image = cached; return }
            // A view that now shows another track (a row that moved, a queue that changed) drops the old cover at once
            // instead of showing it until the new one has loaded.
            image = nil
            let loaded = await MusicArtworkStore.shared.image(for: url)
            withAnimation(NookTheme.reveal) { image = loaded }
        }
    }
}

/// The playing cover's colours as soft light: two radial washes in the cover's own colours (its upper-left and lower-right
/// halves, averaged once per cover), fading out from `center`. A card, the bar or the Now Playing page takes on the
/// track's colours without any edge, and without a blur to redraw.
struct MusicArtworkGlow: View {
    let url: URL?
    let seed: String
    var opacity = 0.4
    var center: UnitPoint = .center
    /// How far the light reaches, as a share of the larger side.
    var reach: CGFloat = 0.9
    @State private var colors: (Color, Color)?

    var body: some View {
        let pair = colors ?? MusicCoverPlaceholder.colors(for: seed)
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                RadialGradient(colors: [pair.0, pair.0.opacity(0.35), .clear], center: center, startRadius: 0, endRadius: side * reach)
                RadialGradient(colors: [pair.1.opacity(0.8), .clear],
                               center: UnitPoint(x: min(1, center.x + 0.35), y: min(1, center.y + 0.45)),
                               startRadius: 0, endRadius: side * reach * 0.7)
            }
            .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { colors = nil; return }
            if let found = await MusicArtworkStore.shared.colors(for: url) {
                withAnimation(NookTheme.reveal) { colors = (Color(nsColor: found.0), Color(nsColor: found.1)) }
            }
        }
    }
}

/// Over a cover in a row: the play symbol under the pointer, the bars while the track plays, nothing otherwise.
struct MusicArtworkState: View {
    let hovering: Bool
    let playing: Bool
    let isPlaying: Bool
    var cornerRadius = NookTheme.Radius.chip

    var body: some View {
        if hovering || playing {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.black.opacity(0.5))
                if hovering {
                    Image(systemName: "play.fill").font(NookTheme.font(12, .bold)).foregroundStyle(NookTheme.paper)
                } else {
                    EqualizerBars(color: NookTheme.music, height: 10, isPlaying: isPlaying)
                        .scaleEffect(0.7)
                }
            }
        }
    }
}

/// A gradient with a glyph, for tracks and playlists the player has no artwork for.
struct MusicCoverPlaceholder: View {
    let seed: String
    var symbol = "music.note"
    var showsSymbol = true

    private static let palette: [(UInt32, UInt32)] = [
        (0xFF8A5B, 0x4A1606), (0x7FD3C0, 0x0F3A33), (0xF5D27A, 0x5A3F0E), (0x8FB4FF, 0x1A2A5C),
        (0xFF9FC4, 0x4D1530), (0xC7A6F0, 0x2B1B45), (0xB9E27A, 0x2B4A0C),
    ]

    /// The two colours a cover without artwork is drawn in, for its glow.
    static func colors(for seed: String) -> (Color, Color) {
        let pair = palette[MusicCoverPalette.index(for: seed, count: palette.count)]
        return (Color(hex: pair.0), Color(hex: pair.1))
    }

    var body: some View {
        let pair = Self.palette[MusicCoverPalette.index(for: seed, count: Self.palette.count)]
        LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if showsSymbol {
                    GeometryReader { geo in
                        Image(systemName: symbol)
                            .font(NookTheme.font(max(10, min(geo.size.width, geo.size.height) * 0.3), .semibold))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
    }
}

// MARK: Transport

/// Shuffle, previous, play/pause, next and repeat. `large` is the full player's size.
struct MusicTransport: View {
    let info: NowPlayingInfo
    let service: NowPlayingService
    var large = false

    var body: some View {
        HStack(spacing: large ? NookTheme.Spacing.lg : NookTheme.Spacing.xs) {
            MusicToggleButton(systemName: "shuffle", label: tr("music.shuffle"), isOn: info.shuffle, size: large ? 34 : 28) {
                service.setShuffle(!info.shuffle)
            }
            NookIconButton(systemName: "backward.fill", label: tr("music.previous"), size: large ? 36 : 28) { service.control(.previous) }
                .help(tr("music.previous"))
            NookIconButton(
                systemName: info.isPlaying ? "pause.fill" : "play.fill",
                label: info.isPlaying ? tr("music.pause") : tr("music.play"),
                filled: true,
                size: large ? 48 : 32
            ) { service.control(.playPause) }
                .help(info.isPlaying ? tr("music.pause") : tr("music.play"))
            NookIconButton(systemName: "forward.fill", label: tr("music.next"), size: large ? 36 : 28) { service.control(.next) }
                .help(tr("music.next"))
            MusicToggleButton(systemName: "repeat", label: tr("music.repeat"), isOn: info.repeating, size: large ? 34 : 28) {
                service.setRepeat(!info.repeating)
            }
        }
    }
}

/// Mm:ss format for elapsed and remaining time.
func musicClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Progress bar for scrubbing: click or drag. `.inline` puts the times beside the bar (the compact bar), `.stacked`
/// under it (the full player, where the bar gets the whole width).
struct MusicScrubBar: View {
    enum Style { case inline, stacked }

    let info: NowPlayingInfo
    var style: Style = .inline
    let onSeek: (Double) -> Void
    /// Scrub drag destination (0…1). `nil` when not scrubbing.
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        // Spotify and Music are polled every 2 seconds; time advances locally in between. Paused, the position stands
        // still, so the clock does too (a drag or a new poll still redraws it).
        TimelineView(.animation(minimumInterval: 0.5, paused: !info.isPlaying)) { context in
            let duration = Double(info.duration)
            let position = dragFraction.map { $0 * duration } ?? info.estimatedPosition(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            let elapsed = Text(musicClock(position))
            let remaining = Text(duration > 0 ? "-" + musicClock(duration - position) : "–:––")
            switch style {
            case .inline:
                HStack(spacing: NookTheme.Spacing.md) {
                    elapsed.frame(width: 34, alignment: .trailing)
                    bar(fraction: fraction, duration: duration)
                    remaining.frame(width: 38, alignment: .leading)
                }
            case .stacked:
                VStack(spacing: NookTheme.Spacing.xxs) {
                    bar(fraction: fraction, duration: duration)
                    HStack {
                        elapsed
                        Spacer(minLength: NookTheme.Spacing.md)
                        remaining
                    }
                }
            }
        }
        .font(NookTheme.TextStyle.caption.monospacedDigit())
        .foregroundStyle(dragFraction == nil ? NookTheme.textTertiary : NookTheme.textSecondary)
    }

    private func bar(fraction: Double, duration: Double) -> some View {
        let enabled = duration > 0
        let active = enabled && (hovering || dragFraction != nil)
        let thickness: CGFloat = style == .inline ? (active ? 5 : 3) : (active ? 6 : 4)
        return GeometryReader { geo in
            let width = max(1, geo.size.width)
            let filled = width * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.line2).frame(height: thickness)
                Capsule()
                    .fill(active ? NookTheme.music : NookTheme.paper)
                    .frame(width: filled, height: thickness)
                if active {
                    Circle()
                        .fill(NookTheme.paper)
                        .frame(width: 11, height: 11)
                        .offset(x: min(max(0, filled - 5.5), width - 11))
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        dragFraction = Double(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        guard enabled else { return }
                        let target = Double(min(1, max(0, value.location.x / width)))
                        onSeek(target * duration)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
        .animation(NookTheme.reveal, value: active)
        .accessibilityElement()
        .accessibilityLabel(tr("music.progress"))
        .accessibilityValue("\(musicClock(fraction * duration)) / \(musicClock(duration))")
    }
}

/// Small toggle button (shuffle, repeat). On = music color with an indicator dot below.
struct MusicToggleButton: View {
    let systemName: String
    let label: String
    let isOn: Bool
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(NookTheme.font(size * 0.44, .semibold))
                .foregroundStyle(isOn ? NookTheme.music : (hovering ? NookTheme.paper : NookTheme.textTertiary))
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? NookTheme.smoke : Color.clear))
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(NookTheme.music)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(isOn ? 1 : 0)
                        .offset(y: -2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.reveal, value: isOn)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? tr("music.on") : tr("music.off"))
    }
}

/// Player volume: speaker icon (click to mute/unmute) and a draggable slider.
struct MusicVolumeControl: View {
    let volume: Int
    var width: CGFloat = 84
    let onChange: (Int) -> Void
    @State private var dragValue: Int?
    @State private var beforeMute = 50
    @State private var hovering = false

    private var shown: Int { dragValue ?? volume }

    private var icon: String {
        switch shown {
        case 0: return "speaker.slash.fill"
        case 1..<34: return "speaker.wave.1.fill"
        case 34..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Button {
                if shown > 0 {
                    beforeMute = shown
                    onChange(0)
                } else {
                    onChange(max(10, beforeMute))
                }
            } label: {
                Image(systemName: icon)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 20, height: 24, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown > 0 ? tr("music.mute") : tr("music.unmute"))
            .accessibilityLabel(shown > 0 ? tr("music.mute") : tr("music.unmute"))

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let filled = width * CGFloat(shown) / 100
                let thickness: CGFloat = (hovering || dragValue != nil) ? 5 : 3
                ZStack(alignment: .leading) {
                    Capsule().fill(NookTheme.line2).frame(height: thickness)
                    Capsule().fill(NookTheme.paper).frame(width: filled, height: thickness)
                }
                .frame(width: width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let next = Int((min(1, max(0, value.location.x / width)) * 100).rounded())
                            if next != dragValue {
                                dragValue = next
                                onChange(next)
                            }
                        }
                        .onEnded { _ in dragValue = nil }
                )
            }
            .frame(width: width, height: 16)
            .accessibilityElement()
            .accessibilityLabel(tr("music.volume"))
            .accessibilityValue(tr("music.percent", shown))
        }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// Opens Spotify or Music itself.
func openMusicPlayer(_ info: NowPlayingInfo) {
    let bundleID = info.app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The player's name as the UI shows it: Music is translated, Spotify is not.
func musicPlayerName(_ info: NowPlayingInfo) -> String {
    info.app == "Music" ? tr("tab.music") : info.app
}
