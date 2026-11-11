import Foundation

/// A personal adapter: a small LoRA trained on this Mac from what the user wrote, so the autocomplete model writes more like
/// them. Each user trains their own from their own writing; nothing leaves the Mac and nobody else's writing goes in. The
/// training runs with MLX on the MLX build of the same model (`CompletionAdapterBase`); the result goes to a GGUF LoRA that
/// llama.cpp puts on top of the GGUF model (`CompletionAdapterTraining`), sealed on disk (`CompletionAdapterStore`).
///
/// This part is Foundation-only: which writing becomes an example, which model can be trained, and how the trained weights
/// are named in the GGUF file.
enum CompletionAdapter {
    /// One thing the user wrote and what was on screen when they wrote it, in the layout autocomplete reads it in: `request`
    /// is the user's turn of the chat prompt (`CompletionChat.request`), `text` the answer the model should learn to write.
    struct Example: Equatable, Sendable {
        var request: String
        var text: String
    }

    /// Fewer examples than this teach too little to be worth the training time, and risk learning a few messages by heart.
    static let minimumExamples = 150
    /// Messages longer than this are mostly mails with quotes and signatures: a suggestion is a sentence or two.
    static let maxTextLength = 600
    /// Messages before the user's own one that stand in for the screen around the field.
    static let contextMessages = 8
    /// Older messages than this before the user's own one belong to another conversation.
    static let contextWindow: TimeInterval = 12 * 3600

    /// Every tenth example is kept apart to measure the training on writing it did not learn from.
    static func split(_ examples: [Example]) -> (train: [Example], validate: [Example]) {
        var train: [Example] = [], validate: [Example] = []
        for (index, example) in examples.enumerated() {
            if index % 10 == 9 { validate.append(example) } else { train.append(example) }
        }
        return (train, validate)
    }

    /// Training steps (of `batchSize` examples) for this many examples: about one pass over them, within bounds that keep a
    /// training under an hour on an M-series Mac.
    static func steps(examples: Int) -> Int { min(800, max(100, examples / batchSize)) }

    static let batchSize = 4
    /// LoRA rank and scale, and how many of the last layers get one: as the experiment on 2026-11-11 (4 085 messages) used.
    static let rank = 16
    static let scale: Float = 20
    static let layers = 16
    static let learningRate: Float = 1e-4

    /// The GGUF tensor that an MLX adapter weight belongs to: "…layers.30.self_attn.q_proj.lora_a" is the low-rank A of
    /// "blk.30.attn_q.weight". Nil for a weight that is not part of a known projection.
    static func ggufName(forMLXKey key: String) -> String? {
        guard let match = key.firstMatch(of: #/layers\.(\d+)\.(.+)\.lora_([ab])$/#), let module = projections[String(match.2)] else { return nil }
        return "blk.\(match.1).\(module).weight.lora_\(match.3)"
    }

    /// MLX's module names (Hugging Face's) and llama.cpp's for the same projection.
    static let projections: [String: String] = [
        "self_attn.q_proj": "attn_q", "self_attn.k_proj": "attn_k", "self_attn.v_proj": "attn_v", "self_attn.o_proj": "attn_output",
        "q_proj": "attn_q", "k_proj": "attn_k", "v_proj": "attn_v", "o_proj": "attn_output",
        "mlp.gate_proj": "ffn_gate", "mlp.up_proj": "ffn_up", "mlp.down_proj": "ffn_down",
    ]

    /// The adapter as a GGUF file llama.cpp loads: the weights of MLX's LoRA layers (y = Wx + scale · (x A) B, with A of
    /// in × rank and B of rank × out) transposed to llama.cpp's (A of rank × in, B of out × rank), and alpha = scale · rank,
    /// since llama.cpp scales by alpha / rank.
    /// - Parameter weights: MLX key → (rows, columns, values row after row).
    static func gguf(architecture: String, weights: [String: (rows: Int, columns: Int, values: [Float])]) throws -> Data {
        var writer = CompletionGGUFWriter()
        writer.add("general.architecture", .string(architecture))
        writer.add("general.type", .string("adapter"))
        writer.add("adapter.type", .string("lora"))
        writer.add("adapter.lora.alpha", .float(scale * Float(rank)))
        for key in weights.keys.sorted() {
            guard let name = ggufName(forMLXKey: key), let weight = weights[key] else { throw NookError("Unknown adapter weight \(key)") }
            writer.add(.init(name: name, rows: weight.columns, columns: weight.rows,
                             values: transposed(weight.values, rows: weight.rows, columns: weight.columns)))
        }
        return writer.data()
    }

    static func transposed(_ values: [Float], rows: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: values.count)
        for row in 0..<rows {
            for column in 0..<columns { out[column * rows + row] = values[row * columns + column] }
        }
        return out
    }
}

/// Which MLX model to train an adapter on, for the GGUF model autocomplete runs: the same model, so the adapter fits it.
/// Only models whose MLX build is known: for any other GGUF model there is no personal adapter.
enum CompletionAdapterBase {
    struct Base: Equatable {
        /// The MLX model on Hugging Face.
        var repository: String
        /// llama.cpp's name for the architecture (`general.architecture`).
        var architecture: String
    }

    static func base(forModelFile name: String) -> Base? {
        let lower = name.lowercased()
        // Instruct models only: autocomplete prefers them (see `CompletionChat`), and the adapter learns in their chat layout.
        guard lower.contains("-it") else { return nil }
        if lower.contains("gemma-4-e4b") { return Base(repository: "mlx-community/gemma-4-e4b-it-4bit", architecture: "gemma4") }
        if lower.contains("gemma-4-e2b") { return Base(repository: "mlx-community/gemma-4-e2b-it-4bit", architecture: "gemma4") }
        return nil
    }

    /// Enough memory to train next to everything else: the model, its gradients and the running autocomplete model.
    static let minimumMemory: UInt64 = 24 << 30
}

/// What is known about the trained adapter, kept next to it (plain: it holds no writing).
struct CompletionAdapterInfo: Codable, Equatable {
    /// The GGUF model it was trained for, by file name and size: another model (or another download of it) does not take it.
    var modelFile: String
    var modelSize: Int64
    var repository: String
    var date: Date
    var examples: Int
    var steps: Int
    /// The loss on the examples kept apart, before and after: the adapter is only kept when the second is lower.
    var lossBefore: Float
    var lossAfter: Float

    func fits(file: URL, size: Int64) -> Bool { file.lastPathComponent == modelFile && size == modelSize }

    /// How much better it predicts the user's own writing it did not learn from: 0.25 is a quarter less surprise per token.
    var improvement: Float { lossBefore > 0 ? max(0, (lossBefore - lossAfter) / lossBefore) : 0 }
}
