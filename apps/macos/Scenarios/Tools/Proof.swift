// Writes the proof of scripts/prove-scenario.sh from the two runs' reports (docs/SCENARIOS.md):
//   swift Proof.swift <prove dir> <scenario> <base sha> <head sha> <base exit> <head exit>
// <prove dir>/base/out and <prove dir>/head/out hold each side's report.json and results. Writes proof.json and proof.md
// to <prove dir>, prints proof.json, and exits 0 (proven), 1 (ran, not proven) or 2 (could not run).
import Foundation

struct Step: Codable { var api: String; var label: String; var status: String }
struct Failure: Codable { var code: String; var message: String }
struct Result: Codable {
    var name: String
    var title: String
    var status: String
    var error: Failure?
    var steps: [Step]
    var captures: [String]
}
struct Report: Codable { var results: [Result] }

struct Side: Codable {
    var sha: String
    /// passed, failed (an expectation did not hold: the bug), or error (could not run: says nothing about the bug).
    var status: String
    var title: String
    var message: String?
    var steps: [Step]
    /// Capture paths relative to the prove folder, in the order the scenario took them.
    var captures: [String]
}

struct Proof: Codable {
    var scenario: String
    var failsOnBase: Bool
    var passesOnHead: Bool
    var baseSha: String
    var headSha: String
    var verdict: String
    var steps: [String: [Step]]
    var captures: [String]
    var markdown: String
    var base: Side
    var head: Side
}

let arguments = CommandLine.arguments
guard arguments.count >= 7 else {
    FileHandle.standardError.write(Data("usage: Proof.swift <prove dir> <scenario> <base sha> <head sha> <base exit> <head exit>\n".utf8))
    exit(2)
}
let prove = URL(fileURLWithPath: arguments[1], isDirectory: true)
let scenario = arguments[2]

func readSide(_ side: String, sha: String, exitCode: String) -> Side {
    let out = prove.appendingPathComponent(side).appendingPathComponent("out")
    guard let data = try? Data(contentsOf: out.appendingPathComponent("report.json")),
          let report = try? JSONDecoder().decode(Report.self, from: data) else {
        return Side(sha: sha, status: "error", title: "", message: "no report: the build failed or the test process did not start (exit \(exitCode))",
                    steps: [], captures: [])
    }
    // One scenario is one test: with several, a pass in one could hide a failure in another.
    let mine = report.results.filter { $0.name == scenario || $0.name.hasPrefix(scenario + "-") }
    guard mine.count == 1, let result = mine.first else {
        let message = mine.isEmpty ? "the scenario wrote no result (exit \(exitCode)): it crashed or did not build"
            : "the scenario ran \(mine.count) tests; a proof needs exactly one"
        return Side(sha: sha, status: "error", title: "", message: message, steps: [], captures: [])
    }
    let status = ["passed", "failed"].contains(result.status) ? result.status : "error"
    return Side(sha: sha, status: status, title: result.title, message: result.error.map { "\($0.code): \($0.message)" },
                steps: result.steps, captures: result.captures.map { "\(side)/out/results/\(result.name)/\($0)" })
}

let base = readSide("base", sha: arguments[3], exitCode: arguments[5])
let head = readSide("head", sha: arguments[4], exitCode: arguments[6])

func short(_ sha: String) -> String { String(sha.prefix(10)) }
let baseSha = "`\(short(base.sha))`", headSha = "`\(short(head.sha))`"
let broken: Side? = base.status == "error" ? base : head.status == "error" ? head : nil
let verdict: String
if let broken {
    let which = broken.sha == base.sha && base.status == "error" ? "base \(baseSha)" : "head \(headSha)"
    verdict = "Not proven: the scenario could not run on \(which) (\(broken.message ?? "unknown error"))."
} else if base.status == "passed" {
    verdict = head.status == "passed"
        ? "Not proven: the scenario passes on base \(baseSha) too, so it does not reproduce the bug."
        : "Not proven: the scenario passes on base \(baseSha) and fails on head \(headSha), so head breaks it."
} else {
    verdict = head.status == "passed"
        ? "Proven: the scenario fails on base \(baseSha) and passes on head \(headSha)."
        : "Not proven: the scenario fails on base \(baseSha) and still fails on head \(headSha)."
}

/// `results/Name/02-streaming.png` → `streaming`: base and head captures pair by label.
func label(_ path: String) -> String {
    var name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
    if let dash = name.firstIndex(of: "-"), name[..<dash].allSatisfy(\.isNumber) { name = String(name[name.index(after: dash)...]) }
    return name.replacingOccurrences(of: "-", with: " ")
}
var labels: [String] = []
for capture in base.captures + head.captures where !labels.contains(label(capture)) { labels.append(label(capture)) }
func cell(_ name: String, _ side: Side, _ wanted: String) -> String {
    guard let capture = side.captures.first(where: { label($0) == wanted }) else { return "" }
    return "![\(name) \(short(side.sha)): \(wanted)](\(capture))"
}
func outcome(_ side: Side) -> String {
    if side.status == "passed" { return "passed" }
    let message = (side.message ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    return (side.status == "failed" ? "failed" : "could not run") + "<br>" + message
}
let markdown = ([
    "### Scenario: \(head.title.isEmpty ? base.title : head.title)",
    "",
    "**\(verdict)**",
    "",
    "|  | Base \(baseSha) | Head \(headSha) |",
    "| --- | --- | --- |",
    "| Result | \(outcome(base)) | \(outcome(head)) |",
] + labels.map { "| \($0) | \(cell("Base", base, $0)) | \(cell("Head", head, $0)) |" } + [""]).joined(separator: "\n")

let proof = Proof(scenario: head.title.isEmpty ? base.title : head.title, failsOnBase: base.status == "failed",
                  passesOnHead: head.status == "passed", baseSha: base.sha, headSha: head.sha, verdict: verdict,
                  steps: ["base": base.steps, "head": head.steps], captures: base.captures + head.captures,
                  markdown: markdown, base: base, head: head)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let json = (try? encoder.encode(proof)) ?? Data("{}".utf8)
try? json.write(to: prove.appendingPathComponent("proof.json"))
try? markdown.write(to: prove.appendingPathComponent("proof.md"), atomically: true, encoding: .utf8)
print(String(data: json, encoding: .utf8) ?? "")
exit(proof.failsOnBase && proof.passesOnHead ? 0 : (base.status == "error" || head.status == "error") ? 2 : 1)
