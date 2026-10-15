import Foundation

/// An error with a message that can be shown to the user as is.
struct NookError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
