import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Picks from a model's logits, over the whole vocabulary (often 150 000+ tokens) for every token written. With Accelerate, so
/// it stays fast in a debug build too: there, plain Swift loops over the vocabulary cost tens of milliseconds per token.
struct CompletionSampler {
    let vocabularySize: Int
    private var scratch: [Float]
    private var mask: [Float]
    /// 0, 1, 2 … as floats, to pick indices out with a mask (exact up to 2^24).
    private var ramp: [Float]

    init(vocabularySize: Int) {
        self.vocabularySize = vocabularySize
        scratch = [Float](repeating: 0, count: vocabularySize)
        mask = [Float](repeating: 0, count: vocabularySize)
        ramp = (0..<vocabularySize).map(Float.init)
    }

    /// The highest logit and its index (the first one when several are equal), and the softmax's denominator relative to it:
    /// the sum of exp(logit − highest) over all logits.
    mutating func maximum(_ logits: UnsafePointer<Float>) -> (index: Int, value: Float, sum: Float) {
        guard vocabularySize > 0 else { return (0, 0, 1) }
        #if canImport(Accelerate)
        let count = vDSP_Length(vocabularySize)
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(logits, 1, &value, &index, count)
        var shift = -value
        var sum: Float = 0
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsadd(logits, 1, &shift, base, 1, count)
            var length = Int32(vocabularySize)
            vvexpf(base, base, &length)
            vDSP_sve(base, 1, &sum, count)
        }
        return (Int(index), value, sum)
        #else
        var index = 0
        for position in 1..<vocabularySize where logits[position] > logits[index] { index = position }
        let value = logits[index]
        var sum: Float = 0
        for position in 0..<vocabularySize { sum += exp(logits[position] - value) }
        return (index, value, sum)
        #endif
    }

    /// The indices of the `k` highest logits, highest first, without sorting the whole vocabulary: only the logits within a
    /// margin of the highest are looked at, the margin widened until there are `k`.
    mutating func top(_ logits: UnsafePointer<Float>, k: Int) -> [Int] {
        guard k > 0, vocabularySize > 0 else { return [] }
        #if canImport(Accelerate)
        let count = vDSP_Length(vocabularySize)
        var highest: Float = 0
        vDSP_maxv(logits, 1, &highest, count)
        var margin: Float = 8
        while true {
            var threshold = highest - margin
            var two: Float = 2
            var found = 0
            mask.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                // ±2 by the threshold, then 4 or 0: a mask for the compress below, and twice the count as its sum.
                vDSP_vlim(logits, 1, &threshold, &two, base, 1, count)
                vDSP_vsadd(base, 1, &two, base, 1, count)
                var total: Float = 0
                vDSP_sve(base, 1, &total, count)
                found = Int((total / 4).rounded())
            }
            if found >= k || margin >= 128 || found == vocabularySize {
                var indices = [Float](repeating: 0, count: found)
                var values = [Float](repeating: 0, count: found)
                // The length is the input's: the output gets one value per nonzero mask entry, `found` in all.
                vDSP_vcmprs(ramp, 1, mask, 1, &indices, 1, count)
                vDSP_vcmprs(logits, 1, mask, 1, &values, 1, count)
                let ranked = zip(indices, values).sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                return ranked.prefix(k).map { Int($0.0) }
            }
            margin *= 2
        }
        #else
        return (0..<vocabularySize).sorted { logits[$0] != logits[$1] ? logits[$0] > logits[$1] : $0 < $1 }.prefix(k).map { $0 }
        #endif
    }
}
