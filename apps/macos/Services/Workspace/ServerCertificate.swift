import CryptoKit
import Foundation
import Security

/// The certificate a server showed, as the browser's certificate question names it: who it was issued to and its
/// SHA-256 fingerprint (what an approval in `CertificateTrustStore` is kept by).
struct ServerCertificate: Equatable {
    /// The subject, as macOS summarizes it ("localhost", "mkcert development certificate"), made safe to show: the server
    /// chose it, so it gets one line of at most 120 characters.
    let subject: String
    /// SHA-256 of the leaf certificate's DER bytes, lowercase hex.
    let fingerprint: String

    init?(_ trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        let flat = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        subject = flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }

    /// The first bytes of the fingerprint as "ab:cd:ef:…", enough to compare with what the server's tool printed.
    var shortFingerprint: String {
        let pairs = stride(from: 0, to: min(fingerprint.count, 16), by: 2).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            return String(fingerprint[start..<fingerprint.index(start, offsetBy: 2)])
        }
        return pairs.joined(separator: ":") + "…"
    }
}

/// A local server whose certificate macOS does not trust, waiting for you in the browser (`BrowserView`).
struct CertificateQuestion: Equatable {
    let approval: CertificateApproval
    let certificate: ServerCertificate
    /// The page to load again once you trust it.
    var pageURL: URL?

    /// "localhost:5173", or the host alone on 443.
    var hostLabel: String {
        let host = approval.host.contains(":") ? "[\(approval.host)]" : approval.host
        return approval.port == 443 ? host : "\(host):\(approval.port)"
    }
}
