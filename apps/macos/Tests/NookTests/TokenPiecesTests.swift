import XCTest

/// The flat token table finds the same tokens, with the same bytes, as one array per token did.
final class TokenPiecesTests: XCTestCase {
    private let vocabulary: [[UInt8]] = ["", "a", " ", " a", " ab", "ab", "b", "\u{e9}", " b", "abc", "", " "].map { Array($0.utf8) }

    func testBytesMatchEveryToken() {
        let table = TokenPieces(count: vocabulary.count) { vocabulary[$0] }
        XCTAssertEqual(table.count, vocabulary.count)
        for (index, piece) in vocabulary.enumerated() {
            XCTAssertEqual(Array(table[index]), piece)
            XCTAssertEqual(table.length(index), piece.count)
        }
    }

    func testCandidatesMatchTheOldSearch() {
        let table = TokenPieces(count: vocabulary.count) { vocabulary[$0] }
        for word in ["", "a", "ab", " a", " ab", " b", "b", "\u{e9}t\u{e9}", "zz"] {
            let required = Array(word.utf8)
            XCTAssertEqual(table.candidates(for: required), oldCandidates(required), word)
            guard !required.isEmpty else { continue }
            // The candidates hold every token that fits, as a search of the whole vocabulary finds them.
            let fitting = table.candidates(for: required).filter { CompletionHealing.fits(table[$0], required) }
            XCTAssertEqual(Set(fitting), Set(vocabulary.indices.filter { CompletionHealing.fits(vocabulary[$0], required) }), word)
        }
    }

    /// What `LlamaCompleter` searched before the table was flattened.
    private func oldCandidates(_ required: [UInt8]) -> [Int] {
        var first = [[Int]](repeating: [], count: 256)
        var two: [UInt16: [Int]] = [:]
        for (index, bytes) in vocabulary.enumerated() {
            if let head = bytes.first { first[Int(head)].append(index) }
            if bytes.count >= 2 { two[UInt16(bytes[0]) << 8 | UInt16(bytes[1]), default: []].append(index) }
        }
        guard required.count >= 2 else { return first[Int(required.first ?? 0)] }
        let single = first[Int(required[0])].filter { vocabulary[$0].count == 1 }
        return single + (two[UInt16(required[0]) << 8 | UInt16(required[1])] ?? [])
    }
}
