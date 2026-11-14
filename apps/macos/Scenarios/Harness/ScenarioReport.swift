import Foundation

/// The run's report, in the shape scripts/prove-scenario.sh reads: `report.json` and `summary.md` in the output folder,
/// and per scenario `results/<name>/result.json` with its captures beside it.
enum ScenarioReport {
    enum Status: String, Codable {
        /// Every expectation held.
        case passed
        /// An expectation did not hold: the behavior under test is broken.
        case failed
        /// The scenario could not run (setup, a missing element, a guard): it says nothing about the behavior.
        case error
    }

    struct Step: Codable {
        var api: String
        var label: String
        var status: String
    }

    struct Failure: Codable {
        var code: String
        var message: String
    }

    struct Result: Codable {
        var name: String
        var title: String
        var status: Status
        var error: Failure?
        var steps: [Step]
        /// File names in the scenario's result folder, in the order they were taken.
        var captures: [String]
        var notes: [String]
        var durationSeconds: Double
    }

    struct Run: Codable {
        var generatedAt: Date
        var results: [Result]
    }

    /// Writes the scenario's result, then the run's report from every result in the output folder.
    static func write(_ result: Result, in directory: URL?) {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(result) { try? data.write(to: directory.appendingPathComponent("result.json")) }

        let output = directory.deletingLastPathComponent().deletingLastPathComponent()
        let resultsFolder = output.appendingPathComponent("results", isDirectory: true)
        let decoder = JSONDecoder()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: resultsFolder.path)) ?? []).sorted()
        let results = names.compactMap { name -> Result? in
            guard let data = try? Data(contentsOf: resultsFolder.appendingPathComponent(name).appendingPathComponent("result.json"))
            else { return nil }
            return try? decoder.decode(Result.self, from: data)
        }
        if let data = try? encoder.encode(Run(generatedAt: Date(), results: results)) {
            try? data.write(to: output.appendingPathComponent("report.json"))
        }
        try? summary(results).write(to: output.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    static func summary(_ results: [Result]) -> String {
        var lines = ["# Scenarios", ""]
        let passed = results.count(where: { $0.status == .passed })
        let failed = results.count(where: { $0.status == .failed })
        let errors = results.count(where: { $0.status == .error })
        lines.append("\(passed) passed, \(failed) failed, \(errors) could not run.")
        lines.append("")
        for result in results {
            let mark = result.status == .passed ? "passed" : result.status == .failed ? "FAILED" : "COULD NOT RUN"
            lines.append("## \(result.name): \(mark)")
            lines.append("")
            lines.append(result.title)
            lines.append("")
            if let error = result.error { lines += ["`\(error.code)`: \(error.message)", ""] }
            for step in result.steps { lines.append("- [\(step.status)] \(step.api) \(step.label)") }
            if !result.captures.isEmpty {
                lines.append("")
                for capture in result.captures { lines.append("![\(capture)](results/\(result.name)/\(capture))") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
