import Foundation

/// Keeps a request's credentials on a redirect within the same host. URLSession drops `Authorization` on every redirect,
/// and GitHub answers a renamed repository's old name with one (`/repos/owner/old` → `/repositories/<id>`): the redirected
/// request then went out anonymous, which reads as 404 on a private repository or the per-IP rate limit, so the pull
/// request of a branch was never found.
final class RedirectCredentials: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectCredentials()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.follow(task.originalRequest, to: request))
    }

    /// Every answer passes here, also those of `data(for:)`, whose completion never reaches the session's delegate: the
    /// place where `ForgeRateBudget` learns how much of each forge's limit is left. An answer `ForgeRateGate` gave
    /// itself has no transaction and so changes nothing.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let response = metrics.transactionMetrics.last(where: { $0.response != nil })?.response as? HTTPURLResponse else { return }
        ForgeRateBudget.shared.record(response)
    }

    /// The redirected request, with the original `Authorization` when it stays on the same scheme, host and port.
    static func follow(_ original: URLRequest?, to request: URLRequest) -> URLRequest {
        guard let original, let auth = original.value(forHTTPHeaderField: "Authorization"),
              request.value(forHTTPHeaderField: "Authorization") == nil,
              let from = original.url, let to = request.url, from.scheme?.lowercased() == to.scheme?.lowercased(),
              let host = from.host?.lowercased(), host == to.host?.lowercased(), from.port == to.port else { return request }
        var kept = request
        kept.setValue(auth, forHTTPHeaderField: "Authorization")
        return kept
    }
}
