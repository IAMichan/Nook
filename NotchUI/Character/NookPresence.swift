import Foundation

/// Moments Nook reacts to: a click, the pointer arriving, typing, a celebration. Shared by every orb on screen, so
/// an orb that is replaced mid-animation (the panel opens) carries on where the previous one was.
///
/// Only `drowsy` is published: it changes rarely and must redraw an orb that is not animating. Everything else is
/// read per frame by orbs that are already awake, so it does not need to trigger updates.
@MainActor
final class NookPresence: ObservableObject {
    static let shared = NookPresence()

    /// After this long without anything happening, Nook dozes off.
    static let drowsyAfter: TimeInterval = 600
    /// Nook says hello at most once in this period; more often gets tiresome.
    static let greetingGap: TimeInterval = 180

    @Published private(set) var drowsy = false

    private(set) var pokedAt: Date = .distantPast
    private(set) var greetedAt: Date = .distantPast
    private(set) var wokeAt: Date = .distantPast
    private(set) var typedAt: Date = .distantPast
    private(set) var typedCount = 0
    private(set) var celebratedAt: Date = .distantPast
    private(set) var heardAt: Date = .distantPast
    private(set) var noddedAt: Date = .distantPast
    private(set) var giggledAt: Date = .distantPast
    private var pokes: [Date] = []

    /// Where something Nook should look at sits, as an angle around him (0 = right, clockwise, y pointing down): a piece of
    /// the task ring under the pointer. Nil when there is nothing to look at.
    var lookAngle: Double?

    private var lastActivity = Date()
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDrowsy() }
        }
    }

    /// The orb was clicked: it squishes and springs back. Three quick clicks tickle: it giggles.
    func poke() {
        let now = Date()
        pokedAt = now
        pokes = pokes.filter { now.timeIntervalSince($0) < 1 } + [now]
        if pokes.count >= 3 {
            giggledAt = now
            pokes = []
        }
        noteActivity()
    }

    /// You sent Nook something: a small hop with wide eyes, as in "got it".
    func heard() {
        heardAt = Date()
        noteActivity()
    }

    /// Something Nook or an agent worked on is finished: a short, content nod.
    func nod() {
        noddedAt = Date()
        noteActivity()
    }

    /// The pointer arrived at the notch: wakes Nook with a start, or says hello now and then.
    func pointerEntered() {
        let now = Date()
        if drowsy || now.timeIntervalSince(lastActivity) > Self.drowsyAfter {
            wokeAt = now
        } else if now.timeIntervalSince(greetedAt) > Self.greetingGap {
            greetedAt = now
        }
        noteActivity()
    }

    /// Text is being typed somewhere in Nook: it reads along.
    func typed(count: Int) {
        typedAt = Date()
        typedCount = count
        noteActivity()
    }

    /// Something bigger finished (a whole plan, the last agent): a small burst of sparks. Use sparingly.
    func celebrate() {
        celebratedAt = Date()
        noteActivity()
    }

    func noteActivity() {
        lastActivity = Date()
        if drowsy { drowsy = false }
    }

    private func checkDrowsy() {
        let sleepy = Date().timeIntervalSince(lastActivity) > Self.drowsyAfter
        if sleepy != drowsy { drowsy = sleepy }
    }
}
