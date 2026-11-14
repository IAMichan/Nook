import XCTest

/// Nook proposes a local model that suits each user's Mac.
final class ModelAdvisorTests: XCTestCase {
    private func first(_ memory: Int, arm: Bool = true, installed: Set<String> = [], servers: [ServerModel] = []) -> ModelAdvisor.Recommendation {
        ModelAdvisor.recommend(hardware: .init(memoryGB: memory, appleSilicon: arm), installedMLX: installed, serverModels: servers)[0]
    }

    private func mlxID(_ recommendation: ModelAdvisor.Recommendation) -> String? {
        if case .mlx(let option) = recommendation.choice { return option.id }
        return nil
    }

    func testPicksByMemory() {
        XCTAssertEqual(mlxID(first(8)), "mlx-community/Qwen3.5-4B-4bit")
        XCTAssertEqual(mlxID(first(16)), "mlx-community/Qwen3.5-9B-4bit")
        XCTAssertEqual(mlxID(first(24)), "mlx-community/Qwen3.5-9B-4bit")
        XCTAssertEqual(mlxID(first(32)), "mlx-community/Qwen3.6-27B-4bit")
        XCTAssertEqual(mlxID(first(64)), "mlx-community/Qwen3.6-35B-A3B-4bit")
    }

    func testInstalledBestModelIsReadyAndFirst() {
        let top = first(16, installed: ["mlx-community/Qwen3.5-9B-4bit"])
        XCTAssertEqual(mlxID(top), "mlx-community/Qwen3.5-9B-4bit")
        XCTAssertTrue(top.ready)
    }

    func testAnOlderInstalledModelStaysUsableButTheNewOneIsProposed() {
        let all = ModelAdvisor.recommend(hardware: .init(memoryGB: 16, appleSilicon: true),
                                         installedMLX: ["mlx-community/Qwen3-8B-4bit"], serverModels: [])
        XCTAssertEqual(mlxID(all[0]), "mlx-community/Qwen3.5-9B-4bit")
        XCTAssertTrue(all.contains { mlxID($0) == "mlx-community/Qwen3-8B-4bit" && $0.ready })
    }

    func testEveryModelHasAFamilyAndFitsItsWindow() {
        for option in ModelAdvisor.catalog {
            XCTAssertNotEqual(option.family, .other, option.id)
            XCTAssertLessThan(option.profile.maxOutputTokens, option.profile.contextTokens / 2, option.id)
            XCTAssertLessThanOrEqual(option.profile.thinkingOutputTokens, option.profile.contextTokens / 2, option.id)
        }
        XCTAssertEqual(Set(ModelAdvisor.catalog.map(\.id)).count, ModelAdvisor.catalog.count, "no duplicates")
    }

    func testSamplingFollowsTheModelMakers() {
        XCTAssertEqual(ModelFamily.qwen.sampling(thinking: false), ModelSampling(temperature: 0.7, topP: 0.8, topK: 20))
        XCTAssertEqual(ModelFamily.qwen.sampling(thinking: true).topP, 0.95)
        XCTAssertEqual(ModelFamily.gemma4.sampling(thinking: false).topK, 64)
        XCTAssertEqual(ModelFamily.gemma4.stopTokens, ["<turn|>"])
    }

    func testThinkingOnlyForHardQuestions() {
        XCTAssertFalse(ThinkingPolicy.wantsThinking("Hoi!"))
        XCTAssertFalse(ThinkingPolicy.wantsThinking("Wat staat er morgen in mijn agenda?"))
        XCTAssertTrue(ThinkingPolicy.wantsThinking("Waarom faalt de build van Nook?"))
        XCTAssertTrue(ThinkingPolicy.wantsThinking("Vergelijk de offertes van Sanne en Pieter"))
        XCTAssertTrue(ThinkingPolicy.wantsThinking("Explain step by step how OAuth works"))
    }

    func testReasoningIsNeverShown() {
        XCTAssertEqual(ThinkingPolicy.answer(from: "Let me think…\n</think>\n\nHet antwoord", thinking: true), "\n\nHet antwoord")
        XCTAssertEqual(ThinkingPolicy.answer(from: "Still reasoning about", thinking: true), "", "nothing shows before the reasoning ends")
        XCTAssertEqual(ThinkingPolicy.answer(from: "<think>x</think>Antwoord", thinking: false), "Antwoord")
        XCTAssertEqual(ThinkingPolicy.answer(from: "Gewoon antwoord", thinking: false), "Gewoon antwoord")
        XCTAssertEqual(ThinkingPolicy.answer(from: "Begin <think>half", thinking: false), "Begin ")
    }

    /// Answers that stress the streaming cuts: reasoning opened by the template, reasoning blocks of the model's own, tool
    /// calls written as JSON (with and without a fence), <tool_call> tags and text that is not ASCII.
    private let streamedAnswers: [String] = [
        "Let me think…\nabout it\n</think>\n\nHet antwoord is 42.",
        "<think>first a thought</think>Het antwoord <think>another</think>gaat door.",
        "Even kijken.\n```json\n{\"name\": \"calendar\", \"parameters\": {}}\n```",
        "Ik zoek het op. { \"tool\" : \"mail\" }",
        "Antwoord <tool_call>{\"name\": \"x\"}</tool_call> rest",
        "Café ☕️ 👩‍👩‍👧 — naïve { \"na\nme\": no call } done",
        "</think></think>twice closed",
        "thinking text\n</think>answer<think>open and never closed",
        "A <thin k> that is not a tag and a </thin> either, then </think>after",
        "``` not json\n{\n  \"name\"\n  :\n \"weather\"}",
        "   \n\n  ",
        "tools: name json `{` and \"name\" without a colon",
    ]

    func testStreamingAnswerMatchesTheWholeText() {
        for thinking in [false, true] {
            for sample in streamedAnswers {
                // One character at a time: every prefix must give what the whole-text function gives.
                var answer = StreamingAnswer(thinking: thinking)
                var prefix = ""
                for character in sample {
                    prefix.append(character)
                    answer.append(String(character))
                    XCTAssertEqual(answer.visible, ThinkingPolicy.visible(prefix, thinking: thinking),
                                   "prefix: \(prefix.debugDescription), thinking: \(thinking)")
                }
                // Pieces of several characters, as a model sends them.
                for size in [2, 3, 5, 7, 11] {
                    var answer = StreamingAnswer(thinking: thinking)
                    var prefix = ""
                    let characters = Array(sample)
                    for start in stride(from: 0, to: characters.count, by: size) {
                        let piece = String(characters[start..<min(start + size, characters.count)])
                        prefix += piece
                        answer.append(piece)
                        XCTAssertEqual(answer.visible, ThinkingPolicy.visible(prefix, thinking: thinking),
                                       "prefix: \(prefix.debugDescription), piece size \(size), thinking: \(thinking)")
                    }
                }
            }
        }
    }

    func testStreamingAnswerHidesReasoningAndToolCalls() {
        var answer = StreamingAnswer(thinking: true)
        answer.append("Still reasoning </thi")
        XCTAssertEqual(answer.visible, "", "nothing shows before the reasoning ends")
        answer.append("nk>\nHet antwoord")
        XCTAssertEqual(answer.visible, "Het antwoord")
        answer.append(" {\"name\": \"calendar\"")
        XCTAssertEqual(answer.visible, "Het antwoord", "a tool call being written is never shown")
        answer.append(" en meer")
        XCTAssertEqual(answer.visible, "Het antwoord")
    }

    func testExistingOllamaModelBeatsADownload() {
        let top = first(16, servers: [ServerModel(server: .ollama, name: "qwen2.5:7b-instruct")])
        XCTAssertEqual(top.choice, .server(ServerModel(server: .ollama, name: "qwen2.5:7b-instruct")))
        XCTAssertTrue(top.ready)
    }

    func testServerModelsThatDoNotFitAreIgnored() {
        let top = first(16, servers: [ServerModel(server: .ollama, name: "llama3.3:70b"), ServerModel(server: .ollama, name: "nomic-embed-text")])
        XCTAssertNotNil(mlxID(top), "a 70B model does not fit in 16 GB and an embedding model cannot chat")
    }

    func testIntelMacGetsAnExplanation() {
        let top = first(32, arm: false)
        XCTAssertEqual(top.choice, .unavailable)
        XCTAssertEqual(top.reason, tr("advisor.reason.needsSilicon"))
        XCTAssertEqual(first(32, arm: false, servers: [ServerModel(server: .lmstudio, name: "qwen2.5-7b-instruct")]).choice,
                       .server(ServerModel(server: .lmstudio, name: "qwen2.5-7b-instruct")))
    }

    func testTooLittleMemory() {
        XCTAssertEqual(first(4).choice, .unavailable)
    }

    func testParameterSizeFromName() {
        XCTAssertEqual(ModelAdvisor.parameterBillions("qwen2.5:14b"), 14)
        XCTAssertEqual(ModelAdvisor.parameterBillions("llama3.2:3b-instruct-q4"), 3)
        XCTAssertEqual(ModelAdvisor.parameterBillions("phi3.5:3.8b"), 4)
        XCTAssertNil(ModelAdvisor.parameterBillions("mistral"))
        XCTAssertEqual(ModelAdvisor.profile(forServerModel: "qwen2.5:14b"), .localXL)
        XCTAssertEqual(ModelAdvisor.profile(forServerModel: "llama3.2:3b"), .localSmall)
    }

    func testBudgetShortensLowestPriorityFirst() {
        let parts = [
            ContextBudget.Part(text: String(repeating: "s", count: 100), priority: 3),
            ContextBudget.Part(text: String(repeating: "c", count: 300), priority: 1, minimum: 50),
            ContextBudget.Part(text: String(repeating: "h", count: 200), priority: 2)
        ]
        let fitted = ContextBudget.fit(parts, budget: 400)
        XCTAssertEqual(fitted[0].count, 100, "the highest priority part is untouched")
        XCTAssertEqual(fitted[2].count, 200)
        XCTAssertTrue(fitted[1].hasPrefix(String(repeating: "c", count: 100)))
        XCTAssertLessThan(fitted[1].count, 300)
        XCTAssertEqual(ContextBudget.fit(parts, budget: 1_000).map(\.count), [100, 300, 200], "fits already: unchanged")
    }

    func testProfileBudgets() {
        XCTAssertGreaterThan(ModelProfile.cloud.promptCharacterBudget, ModelProfile.localLarge.promptCharacterBudget)
        XCTAssertGreaterThan(ModelProfile.localLarge.promptCharacterBudget, ModelProfile.localSmall.promptCharacterBudget)
        XCTAssertEqual(ModelProfile.estimateTokens(String(repeating: "a", count: 700)), 200)
    }
}
