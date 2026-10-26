import Foundation

// "Why can't I connect?" (docs/COMPANION.md, "When it does not connect"). The phone checks every route to the Mac once
// more, in detail, and this model turns what each check ran into (plus the last error of the live connection) into one
// headline, the state of each hop on the way (this device, the local network, the tailnet, the relay, Nook on the Mac)
// and what to do about it. The Mac uses the same model for *Test relay* in Settings › Devices.
//
// The model is pure and returns codes, not text: each app words them in its own language.

enum CompanionDiagnosis {
    /// What one check of one route ran into.
    enum RouteOutcome: Equatable, Sendable {
        /// The Mac answered, in this many milliseconds.
        case answered(milliseconds: Int)
        /// The Mac answered, but refused the request (a clock too far off, too many requests).
        case refused(CompanionError)
        /// Something answered that does not hold this pairing's key: another machine at that address, or another pairing.
        case wrongKey
        /// The connection opened and was closed without an answer: the Mac does not know this pairing (any more).
        case closedWithoutAnswer
        /// The relay closed the connection with this code (`relayMacOffline`, `relayRoomFull`, or another).
        case closed(code: Int)
        /// Nothing could be reached at that address (no route, refused, no such name, a relay that cannot be reached).
        case unreachable
        /// The connection opened, but no answer came in time.
        case timedOut
        /// Not checked.
        case unchecked
    }

    /// The close codes the relay uses (apps/relay/worker/room.js).
    static let relayMacOffline = 4404
    static let relayRoomFull = 4429

    struct Probe: Equatable, Sendable {
        var route: CompanionRoute
        var outcome: RouteOutcome
    }

    struct Input: Equatable, Sendable {
        /// Whether this device has a network at all.
        var online: Bool
        var probes: [Probe]
        var compatibility: CompanionCompatibility = .ok
        /// What the live connection last ran into: a refusal, and the relay's close code.
        var lastError: CompanionError?
        var lastCloseCode: Int?
    }

    /// The places on the way from this device to Nook on the Mac.
    enum Hop: String, Equatable, Sendable, CaseIterable {
        case device, localNetwork, tailnet, relay, mac
    }

    enum HopResult: String, Equatable, Sendable {
        case ok, failed, unchecked
    }

    struct HopState: Equatable, Sendable {
        var hop: Hop
        var result: HopResult
    }

    /// What went wrong, as the headline says it.
    enum Cause: String, Equatable, Sendable {
        case connected
        case deviceOffline
        case macTooOld, phoneTooOld
        case clockSkew
        case rateLimited
        /// The Mac does not know this pairing: it was removed on the Mac, or the Mac was reset.
        case notPaired
        /// Something else answers at the Mac's address.
        case keyMismatch
        /// The relay works, but the Mac is not connected to it (asleep, off, Nook closed, relay switched off).
        case macNotOnRelay
        case relayFull
        case relayUnreachable
        /// The Tailscale route did not answer.
        case tailnetSilent
        /// The Mac's addresses on the local network did not answer: another network, or the Mac is away.
        case notOnLocalNetwork
        /// Something listens, but the Mac did not answer in time.
        case macSilent
        case notChecked
    }

    /// What to do about it, in order.
    enum Step: String, Equatable, Sendable {
        case connectDevice
        case updateMac, updateApp
        case setClocks
        case waitAMinute
        case pairAgain
        case wakeMac
        case openNookOnMac
        case checkRelayOnMac
        case keepMacAwake
        case checkInternet
        case turnOnTailscale
        case sameWiFi
        case setUpAway
    }

    struct Result: Equatable, Sendable {
        var cause: Cause
        var hops: [HopState]
        var steps: [Step]
        /// The fastest answer, when one came.
        var fastestMilliseconds: Int?
    }

    static func diagnose(_ input: Input) -> Result {
        let hops = hopStates(input)
        let cause = cause(input)
        let fastest = input.probes.compactMap { probe -> Int? in
            if case .answered(let ms) = probe.outcome { return ms }
            return nil
        }.min()
        return Result(cause: cause, hops: hops, steps: steps(cause, input), fastestMilliseconds: fastest)
    }

    // MARK: Hops

    private enum Path { case local, tailnet, relay }

    private static func path(_ route: CompanionRoute) -> Path {
        if route.isRelay { return .relay }
        switch route.kind {
        case .tailnet, .vpn: return .tailnet
        case .loopback, .lan, .internet: return .local
        }
    }

    /// Whether the way to the Mac worked: something that holds the key (or the relay itself) was reached.
    private static func pathResult(_ outcomes: [RouteOutcome]) -> HopResult? {
        let checked = outcomes.filter { $0 != .unchecked }
        guard !outcomes.isEmpty else { return nil }
        guard !checked.isEmpty else { return .unchecked }
        let reached = checked.contains { outcome in
            switch outcome {
            case .answered, .refused, .closedWithoutAnswer, .timedOut: return true
            case .closed(let code): return code == relayMacOffline
            case .wrongKey, .unreachable, .unchecked: return false
            }
        }
        return reached ? .ok : .failed
    }

    private static func hopStates(_ input: Input) -> [HopState] {
        var states = [HopState(hop: .device, result: input.online ? .ok : .failed)]
        let byPath = Dictionary(grouping: input.probes, by: { path($0.route) })
        for (hop, kind) in [(Hop.localNetwork, Path.local), (.tailnet, .tailnet), (.relay, .relay)] {
            guard var result = pathResult((byPath[kind] ?? []).map(\.outcome)) else { continue }
            if !input.online { result = .unchecked }
            states.append(HopState(hop: hop, result: result))
        }
        states.append(HopState(hop: .mac, result: macResult(input)))
        return states
    }

    private static func macResult(_ input: Input) -> HopResult {
        guard input.online else { return .unchecked }
        let outcomes = input.probes.map(\.outcome)
        if outcomes.contains(where: { if case .answered = $0 { return true } else { return false } }) { return .ok }
        let failed = outcomes.contains { outcome in
            switch outcome {
            case .refused, .closedWithoutAnswer, .timedOut: return true
            case .closed(let code): return code == relayMacOffline
            default: return false
            }
        }
        if failed || input.lastCloseCode == relayMacOffline { return .failed }
        return .unchecked
    }

    // MARK: The cause

    private static func cause(_ input: Input) -> Cause {
        guard input.online else { return .deviceOffline }
        switch input.compatibility {
        case .macTooOld: return .macTooOld
        case .phoneTooOld: return .phoneTooOld
        case .ok: break
        }
        let outcomes = input.probes.map(\.outcome)
        let refusals = outcomes.compactMap { outcome -> CompanionError? in
            if case .refused(let error) = outcome { return error }
            return nil
        }
        if refusals.contains(.stale) || (input.lastError == .stale && refusals.isEmpty) { return .clockSkew }
        if refusals.contains(.rateLimited) { return .rateLimited }
        if outcomes.contains(where: { if case .answered = $0 { return true } else { return false } }) { return .connected }
        if outcomes.contains(.closedWithoutAnswer) { return .notPaired }
        if outcomes.contains(.wrongKey) { return .keyMismatch }
        let relay = input.probes.filter { $0.route.isRelay }.map(\.outcome)
        if relay.contains(.closed(code: relayMacOffline)) || (relay.allSatisfy { $0 == .unchecked } && input.lastCloseCode == relayMacOffline) {
            return .macNotOnRelay
        }
        if relay.contains(.closed(code: relayRoomFull)) { return .relayFull }
        if outcomes.contains(.timedOut) { return .macSilent }
        let checked = input.probes.filter { $0.outcome != .unchecked }
        guard !checked.isEmpty else { return .notChecked }
        let relayDown = relay.contains { outcome in
            if case .closed = outcome { return true }
            return outcome == .unreachable
        }
        if relayDown { return .relayUnreachable }
        if checked.contains(where: { path($0.route) == .tailnet }) { return .tailnetSilent }
        return .notOnLocalNetwork
    }

    private static func steps(_ cause: Cause, _ input: Input) -> [Step] {
        let hasRelay = input.probes.contains { $0.route.isRelay }
        let hasTailnet = input.probes.contains { path($0.route) == .tailnet }
        switch cause {
        case .connected, .notChecked: return []
        case .deviceOffline: return [.connectDevice]
        case .macTooOld: return [.updateMac]
        case .phoneTooOld: return [.updateApp]
        case .clockSkew: return [.setClocks]
        case .rateLimited: return [.waitAMinute]
        case .notPaired, .keyMismatch: return [.pairAgain]
        case .macNotOnRelay: return [.wakeMac, .openNookOnMac, .checkRelayOnMac, .keepMacAwake]
        case .relayFull: return [.waitAMinute]
        case .relayUnreachable: return [.checkInternet, .checkRelayOnMac]
        case .tailnetSilent: return [.turnOnTailscale, .wakeMac] + (hasRelay ? [] : [.setUpAway])
        case .macSilent: return [.wakeMac, .openNookOnMac]
        case .notOnLocalNetwork:
            var steps: [Step] = [.sameWiFi, .wakeMac, .openNookOnMac]
            if !hasRelay && !hasTailnet { steps.append(.setUpAway) }
            return steps
        }
    }
}
