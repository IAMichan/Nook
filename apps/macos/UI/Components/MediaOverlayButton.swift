import SwiftUI

/// The round dark mark over a picture or a video (play, enlarge, zoom, remove): a white symbol on a disc of
/// `NookTheme.ink`, so it reads on any picture in every appearance. A button over media is a `MediaOverlayButton`; use
/// the glyph alone where the picture itself is the button or the mark is only a hint.
struct MediaOverlayGlyph: View {
    enum Size {
        /// Removing an attachment from a field: 16 pt.
        case mini
        /// A corner button over a picture (enlarge, zoom): 26 pt.
        case small
        /// A button on a full-size stage: 30 pt.
        case medium
        /// The play mark in the middle of a video: 44 pt.
        case play

        var diameter: CGFloat {
            switch self {
            case .mini: return 16
            case .small: return 26
            case .medium: return 30
            case .play: return 44
            }
        }

        var symbol: CGFloat {
            switch self {
            case .mini: return 8
            case .small: return 11
            case .medium: return 12
            case .play: return 18
            }
        }

        var weight: Font.Weight { self == .mini ? .bold : .semibold }
    }

    let icon: String
    var size: Size = .small
    /// Under the pointer: the disc darkens a step.
    var emphasized: Bool = false

    init(_ icon: String, size: Size = .small, emphasized: Bool = false) {
        self.icon = icon
        self.size = size
        self.emphasized = emphasized
    }

    var body: some View {
        Image(icon: icon)
            .font(NookTheme.font(size.symbol, size.weight))
            .foregroundStyle(.white)
            .frame(width: size.diameter, height: size.diameter)
            .background(Circle().fill(NookTheme.ink.opacity(emphasized ? 0.7 : 0.55)))
    }
}

/// A round dark button over a picture or a video: a `MediaOverlayGlyph` with its tooltip and VoiceOver label. `detail`
/// names what it acts on for VoiceOver ("Play: holiday.mov").
struct MediaOverlayButton: View {
    let icon: String
    let label: String
    var size: MediaOverlayGlyph.Size = .small
    var detail: String? = nil
    let action: () -> Void

    init(_ icon: String, label: String, size: MediaOverlayGlyph.Size = .small, detail: String? = nil,
         action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.size = size
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MediaOverlayGlyph(icon, size: size)
                .contentShape(Circle())
        }
        .buttonStyle(.nookPlain)
        .help(label)
        .accessibilityLabel(detail.map { "\(label): \($0)" } ?? label)
    }
}
