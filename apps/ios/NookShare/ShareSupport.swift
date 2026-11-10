import UIKit

/// The app's light taps, for the parts of the app the share sheet reuses (`AttachPictureButton`, `ImageTray`).
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
