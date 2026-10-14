import Foundation
import AppKit

/// Praat met Ollama (ollama.com), dat gratis modellen op je eigen Mac draait.
/// Alles blijft lokaal: er gaat niets naar het internet behalve het downloaden van het model zelf.
enum LocalModelService {
    // Een IP-adres in plaats van "localhost": dan blijft App Transport Security er buiten.
    static let base = URL(string: "http://127.0.0.1:11434")!
    static let downloadPage = URL(string: "https://ollama.com/download")!

    struct Suggestion: Identifiable {
        let id: String        // modelnaam bij Ollama
        let title: String
        let detail: String
    }

    /// Modellen die tools kunnen aanroepen, zoals Nook nodig heeft.
    static let suggestions: [Suggestion] = [
        Suggestion(id: "qwen2.5:7b", title: "Qwen 2.5 (7B)", detail: "Aanbevolen · ± 4,7 GB · goed in Nederlands, 16 GB geheugen of meer"),
        Suggestion(id: "llama3.1:8b", title: "Llama 3.1 (8B)", detail: "± 4,9 GB · degelijk allrounder, 16 GB geheugen of meer"),
        Suggestion(id: "llama3.2:3b", title: "Llama 3.2 (3B)", detail: "Licht · ± 2 GB · sneller, minder slim, past op 8 GB geheugen")
    ]

    static func isRunning() async -> Bool {
        (try? await installedModels()) != nil
    }

    static func installedModels() async throws -> [String] {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let models = (object?["models"] as? [[String: Any]]) ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    /// Downloadt een model. `progress` krijgt een tekst en een fractie (0…1, of nil als onbekend).
    static func pull(_ model: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NookError("Ollama kon \(model) niet downloaden (status \(http.statusCode)). Klopt de naam?")
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let error = object["error"] as? String { throw NookError("Downloaden mislukte: \(error)") }
            let status = (object["status"] as? String) ?? ""
            var fraction: Double?
            if let total = object["total"] as? Double, total > 0, let done = object["completed"] as? Double {
                fraction = min(1, done / total)
            }
            progress(status, fraction)
        }
    }

    /// Eén chatverzoek (zonder streaming). Eerste keer laden van een model kan even duren.
    static func chat(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw NookError("Ollama draait niet. Open de Ollama-app (of voer `ollama serve` uit) en probeer het opnieuw.")
            case .timedOut:
                throw NookError("Het lokale model reageerde niet op tijd. Een groot model op een trage Mac kan dit doen; kies een lichter model.")
            default:
                throw NookError("Netwerkfout naar Ollama: \(error.localizedDescription)")
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (object["error"] as? String) ?? "Status \(status)"
            if status == 404 {
                throw NookError("Dit model is niet geïnstalleerd. Installeer het bij Instellingen › Brein.")
            }
            if message.localizedCaseInsensitiveContains("does not support tools") {
                throw NookError("Dit model kan Nooks tools niet gebruiken. Kies een model uit de lijst, zoals qwen2.5:7b.")
            }
            throw NookError("Het lokale model gaf een fout: \(message)")
        }
        return object
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config)
    }()
}
