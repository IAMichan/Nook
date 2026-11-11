import Foundation

extension CompletionAdapter {
    /// The examples from the user's writing: their own messages in the chats Nook reads, with the conversation before each
    /// one as the screen text, and the texts autocomplete recorded (`CompletionSamples`). Secrets are taken out (a message
    /// that holds one is left out whole), as are messages of one word, media without a caption and notices.
    static func examples(threads: [InboxThread], samples: [CompletionSamples.Sample], builder: PromptBuilder = PromptBuilder()) -> [Example] {
        var result: [Example] = []
        var seen = Set<String>()
        func add(_ text: String, screen: String?, app: String?) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.split(whereSeparator: \.isWhitespace).count >= 2, clean.count <= maxTextLength,
                  CompletionPrivacy.sanitize(clean) == clean, seen.insert(clean).inserted else { return }
            var input = CompletionContext(before: "")
            input.appName = app
            input.screenText = screen.map { CompletionPrivacy.sanitize($0) }
            result.append(Example(request: CompletionChat.request(context: builder.build(input).context), text: clean))
        }
        for thread in threads {
            let messages = thread.messages.filter { !$0.isNotice && !$0.isDeleted && !$0.text.isEmpty }.sorted { $0.date < $1.date }
            let app = MessagingApps.builtIn.first { $0.id == thread.app }?.name
            for (index, message) in messages.enumerated() where message.isMine {
                let earlier = messages[max(0, index - contextMessages)..<index]
                    .filter { message.date.timeIntervalSince($0.date) < contextWindow }
                    .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
                add(message.text, screen: earlier.isEmpty ? nil : earlier.joined(separator: "\n"), app: app)
            }
        }
        for sample in samples { add(sample.text, screen: nil, app: nil) }
        return result
    }
}
