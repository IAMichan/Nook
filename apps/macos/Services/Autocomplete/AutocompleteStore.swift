import Foundation
import Combine

/// The settings of autocompletion, kept in UserDefaults.
@MainActor
final class AutocompleteStore: ObservableObject {
    static let shared = AutocompleteStore()

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "autocompleteEnabled") } }
    @Published var acceptKey: CompletionAcceptKey { didSet { defaults.set(acceptKey.rawValue, forKey: "autocompleteAcceptKey") } }
    /// The GGUF file the user picked by hand; empty means the model Cotypist downloaded.
    @Published var modelPath: String { didSet { defaults.set(modelPath, forKey: "autocompleteModelPath") } }

    private let defaults = UserDefaults.standard

    private init() {
        enabled = defaults.bool(forKey: "autocompleteEnabled")
        acceptKey = CompletionAcceptKey(rawValue: defaults.string(forKey: "autocompleteAcceptKey") ?? "") ?? .tab
        modelPath = defaults.string(forKey: "autocompleteModelPath") ?? ""
    }
}
