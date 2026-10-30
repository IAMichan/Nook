import Foundation

/// GitHub's own rate-limit answer ("API rate limit exceeded for 1.2.3.4. (But here's the good news…") as a sentence in
/// your language, with the time it lifts. A limit on an address rather than an account means the token never arrived.
enum GitHubRateLimit {
    static func message(_ response: HTTPURLResponse?, _ text: String?) -> String? {
        guard let response, [403, 429].contains(response.statusCode),
              let text, text.localizedCaseInsensitiveContains("rate limit") else { return nil }
        let reset = (response.value(forHTTPHeaderField: "X-RateLimit-Reset")).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(TimeInterval(response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 3600))
        let until = DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)
        return tr(isAnonymous(text) ? "github.error.rateLimitAnonymous" : "github.error.rateLimit", until)
    }

    /// "…exceeded for 86.95.248.97." (signed out) against "…exceeded for user ID 123." (with a token).
    static func isAnonymous(_ text: String) -> Bool {
        guard let range = text.range(of: "exceeded for ") else { return false }
        return !text[range.upperBound...].hasPrefix("user")
    }
}
