import Foundation
import MLX
import MLXNN
import MLXOptimizers
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// The training of the personal adapter (see `CompletionAdapter`), on an MLX model on disk: LoRA layers on its last layers,
/// trained on the user's writing with only the user's own words counting in the loss (not the prompt around them), then
/// written as a GGUF LoRA for llama.cpp. `CompletionAdapterTraining` runs it from Settings.
enum CompletionAdapterTrainer {
    enum Progress: Sendable {
        case preparing
        case step(Int, of: Int)
    }

    struct Result: Sendable {
        var gguf: Data
        var steps: Int
        var lossBefore: Float
        var lossAfter: Float
    }

    /// One example as tokens, and from which token on the loss counts (the user's own words and the end of the turn).
    private struct Tokens: Sendable {
        var tokens: [Int]
        var answerStart: Int
    }

    /// Longer examples are cut: a suggestion never needs more prompt than this, and it keeps the memory a training takes small.
    static let maxTokens = 1_024

    /// The training itself, on an MLX model already on disk.
    /// - Parameter steps: how many steps; nil for `CompletionAdapter.steps`.
    static func train(modelDirectory directory: URL, architecture: String, examples: [CompletionAdapter.Example],
                                  steps: Int? = nil, report: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        report(.preparing)
        let container = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(directory: directory))
        let (train, validate) = CompletionAdapter.split(examples)
        let steps = steps ?? CompletionAdapter.steps(examples: train.count)
        return try await container.perform { context in
            let model = context.model
            let tokenized = train.compactMap { tokens($0, tokenizer: context.tokenizer) }
            let held = validate.compactMap { tokens($0, tokenizer: context.tokenizer) }
            guard tokenized.count >= CompletionAdapter.minimumExamples * 9 / 10, !held.isEmpty else {
                throw NookError("Too few examples to train on")
            }
            // Only the projections llama.cpp has a name for (`CompletionAdapter.projections`): a model loaded as a vision model
            // lists whole layers, with gates of its own that the GGUF adapter could not carry.
            guard let layers = (model as? LoRAModel)?.loraLayers else { throw NookError("This model takes no LoRA") }
            let names = Set(layers.last?.namedModules().map(\.0) ?? [])
            let keys = CompletionAdapter.projections.keys.filter { names.contains($0) }.sorted()
            guard !keys.isEmpty else { throw NookError("No known projections to train") }
            _ = try LoRAContainer.from(model: model, configuration: LoRAConfiguration(
                numLayers: CompletionAdapter.layers,
                loraParameters: .init(rank: CompletionAdapter.rank, scale: CompletionAdapter.scale, keys: keys)))
            let lossBefore = evaluate(model, held)
            let optimizer = Adam(learningRate: CompletionAdapter.learningRate)
            let step = valueAndGrad(model: model as Module) { module, inputs, packed in
                loss(module, inputs: inputs, packed: packed)
            }
            var order = Array(tokenized.indices).shuffled()
            var position = 0
            for index in 0..<steps {
                try Task.checkCancellation()
                if position + CompletionAdapter.batchSize > order.count { order.shuffle(); position = 0 }
                let batch = order[position..<(position + CompletionAdapter.batchSize)].map { tokenized[$0] }
                position += CompletionAdapter.batchSize
                let (inputs, packed) = arrays(batch)
                let (_, gradients) = step(model as Module, inputs, packed)
                optimizer.update(model: model as Module, gradients: gradients)
                eval(model as Module, optimizer)
                if index % 5 == 0 || index == steps - 1 { report(.step(index + 1, of: steps)) }
            }
            let lossAfter = evaluate(model, held)
            var weights: [String: (rows: Int, columns: Int, values: [Float])] = [:]
            for (key, array) in (model as Module).trainableParameters().flattened() where array.ndim == 2 {
                weights[key] = (array.dim(0), array.dim(1), array.asType(.float32).asArray(Float.self))
            }
            let gguf = try CompletionAdapter.gguf(architecture: architecture, weights: weights)
            return Result(gguf: gguf, steps: steps, lossBefore: lossBefore, lossAfter: lossAfter)
        }
    }

    /// The example in the model's own chat template: the request as the user's turn, the text as the model's answer. The
    /// loss counts from where the two templates part (the answer) to the end of the answer's turn; whitespace the template
    /// puts after that is no part of what the model should learn to write.
    private static func tokens(_ example: CompletionAdapter.Example, tokenizer: any MLXLMCommon.Tokenizer) -> Tokens? {
        let user: [String: any Sendable] = ["role": "user", "content": example.request]
        guard let prompt = try? tokenizer.applyChatTemplate(messages: [user], tools: nil, additionalContext: nil),
              var full = try? tokenizer.applyChatTemplate(messages: [user, ["role": "assistant", "content": example.text]],
                                                          tools: nil, additionalContext: nil) else { return nil }
        var shared = 0
        while shared < prompt.count, shared < full.count, prompt[shared] == full[shared] { shared += 1 }
        while let last = full.last, full.count > shared + 1,
              tokenizer.decode(tokenIds: [last], skipSpecialTokens: false).allSatisfy(\.isWhitespace) { full.removeLast() }
        guard full.count > shared, full.count <= maxTokens else { return nil }
        return Tokens(tokens: full, answerStart: shared)
    }

    /// Inputs (each example without its last token) and, packed in one array, the targets (without the first) and the mask
    /// that says which targets count: padding and the prompt do not.
    private static func arrays(_ batch: [Tokens]) -> (MLXArray, MLXArray) {
        let length = (batch.map(\.tokens.count).max() ?? 1) - 1
        var inputs = [Int32](repeating: 0, count: batch.count * length)
        var targets = inputs, mask = inputs
        for (row, example) in batch.enumerated() {
            for position in 0..<(example.tokens.count - 1) {
                inputs[row * length + position] = Int32(example.tokens[position])
                targets[row * length + position] = Int32(example.tokens[position + 1])
                mask[row * length + position] = position + 1 >= example.answerStart ? 1 : 0
            }
        }
        let shape = [batch.count, length]
        return (MLXArray(inputs, shape), stacked([MLXArray(targets, shape), MLXArray(mask, shape)]))
    }

    /// Mean cross-entropy over the tokens that count.
    private static func loss(_ module: Module, inputs: MLXArray, packed: MLXArray) -> MLXArray {
        let targets = packed[0], mask = packed[1].asType(.float32)
        let logits = (module as! any LanguageModel)(inputs, cache: nil).asType(.float32)
        let ce = crossEntropy(logits: logits, targets: targets, reduction: .none) * mask
        return ce.sum() / maximum(mask.sum(), MLXArray(Float(1)))
    }

    /// The mean loss per counted token over `examples`, without training.
    private static func evaluate(_ model: any LanguageModel, _ examples: [Tokens]) -> Float {
        var total: Float = 0, count: Float = 0
        var index = 0
        while index < examples.count {
            let batch = Array(examples[index..<min(index + CompletionAdapter.batchSize, examples.count)])
            let (inputs, packed) = arrays(batch)
            let tokens = packed[1].sum().item(Float.self)
            total += loss(model as Module, inputs: inputs, packed: packed).item(Float.self) * tokens
            count += tokens
            index += CompletionAdapter.batchSize
        }
        return count > 0 ? total / count : 0
    }
}
