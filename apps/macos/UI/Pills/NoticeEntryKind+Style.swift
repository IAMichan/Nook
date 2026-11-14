import SwiftUI

extension NoticeEntry.Kind {
    /// The mark the confirmation strip shows for the same state; a plain notice gets Nook's bell.
    var symbol: String {
        switch self {
        case .done: return DoneTone.done.symbol
        case .failed: return DoneTone.failed.symbol
        case .waiting: return DoneTone.waiting.symbol
        case .info: return "bell.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: return DoneTone.done.color
        case .failed: return DoneTone.failed.color
        case .waiting: return DoneTone.waiting.color
        case .info: return NookTheme.iris
        }
    }
}
