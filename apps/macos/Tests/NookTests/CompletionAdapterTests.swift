import XCTest

final class CompletionAdapterTests: XCTestCase {
    func testGGUFWriterWritesAHeaderTheReaderKnows() {
        var writer = CompletionGGUFWriter()
        writer.add("general.architecture", .string("gemma4"))
        writer.add("adapter.lora.alpha", .float(320))
        writer.add(.init(name: "blk.0.attn_q.weight.lora_a", rows: 2, columns: 3, values: [1, 2, 3, 4, 5, 6]))
        let data = writer.data()
        XCTAssertEqual(GGUFReader.parse(data)?.architecture, "gemma4")
        XCTAssertEqual(data.count % CompletionGGUFWriter.alignment, 0)
        // The tensor's values sit at the end, little-endian F32, after padding to the alignment.
        let tail = data.suffix(32).prefix(24)
        let values = tail.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(values, [1, 2, 3, 4, 5, 6])
        // Dimensions are written fastest-changing first: 3 columns, then 2 rows.
        let name = Data("blk.0.attn_q.weight.lora_a".utf8)
        let at = data.range(of: name)!.upperBound
        let dims = data[at..<(at + 4 + 16)].withUnsafeBytes { raw -> [UInt64] in
            (0..<2).map { raw.loadUnaligned(fromByteOffset: 4 + $0 * 8, as: UInt64.self) }
        }
        XCTAssertEqual(dims, [3, 2])
    }

    func testAdapterWeightsAreNamedAndTurnedForLlamaCpp() throws {
        XCTAssertEqual(CompletionAdapter.ggufName(forMLXKey: "language_model.model.layers.30.self_attn.q_proj.lora_a"), "blk.30.attn_q.weight.lora_a")
        XCTAssertEqual(CompletionAdapter.ggufName(forMLXKey: "model.layers.7.mlp.down_proj.lora_b"), "blk.7.ffn_down.weight.lora_b")
        XCTAssertNil(CompletionAdapter.ggufName(forMLXKey: "model.layers.7.self_attn.q_norm.weight"))
        XCTAssertEqual(CompletionAdapter.transposed([1, 2, 3, 4, 5, 6], rows: 2, columns: 3), [1, 4, 2, 5, 3, 6])
        let gguf = try CompletionAdapter.gguf(architecture: "gemma4", weights: [
            "model.layers.1.self_attn.v_proj.lora_a": (rows: 4, columns: 2, values: Array(repeating: 0.5, count: 8)),
        ])
        XCTAssertEqual(GGUFReader.parse(gguf)?.architecture, "gemma4")
        XCTAssertNotNil(gguf.range(of: Data("blk.1.attn_v.weight.lora_a".utf8)))
        XCTAssertThrowsError(try CompletionAdapter.gguf(architecture: "gemma4", weights: ["model.layers.1.norm.lora_a": (1, 1, [0])]))
    }

    func testExamplesAreTheUsersOwnMessagesWithTheConversationBefore() {
        let now = Date()
        func message(_ id: String, _ text: String, mine: Bool, ago: TimeInterval) -> InboxMessage {
            InboxMessage(id: id, text: text, date: now.addingTimeInterval(-ago), fromMe: mine)
        }
        var thread = InboxThread(id: "whatsapp|lisa", app: "whatsapp", name: "Lisa")
        thread.messages = [
            message("1", "Gaan we zaterdag naar het strand?", mine: false, ago: 300),
            message("2", "Ja leuk, ik neem de parasol mee", mine: true, ago: 200),
            message("3", "Top", mine: true, ago: 100),
            message("4", "Mijn wachtwoord: hunter22 voor de wifi", mine: true, ago: 50),
        ]
        let examples = CompletionAdapter.examples(threads: [thread], samples: [
            .init(app: "com.apple.mail", text: "Ja leuk, ik neem de parasol mee", date: now),
            .init(app: "com.apple.mail", text: "Beste Piet, de offerte komt morgen", date: now),
        ])
        XCTAssertEqual(examples.map(\.text), ["Ja leuk, ik neem de parasol mee", "Beste Piet, de offerte komt morgen"],
                       "one word, a secret and a copy are left out")
        XCTAssertTrue(examples[0].request.contains("Gaan we zaterdag naar het strand?"), "the conversation before is the screen")
        XCTAssertTrue(examples[0].request.contains("WhatsApp"))
        XCTAssertTrue(examples[0].request.hasSuffix(CompletionChat.request(context: "")), "the same task autocomplete asks")
        XCTAssertFalse(examples[1].request.contains("strand"))
    }

    func testSplitStepsAndBases() {
        let examples = (0..<20).map { CompletionAdapter.Example(request: "r", text: "t \($0)") }
        let (train, validate) = CompletionAdapter.split(examples)
        XCTAssertEqual(train.count, 18)
        XCTAssertEqual(validate.count, 2)
        XCTAssertEqual(CompletionAdapter.steps(examples: 40), 100)
        XCTAssertEqual(CompletionAdapter.steps(examples: 2_000), 500)
        XCTAssertEqual(CompletionAdapter.steps(examples: 9_000), 800)
        XCTAssertEqual(CompletionAdapterBase.base(forModelFile: "gemma-4-E4B-it.i1-Q4_K_M.gguf")?.repository, "mlx-community/gemma-4-e4b-it-4bit")
        XCTAssertEqual(CompletionAdapterBase.base(forModelFile: "gemma-4-E2B-it-Q8_0.gguf")?.repository, "mlx-community/gemma-4-e2b-it-4bit")
        XCTAssertNil(CompletionAdapterBase.base(forModelFile: "gemma-4-E4B-Q5_K_M.gguf"), "a base model is not trained")
        XCTAssertNil(CompletionAdapterBase.base(forModelFile: "Qwen3-4B-Instruct.gguf"))
    }

    func testAnAdapterOnlyFitsTheFileItWasTrainedFor() {
        let info = CompletionAdapterInfo(modelFile: "m.gguf", modelSize: 10, repository: "r", date: Date(), examples: 200, steps: 100,
                                         lossBefore: 4, lossAfter: 3)
        XCTAssertTrue(info.fits(file: URL(fileURLWithPath: "/a/m.gguf"), size: 10))
        XCTAssertFalse(info.fits(file: URL(fileURLWithPath: "/a/m.gguf"), size: 11))
        XCTAssertFalse(info.fits(file: URL(fileURLWithPath: "/a/n.gguf"), size: 10))
        XCTAssertEqual(info.improvement, 0.25, accuracy: 0.001)
    }
}
