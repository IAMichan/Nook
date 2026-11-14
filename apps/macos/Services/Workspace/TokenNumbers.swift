import Foundation

/// A number in an agent's JSON, read the same way everywhere: a JSON number (a JSON boolean is no number), or a string
/// that holds one. Infinite and NaN values count as missing.
enum JSONNumber {
    static func double(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            // JSON booleans are also NSNumber; they do not count as numbers (0 or 1 do).
            #if canImport(Darwin)
            result = CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
            #else
            // swift-corelibs-foundation (the tests on Linux): a JSON boolean is an NSNumber of type "c".
            result = String(cString: number.objCType) == "c" ? nil : number.doubleValue
            #endif
        } else if let text = value as? String {
            result = Double(text.trimmingCharacters(in: .whitespaces))
        } else {
            result = nil
        }
        return result?.isFinite == true ? result : nil
    }

    /// A whole number (a fraction is cut off), nil when `value` is not a number.
    static func int(_ value: Any?) -> Int? {
        guard let value = double(value), abs(value) < Double(Int.max) else { return nil }
        return Int(value)
    }
}

/// The tokens of one call or turn, with cached input kept apart from the rest of the input as every agent's ledger
/// keeps it. Codex and Gemini CLI count the cached part inside their input; these take it out, the same way live
/// (stream, app server) and in the history read from disk.
enum TokenUsageSplit {
    /// Codex: `input_tokens` / `inputTokens` include `cached_input_tokens` / `cachedInputTokens`.
    static func codex(_ raw: [String: Any]) -> TokenCounts {
        func value(_ keys: String...) -> Int { keys.lazy.compactMap { JSONNumber.int(raw[$0]) }.first ?? 0 }
        let cached = value("cached_input_tokens", "cachedInputTokens")
        let input = value("input_tokens", "inputTokens")
        return TokenCounts(input: max(0, input - cached), output: value("output_tokens", "outputTokens"),
                           cacheRead: cached, cacheWrite: value("cache_write_input_tokens", "cacheWriteInputTokens"))
    }

    /// Gemini CLI: a chat file's `tokens` (`input` with the cached part, `output`, `cached`, `thoughts`) or the stats of
    /// its stream-json result (`input_tokens` with the cached part, `input` without it, `output_tokens`, `cached`). Its
    /// thoughts count as output in both, as they are billed.
    static func gemini(_ raw: [String: Any]) -> TokenCounts {
        func value(_ key: String) -> Int? { JSONNumber.int(raw[key]) }
        let cached = value("cached") ?? 0
        let input: Int
        if let all = value("input_tokens") {
            input = value("input") ?? max(0, all - cached)
        } else {
            input = max(0, (value("input") ?? value("prompt") ?? 0) - cached)
        }
        let output = (value("output_tokens") ?? value("output") ?? value("candidates") ?? 0)
            + (value("thoughts") ?? value("thoughts_tokens") ?? 0)
        return TokenCounts(input: input, output: output, cacheRead: cached)
    }
}
