import Foundation

/// Dictating into a composer: the microphone listens, the words you speak land after what the box held when it started,
/// and the box is read-only until they have landed. Send while the microphone listens finishes the recording and sends
/// once the words are in; discarding puts the box back as it was and drops that send. The view holds one of these and
/// talks to the speech service; this only keeps the rules, so they can be tested without a microphone.
struct ComposerDictation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// The microphone listens; what it heard so far shows in the box.
        case listening
        /// The recording stopped and the last words are on their way.
        case finishing
    }

    private(set) var phase: Phase = .idle
    /// The words in the box when the recording started; spoken words go after them.
    private(set) var base = ""
    /// Send was pressed while dictating: the message goes once the words have landed.
    private(set) var sendsWhenDone = false

    /// The box is the microphone's: typing waits, and Send means "finish, then send".
    var isActive: Bool { phase != .idle }

    /// Starts a recording on top of `body`. False when one is already running.
    @discardableResult
    mutating func begin(body: String) -> Bool {
        guard phase == .idle else { return false }
        phase = .listening
        base = body
        sendsWhenDone = false
        return true
    }

    /// What the box shows with `spoken` heard so far.
    func text(with spoken: String) -> String {
        Self.join(base, spoken)
    }

    /// Stop listening and keep the words. True when the microphone still has to be stopped (it was listening).
    @discardableResult
    mutating func finish() -> Bool {
        guard phase == .listening else { return false }
        phase = .finishing
        return true
    }

    /// Send pressed while dictating: finish, and send once the words have landed. True when the microphone still has to
    /// be stopped. Without a recording nothing changes and the caller sends as usual.
    @discardableResult
    mutating func requestSend() -> Bool {
        guard isActive else { return false }
        sendsWhenDone = true
        return finish()
    }

    /// The recording delivered its last words: the box's new text, and whether the message goes now.
    mutating func land(_ spoken: String) -> (text: String, send: Bool) {
        let result = (text(with: spoken), sendsWhenDone && phase != .idle)
        reset()
        return result
    }

    /// Throws the recording away: the box goes back to what it held before, and a waiting send is dropped. Nil when
    /// nothing was recording.
    mutating func discard() -> String? {
        guard isActive else { return nil }
        let before = base
        reset()
        return before
    }

    private mutating func reset() {
        phase = .idle
        base = ""
        sendsWhenDone = false
    }

    /// Spoken words after the typed ones, with one space between them when the typed words do not end in one.
    static func join(_ base: String, _ spoken: String) -> String {
        let clean = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return base }
        if base.isEmpty { return clean }
        return base + (base.last?.isWhitespace == true ? "" : " ") + clean
    }
}
