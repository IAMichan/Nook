import Foundation
import SwiftUI

/// Runs the fixed question set (`LocalEval`) against the active brain, with the quality steps as they are switched on in
/// Settings, so two models or two settings can be compared by score and time.
@MainActor
final class LocalEvalRunner: ObservableObject {
    struct Result: Identifiable {
        let id: String
        let question: String
        let answer: String
        let verdict: LocalEval.Verdict
        let seconds: Double
    }

    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var results: [Result] = []
    @Published private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: "localEvalHistory") ?? []
    @Published private(set) var failure: String?

    private var task: Task<Void, Never>?
    let total = LocalEval.cases.count

    var passed: Int { results.filter(\.verdict.passed).count }
    var totalSeconds: Double { results.reduce(0) { $0 + $1.seconds } }

    func start(brain: BrainService, settings: AppSettings) {
        guard !running else { return }
        running = true
        done = 0
        results = []
        failure = nil
        task = Task { [weak self] in
            await self?.run(brain: brain, settings: settings)
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }

    private func run(brain: BrainService, settings: AppSettings) async {
        defer { running = false }
        for item in LocalEval.cases {
            if Task.isCancelled { return }
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let answer = try await reply(to: item, brain: brain, settings: settings)
                results.append(Result(id: item.id, question: item.question, answer: answer, verdict: LocalEval.judge(answer, for: item),
                                      seconds: CFAbsoluteTimeGetCurrent() - started))
            } catch {
                failure = error.localizedDescription
                return
            }
            done += 1
        }
        remember(settings: settings)
    }

    /// One case through the same steps as a chat answer: the context, the evidence step when it is on, the answer and
    /// the check of its details against the documents.
    private func reply(to item: LocalEval.Case, brain: BrainService, settings: AppSettings) async throws -> String {
        var context = LocalEval.context(for: item)
        let small = settings.brainProfile.isSmall
        if settings.evidenceFirst, small {
            let documents = item.documents.map { "### \($0.title)\n\($0.text)" }
            let section = Evidence.section(await brain.extractEvidence(question: item.question, goal: "", documents: documents))
            if !section.isEmpty { context = context.replacingOccurrences(of: "\n\nRead in full", with: "\n\n" + section + "\n\nRead in full") }
        }
        var plan = try await brain.run(userText: item.question, context: context, tools: [])
        if settings.checkAnswers, small, plan.text.count >= 20, !Grounding.mayCompute(item.question) {
            let loose = Grounding.ungrounded(answer: plan.text, sources: context + "\n" + item.question)
            if !loose.isEmpty {
                plan = try await brain.run(userText: item.question + "\n\n(" + Grounding.correction(for: loose) + ")", context: context, tools: [])
            }
        }
        return plan.text
    }

    private func remember(settings: AppSettings) {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let mode = [settings.evidenceFirst ? "bewijs" : nil, settings.checkAnswers ? "controle" : nil].compactMap { $0 }.joined(separator: "+")
        let line = "\(formatter.string(from: Date())) · \(settings.brainLabel) · \(mode.isEmpty ? "basis" : mode) · \(passed)/\(total) · \(Int(totalSeconds)) s"
        history = Array(([line] + history).prefix(12))
        UserDefaults.standard.set(history, forKey: "localEvalHistory")
    }
}
