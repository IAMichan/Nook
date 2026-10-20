import Foundation

/// The look every orb draws itself with, kept in sync by `AppSettings.nookLook`. Its own small object, so a change
/// redraws the orbs (also ones that are not animating) without them observing all of the settings.
@MainActor
final class NookAppearance: ObservableObject {
    static let shared = NookAppearance()

    @Published var look: NookLook = .classic
    /// What Nook wears right now, worked out from the wardrobe in Settings and the moment (`AppModel+Buddy`).
    @Published var outfit: [NookAccessory] = []

    private init() {}
}
