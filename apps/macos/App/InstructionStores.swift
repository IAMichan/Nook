import Combine
import Foundation

/// The saved prompts and the spaces, kept on this Mac in Nook's folder and shown in Settings › Instructions. The logic
/// lives in the Foundation-only `PromptLibrary` and `NookSpaceBook`; these only own the file and tell SwiftUI.
@MainActor
final class InstructionStore: ObservableObject {
    static let shared = InstructionStore()

    @Published private(set) var prompts: PromptLibrary
    @Published private(set) var spaces: NookSpaceBook
    /// The context of the last answer, for the inspector (Settings › Instructions); nil before the first one.
    @Published private(set) var lastContext: ContextBreakdown?

    private let promptsURL: URL
    private let spacesURL: URL

    init(directory: URL = NookPaths.supportDirectory) {
        promptsURL = directory.appendingPathComponent("prompts.json")
        spacesURL = directory.appendingPathComponent("spaces.json")
        prompts = PromptLibrary.load(promptsURL)
        spaces = NookSpaceBook.load(spacesURL)
    }

    func savePrompt(_ prompt: SavedPrompt) -> Bool {
        var next = prompts
        guard next.save(prompt) else { return false }
        prompts = next
        prompts.write(to: promptsURL)
        return true
    }

    func removePrompt(_ id: UUID) {
        var next = prompts
        next.remove(id)
        prompts = next
        prompts.write(to: promptsURL)
    }

    func saveSpace(_ space: NookSpace) {
        var next = spaces
        next.save(space)
        guard next != spaces else { return }
        spaces = next
        spaces.write(to: spacesURL)
    }

    func removeSpace(_ id: UUID) {
        var next = spaces
        next.remove(id)
        spaces = next
        spaces.write(to: spacesURL)
    }

    func assign(conversation: UUID, to space: UUID?) {
        var next = spaces
        next.assign(conversation: conversation, to: space)
        guard next != spaces else { return }
        spaces = next
        spaces.write(to: spacesURL)
    }

    /// What a conversation adds to the model's context besides the question: its answer style and its space's instructions.
    func instructionLines(for conversation: UUID) -> [String] {
        var lines: [String] = []
        if let style = ResponseStyleStore.shared.style(for: conversation).contextLine { lines.append(style) }
        if let space = spaces.space(of: conversation)?.contextText, !space.isEmpty { lines.append(space) }
        return lines
    }

    func noteContext(_ breakdown: ContextBreakdown) {
        guard breakdown != lastContext else { return }
        lastContext = breakdown
    }
}
