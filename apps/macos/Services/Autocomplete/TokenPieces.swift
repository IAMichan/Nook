import Foundation

/// Every token's bytes in one flat buffer, with the tokens indexed by the first bytes of their piece, for spelling a word
/// the model did not see coming from the whole vocabulary (see `LlamaCompleter.healed`).
///
/// One array per token cost about 50 bytes of heap each for a few bytes of text: 13 MB for Gemma's 262 000 tokens. Here the
/// bytes sit back to back and `offsets` marks where each token starts.
struct TokenPieces {
    private let bytes: [UInt8]
    /// Where token `i` starts in `bytes`; `offsets[i + 1]` is where it ends.
    private let offsets: [Int32]
    /// The tokens by the first byte of their piece.
    private let byFirstByte: [[Int32]]
    /// The tokens of two or more bytes by their first two bytes: half of a vocabulary starts with a space.
    private let byFirstTwoBytes: [UInt16: [Int32]]

    /// - Parameter piece: the bytes of token `index`.
    init(count: Int, piece: (Int) -> [UInt8]) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count * 6)
        var offsets: [Int32] = []
        offsets.reserveCapacity(count + 1)
        var first = [[Int32]](repeating: [], count: 256)
        var two: [UInt16: [Int32]] = [:]
        for index in 0..<count {
            offsets.append(Int32(bytes.count))
            let token = piece(index)
            bytes.append(contentsOf: token)
            guard let head = token.first else { continue }
            first[Int(head)].append(Int32(index))
            if token.count >= 2 { two[UInt16(head) << 8 | UInt16(token[1]), default: []].append(Int32(index)) }
        }
        offsets.append(Int32(bytes.count))
        self.bytes = bytes
        self.offsets = offsets
        byFirstByte = first
        byFirstTwoBytes = two
    }

    var count: Int { offsets.count - 1 }

    /// The bytes of token `index`.
    subscript(index: Int) -> ArraySlice<UInt8> { bytes[Int(offsets[index])..<Int(offsets[index + 1])] }

    func length(_ index: Int) -> Int { Int(offsets[index + 1] - offsets[index]) }

    /// The tokens that could fit `required` (see `CompletionHealing.fits`), a superset to test, in vocabulary order per group.
    func candidates(for required: [UInt8]) -> [Int] {
        guard required.count >= 2 else { return byFirstByte[Int(required.first ?? 0)].map(Int.init) }
        // A one-byte piece fits when it is the word's first byte; longer ones need the first two bytes to match.
        let single = byFirstByte[Int(required[0])].lazy.map(Int.init).filter { length($0) == 1 }
        return Array(single) + (byFirstTwoBytes[UInt16(required[0]) << 8 | UInt16(required[1])] ?? []).map(Int.init)
    }
}
