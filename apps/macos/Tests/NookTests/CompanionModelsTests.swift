import XCTest

final class CompanionModelsTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    func testPairingLinkRoundTrip() throws {
        let link = PairingLink(host: "192.168.1.20", port: 49321, key: key, macName: "Michael’s Mac")
        let parsed = try XCTUnwrap(PairingLink.parse(try XCTUnwrap(link.url).absoluteString))
        XCTAssertEqual(parsed, link)
    }

    func testPairingLinkRefusesBadInput() {
        XCTAssertNil(PairingLink.parse("https://pair?h=a&p=1&k=x"))
        XCTAssertNil(PairingLink.parse("nook://pair?h=a&p=0&k=\(Base64URL.encode(key))"))
        XCTAssertNil(PairingLink.parse("nook://pair?h=a%2Fb&p=1&k=\(Base64URL.encode(key))"), "no path in a host")
        XCTAssertNil(PairingLink.parse("nook://pair?h=a&p=1&k=\(Base64URL.encode(Data(repeating: 1, count: 16)))"), "short key")
        XCTAssertNil(PairingLink.parse("nook://pair?h=a&p=70000&k=\(Base64URL.encode(key))"))
    }

    func testBase64URLRoundTrip() {
        for length in 0..<12 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data)
        }
        XCTAssertFalse(Base64URL.encode(Data([0xfb, 0xff])).contains("+"))
    }

    func testFramingSplitsAndJoins() throws {
        var reader = CompanionFrameReader()
        let a = try XCTUnwrap(CompanionFrameReader.frame(Data("hello".utf8)))
        let b = try XCTUnwrap(CompanionFrameReader.frame(Data("x".utf8)))
        let all = a + b
        XCTAssertEqual(reader.feed(all.prefix(3)), [])
        let frames = reader.feed(all.dropFirst(3))
        XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) }, ["hello", "x"])
    }

    func testOversizedFrameClosesTheReader() {
        var reader = CompanionFrameReader()
        let n = CompanionConstants.maxFrame + 1
        let header = Data([UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        XCTAssertEqual(reader.feed(header), [])
        XCTAssertTrue(reader.overflowed)
        XCTAssertEqual(reader.feed(Data("more".utf8)), [])
        XCTAssertNil(CompanionFrameReader.frame(Data(count: n)))
    }

    func testGuardRefusesStaleAndReplayedRequests() {
        var guardrail = RequestGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = CompanionRequest(id: "a", sent: now.timeIntervalSince1970, op: .list)
        XCTAssertNil(guardrail.admit(fresh, now: now))
        XCTAssertEqual(guardrail.admit(fresh, now: now), .replay)
        let old = CompanionRequest(id: "b", sent: now.timeIntervalSince1970 - 120, op: .list)
        XCTAssertEqual(guardrail.admit(old, now: now), .stale)
        let future = CompanionRequest(id: "c", sent: now.timeIntervalSince1970 + 120, op: .list)
        XCTAssertEqual(guardrail.admit(future, now: now), .stale)
    }

    func testGuardRateLimits() {
        var guardrail = RequestGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var limited = false
        for i in 0..<200 {
            if guardrail.admit(CompanionRequest(id: "r\(i)", sent: now.timeIntervalSince1970, op: .list), now: now) == .rateLimited { limited = true }
        }
        XCTAssertTrue(limited)
    }

    func testPolicyOnlyAllowsLowRiskFromThePhone() {
        XCTAssertTrue(CompanionPolicy.canAllow(tool: "Edit", commandIsSafe: nil))
        XCTAssertTrue(CompanionPolicy.canAllow(tool: "Bash", commandIsSafe: true))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "Bash", commandIsSafe: false))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "Bash", commandIsSafe: nil))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "WebFetch", commandIsSafe: nil))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "mcp__x__y", commandIsSafe: nil))
    }

    func testMessageCleaning() {
        XCTAssertEqual(CompanionPolicy.cleanMessage("  hi\u{0007}\nthere  "), "hi\nthere")
        XCTAssertNil(CompanionPolicy.cleanMessage("  \n "))
        XCTAssertNil(CompanionPolicy.cleanMessage(String(repeating: "a", count: 8_001)))
        XCTAssertEqual(CompanionPolicy.excerpt(String(repeating: "a", count: 700)).count, CompanionConstants.excerptLimit + 1)
    }

    func testDeviceIdentifierIsStableAndShort() {
        XCTAssertEqual(PairedDevice.identifier(forKey: key), PairedDevice.identifier(forKey: key))
        XCTAssertEqual(PairedDevice.identifier(forKey: key).count, 16)
        XCTAssertNotEqual(PairedDevice.identifier(forKey: key), PairedDevice.identifier(forKey: Data(repeating: 9, count: 32)))
    }

    func testPairedDeviceDecodesWithoutPushFields() throws {
        let old = #"{"id":"a","name":"iPhone","pairedAt":0}"#
        let device = try JSONDecoder().decode(PairedDevice.self, from: Data(old.utf8))
        XCTAssertNil(device.pushToken)
        XCTAssertNil(device.pushProduction)
    }

    func testBadgeCountsSessionsWithItems() {
        let item = SessionDigest.Item(id: "i", kind: .approval, title: "t", detail: "", canAllow: false, options: [])
        let a = SessionDigest(id: "1", title: "", agent: "", attention: "approval", folder: "", branch: nil, updated: 0, excerpt: "", items: [item, item])
        let b = SessionDigest(id: "2", title: "", agent: "", attention: "idle", folder: "", branch: nil, updated: 0, excerpt: "", items: [])
        XCTAssertEqual([a, b].needingYou, 1)
    }

    func testSessionDigestCanSendIsOptional() throws {
        // A Mac from before terminal sessions reached the phone leaves it out: the phone then offers send and stop.
        let old = #"{"id":"1","title":"","agent":"","attention":"idle","folder":"","updated":0,"excerpt":"","items":[]}"#
        XCTAssertNil(try JSONDecoder().decode(SessionDigest.self, from: Data(old.utf8)).canSend)
        let terminal = SessionDigest(id: "terminal:a", title: "", agent: "", attention: "approval", folder: "", branch: nil,
                                     updated: 0, excerpt: "", items: [], canSend: false)
        XCTAssertEqual(try JSONDecoder().decode(SessionDigest.self, from: JSONEncoder().encode(terminal)), terminal)
    }

    func testRequestResponseCodable() throws {
        let request = CompanionRequest(op: .decide, session: "s", item: "i", allow: true)
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request)), request)
        let response = CompanionResponse.failure("x", .notAllowedFromPhone)
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response)), response)
    }

    func testLaunchRequestAndNewResponseFieldsCodable() throws {
        let launch = LaunchRequest(agent: "claude", project: "/Users/me/app", task: "Fix the login", plan: true, worktree: true)
        let request = CompanionRequest(op: .start, launch: launch)
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request)), request)
        var response = CompanionResponse(id: "x", ok: true, features: CompanionFeature.all, created: "s")
        response.timeline = [TimelineEntry(id: "1", kind: .assistant, text: "Done", detail: nil, date: 1, failed: false)]
        response.conversations = [ChatDigest(id: "c", title: "Plans", updated: 2, busy: true, waiting: false, preview: "")]
        response.messages = [ChatLine(id: "m", fromNook: true, text: "Hi", date: 3, streaming: false, status: "", failed: false, onMac: false)]
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response)), response)
    }

    func testInboxCodable() throws {
        let request = CompanionRequest(op: .inboxSend, item: "wa|31600000000@s.whatsapp.net", text: "On my way", replyTo: "m1")
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request)), request)
        let chat = InboxChatDigest(id: "wa|x", app: "whatsapp", appName: "WhatsApp", name: "Anna", preview: "You: see you",
                                   last: 10, unread: 2, canSend: true, ticks: "read", waitsInApp: false)
        let line = InboxLine(id: "m1", text: "Dinner?", date: 9, sender: "", fromMe: false, attachment: "Photo", ticks: nil,
                             quoteSender: "You", quoteText: "Hi", reactions: ["👍 2"])
        let response = CompanionResponse(id: "x", ok: true, message: "chatsaccess", inbox: [chat], inboxLines: [line])
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response)), response)
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.inbox))
        // A phone from before the Chats tab sends no `replyTo`.
        XCTAssertNil(try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"a","sent":1,"op":"inbox"}"#.utf8)).replyTo)
    }

    func testOldMessagesStillDecode() throws {
        // A Mac or phone of the first version sends none of the new fields.
        let request = #"{"id":"a","sent":1,"op":"list"}"#
        XCTAssertNil(try JSONDecoder().decode(CompanionRequest.self, from: Data(request.utf8)).launch)
        let response = #"{"id":"a","ok":true,"sessions":[]}"#
        XCTAssertNil(try JSONDecoder().decode(CompanionResponse.self, from: Data(response.utf8)).features)
    }

    func testNewestFittingKeepsTheLatestWithinBudget() throws {
        let lines = (0..<100).map { TimelineEntry(id: "\($0)", kind: .assistant, text: String(repeating: "a", count: 1_000), detail: nil, date: Double($0), failed: false) }
        let kept = CompanionPolicy.newestFitting(lines, budget: 10_000)
        XCTAssertFalse(kept.isEmpty)
        XCTAssertLessThan(kept.count, 100)
        XCTAssertEqual(kept.last?.id, "99")
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(kept).count, 10_000 + kept.count + 2)
        XCTAssertEqual(CompanionPolicy.newestFitting(Array(lines.prefix(3))).count, 3)
    }

    func testClipCutsLongLines() {
        XCTAssertEqual(CompanionPolicy.clip("  short \r "), "short")
        XCTAssertEqual(CompanionPolicy.clip(String(repeating: "a", count: 10), limit: 4), "aaaa…")
    }

    func testHomeAndUsageCodable() throws {
        let limit = UsageDigest.Limit(label: "5 hours", percent: 34, resetsAt: 100, note: nil, duration: 18_000)
        let account = UsageDigest.Account(id: "claude", agent: "Claude", account: "Work", limits: [limit])
        let home = HomeDigest(lines: [.init(id: "l", title: "Claude waits", subtitle: "nook", icon: "agent:Claude Code", tone: "amber")],
                              events: [.init(id: "e", title: "Standup", start: 1, end: 2, location: "", calendar: "Work")],
                              suggestions: ["Summarize my day"],
                              track: .init(title: "Song", artist: "Band", album: "", app: "Music", playing: true, position: 12, duration: 200),
                              accounts: [account])
        let usage = UsageDigest(accounts: [account], range: "week", sessions: 3, completed: 2, failed: 0, running: 1, inputTokens: 10,
                                outputTokens: 20, cacheTokens: 5, cost: 0.4, days: [.init(day: 0, agent: "Claude", tokens: 30)],
                                models: [.init(agent: "Claude", model: "default", sessions: 3, tokens: 30, cost: nil)])
        let response = CompanionResponse(id: "x", ok: true, home: home, usage: usage)
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response)), response)
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.usage))
    }

    // MARK: Live Activities

    private let liveToken = String(repeating: "ab", count: 80)

    private func snapshot(_ id: String, _ phase: LiveActivityPhase, title: String = "Fix login") -> LiveActivitySnapshot {
        LiveActivitySnapshot(session: id, project: "nook", title: title, agent: "Claude Code", model: "sonnet", phase: phase)
    }

    func testLiveActivityRegistrationCodableAndOldPhones() throws {
        let registration = LiveActivityRegistration(kind: .activity, token: liveToken, session: "s1", production: false)
        let request = CompanionRequest(op: .liveActivity, live: registration)
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request)), request)
        XCTAssertNil(try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"a","sent":1,"op":"list"}"#.utf8)).live)
        // The phone only registers with a Mac that lists the feature, so an older Mac never sees the new op.
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.liveActivity))
    }

    func testLiveActivityRegistrationValidation() {
        XCTAssertTrue(LiveActivityRegistration(kind: .pushToStart, token: liveToken).isValid)
        XCTAssertFalse(LiveActivityRegistration(kind: .pushToStart, token: nil).isValid)
        XCTAssertFalse(LiveActivityRegistration(kind: .pushToStart, token: "zz" + liveToken).isValid, "hex only: it goes into a URL")
        XCTAssertFalse(LiveActivityRegistration(kind: .pushToStart, token: "abc").isValid)
        XCTAssertFalse(LiveActivityRegistration(kind: .pushToStart, token: String(repeating: "a", count: 514)).isValid)
        XCTAssertTrue(LiveActivityRegistration(kind: .activity, token: liveToken, session: "s1").isValid)
        XCTAssertFalse(LiveActivityRegistration(kind: .activity, token: liveToken, session: nil).isValid)
        XCTAssertFalse(LiveActivityRegistration(kind: .activity, token: liveToken, session: "a\u{0007}b").isValid)
        XCTAssertTrue(LiveActivityRegistration(kind: .ended, session: "s1").isValid)
        XCTAssertFalse(LiveActivityRegistration(kind: .ended).isValid)
        XCTAssertTrue(LiveActivityRegistration(kind: .off).isValid)
        XCTAssertNotNil(APNsJWT.endpoint(production: true, deviceToken: liveToken), "activity tokens are longer than device tokens")
    }

    func testPairedDeviceKeepsLiveActivityTokens() throws {
        var device = PairedDevice(id: "d", name: "iPhone", pairedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(device.wantsLiveActivities)
        device.apply(LiveActivityRegistration(kind: .pushToStart, token: liveToken.uppercased(), production: false))
        XCTAssertEqual(device.liveStartToken, liveToken)
        XCTAssertEqual(device.liveProduction, false)
        XCTAssertTrue(device.wantsLiveActivities)
        device.apply(LiveActivityRegistration(kind: .activity, token: liveToken, session: "s1"))
        XCTAssertEqual(device.liveTokens, ["s1": liveToken])
        device.apply(LiveActivityRegistration(kind: .ended, session: "s1"))
        XCTAssertEqual(device.liveTokens, [:])
        for i in 0..<30 { device.apply(LiveActivityRegistration(kind: .activity, token: liveToken, session: "s\(i)")) }
        XCTAssertEqual(device.liveTokens?.count, PairedDevice.maxLiveTokens)
        // Survives the Mac's store, and an old store without the fields still decodes.
        XCTAssertEqual(try JSONDecoder().decode(PairedDevice.self, from: JSONEncoder().encode(device)), device)
        let old = try JSONDecoder().decode(PairedDevice.self, from: Data(#"{"id":"a","name":"iPhone","pairedAt":0}"#.utf8))
        XCTAssertNil(old.liveActivities)
        XCTAssertNil(old.liveTokens)
        device.apply(LiveActivityRegistration(kind: .off))
        XCTAssertEqual(device.liveActivities, false)
        XCTAssertNil(device.liveStartToken)
        XCTAssertNil(device.liveTokens)
        XCTAssertFalse(device.wantsLiveActivities)
    }

    func testLiveActivityPhaseFromAttention() {
        XCTAssertEqual(LiveActivityPhase(attention: "working", waiting: false), .working)
        XCTAssertEqual(LiveActivityPhase(attention: "working", waiting: true), .waiting)
        XCTAssertEqual(LiveActivityPhase(attention: "approval", waiting: false), .waiting)
        XCTAssertEqual(LiveActivityPhase(attention: "input", waiting: false), .waiting)
        XCTAssertEqual(LiveActivityPhase(attention: "failed", waiting: false), .failed)
        XCTAssertEqual(LiveActivityPhase(attention: "limited", waiting: false), .failed)
        XCTAssertEqual(LiveActivityPhase(attention: "ready", waiting: false), .done)
        XCTAssertEqual(LiveActivityPhase(attention: "finished", waiting: false), .done)
        XCTAssertEqual(LiveActivityPhase(attention: "idle", waiting: false), .done)
    }

    func testLiveActivitySnapshotKeepsTitlesOutWhenAsked() {
        let digest = SessionDigest(id: "1", title: "Secret project", agent: "Codex", attention: "working", folder: "acme",
                                   branch: nil, updated: 0, excerpt: "", items: [], model: "gpt-5")
        let open = LiveActivitySnapshot(digest: digest)
        XCTAssertEqual(open.title, "Secret project")
        XCTAssertEqual(open.project, "acme")
        XCTAssertEqual(open.model, "gpt-5")
        XCTAssertEqual(open.phase, .working)
        let kept = LiveActivitySnapshot(digest: digest, includeTitle: false)
        XCTAssertEqual(kept.title, "")
        XCTAssertEqual(kept.project, "")
        XCTAssertEqual(kept.agent, "Codex")
        // An older Mac sends no model.
        let old = #"{"id":"1","title":"","agent":"","attention":"idle","folder":"","updated":0,"excerpt":"","items":[]}"#
        XCTAssertNil(try JSONDecoder().decode(SessionDigest.self, from: Data(old.utf8)).model)
    }

    func testPlannerStartsUpdatesAndEndsOneActivityPerSession() {
        var planner = LiveActivityPlanner()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // A session begins to work: one start, with a stale date. A finished one gets nothing.
        var actions = planner.plan([snapshot("a", .working), snapshot("b", .done)], canStart: true, tokens: [], now: t0)
        XCTAssertEqual(actions.map(\.event), [.start])
        XCTAssertEqual(actions.first?.session, "a")
        XCTAssertEqual(actions.first?.attributes?.title, "Fix login")
        XCTAssertEqual(actions.first?.staleDate, t0.addingTimeInterval(LiveActivityPlanner.staleAfter))
        XCTAssertTrue(actions.first?.urgent == true)

        // Nothing changed: nothing is sent, also once the phone handed over the activity's token.
        XCTAssertEqual(planner.plan([snapshot("a", .working)], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(10)), [])

        // It waits on you: an urgent update with the new phase, its own start time.
        let t1 = t0.addingTimeInterval(20)
        actions = planner.plan([snapshot("a", .waiting)], canStart: true, tokens: ["a"], now: t1)
        XCTAssertEqual(actions.map(\.event), [.update])
        XCTAssertEqual(actions.first?.content.phase, .waiting)
        XCTAssertEqual(actions.first?.content.since, t1.timeIntervalSince1970)
        XCTAssertTrue(actions.first?.urgent == true)

        // Done: it ends and stays up for 15 minutes.
        let t2 = t1.addingTimeInterval(60)
        actions = planner.plan([snapshot("a", .done)], canStart: true, tokens: ["a"], now: t2)
        XCTAssertEqual(actions.map(\.event), [.end])
        XCTAssertEqual(actions.first?.content.phase, .done)
        XCTAssertEqual(actions.first?.dismissalDate, t2.addingTimeInterval(LiveActivityPlanner.finishedVisible))
        XCTAssertTrue(planner.tracked.isEmpty)
    }

    func testPlannerRateLimitsAndKeepsTheActivityFresh() {
        var planner = LiveActivityPlanner()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = planner.plan([snapshot("a", .working)], canStart: true, tokens: ["a"], now: t0)

        // A phase change within seconds of the last push waits a moment, then goes out with priority 10.
        let titled = "Fix login form"
        XCTAssertEqual(planner.plan([snapshot("a", .waiting, title: titled)], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(2)), [])
        var actions = planner.plan([snapshot("a", .waiting, title: titled)], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(6))
        XCTAssertEqual(actions.map(\.event), [.update])
        XCTAssertEqual(actions.first?.content.title, titled)
        XCTAssertTrue(actions.first?.urgent == true)

        // Only a new title: it waits half a minute after the last push, then goes out with priority 5.
        XCTAssertEqual(planner.plan([snapshot("a", .waiting, title: "Login")], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(10)), [])
        actions = planner.plan([snapshot("a", .waiting, title: "Login")], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(36))
        XCTAssertEqual(actions.map(\.event), [.update])
        XCTAssertFalse(actions.first?.urgent ?? true)

        // Back to working, then quiet: a priority-5 heartbeat moves the stale date on.
        _ = planner.plan([snapshot("a", .working, title: "Login")], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(50))
        XCTAssertEqual(planner.plan([snapshot("a", .working, title: "Login")], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(100)), [])
        let beat = t0.addingTimeInterval(50 + LiveActivityPlanner.heartbeat)
        actions = planner.plan([snapshot("a", .working, title: "Login")], canStart: true, tokens: ["a"], now: beat)
        XCTAssertEqual(actions.map(\.event), [.update])
        XCTAssertFalse(actions.first?.urgent ?? true)
        XCTAssertEqual(actions.first?.staleDate, beat.addingTimeInterval(LiveActivityPlanner.staleAfter))
    }

    func testPlannerWithoutTokensAndLimits() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // No push-to-start token: nothing starts from the Mac.
        var planner = LiveActivityPlanner()
        XCTAssertEqual(planner.plan([snapshot("a", .working)], canStart: false, tokens: [], now: t0), [])

        // An activity the phone started itself is taken over as soon as its token is known.
        let actions = planner.plan([snapshot("a", .working)], canStart: false, tokens: ["a"], now: t0)
        XCTAssertEqual(actions.map(\.event), [.update])

        // At most a handful at once.
        planner = LiveActivityPlanner()
        let many = (0..<8).map { snapshot("s\($0)", .working) }
        XCTAssertEqual(planner.plan(many, canStart: true, tokens: [], now: t0).count, LiveActivityPlanner.maxActivities)

        // A session gone from the list ends at once; a session that ended does not start again within the cooldown.
        planner = LiveActivityPlanner()
        _ = planner.plan([snapshot("a", .working)], canStart: true, tokens: ["a"], now: t0)
        let gone = planner.plan([], canStart: true, tokens: ["a"], now: t0.addingTimeInterval(10))
        XCTAssertEqual(gone.map(\.event), [.end])
        XCTAssertEqual(gone.first?.dismissalDate, t0.addingTimeInterval(10))
        XCTAssertEqual(planner.plan([snapshot("a", .working)], canStart: true, tokens: [], now: t0.addingTimeInterval(20)), [])
        XCTAssertEqual(planner.plan([snapshot("a", .working)], canStart: true, tokens: [], now: t0.addingTimeInterval(80)).map(\.event), [.start])

        // A start that did not arrive: forgotten, and tried again after the cooldown.
        planner.forget("a", now: t0.addingTimeInterval(90))
        XCTAssertTrue(planner.tracked.isEmpty)
        XCTAssertEqual(planner.plan([snapshot("a", .working)], canStart: true, tokens: [], now: t0.addingTimeInterval(100)), [])
    }

    func testLiveActivityPayload() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = LiveActivityContent(phase: .working, title: "Fix login", model: "sonnet", since: 1_699_999_000)
        let attributes = NookActivityAttributes(session: "s1", project: "nook", agent: "Claude Code", title: "Fix login")
        let start = LiveActivityAction(event: .start, session: "s1", attributes: attributes, content: content,
                                       staleDate: now.addingTimeInterval(600), dismissalDate: nil, urgent: true)
        let payload = LiveActivityPayload.make(start, now: now, alert: (title: "Claude Code", body: "Is working on your Mac."))
        let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "start")
        XCTAssertEqual(aps["timestamp"] as? Int, 1_700_000_000)
        XCTAssertEqual(aps["stale-date"] as? Int, 1_700_000_600)
        XCTAssertEqual(aps["attributes-type"] as? String, "NookActivityAttributes")
        XCTAssertEqual((aps["attributes"] as? [String: Any])?["session"] as? String, "s1")
        XCTAssertEqual((aps["alert"] as? [String: String])?["title"], "Claude Code")
        // The content state decodes back into what the widget reads.
        let state = try JSONSerialization.data(withJSONObject: try XCTUnwrap(aps["content-state"]))
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityContent.self, from: state), content)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: payload).count, 4_096)

        let end = LiveActivityAction(event: .end, session: "s1", attributes: nil, content: content, staleDate: nil,
                                     dismissalDate: now.addingTimeInterval(900), urgent: true)
        let endAps = try XCTUnwrap(LiveActivityPayload.make(end, now: now)["aps"] as? [String: Any])
        XCTAssertEqual(endAps["event"] as? String, "end")
        XCTAssertEqual(endAps["dismissal-date"] as? Int, 1_700_000_900)
        XCTAssertNil(endAps["attributes"])
        XCTAssertNil(endAps["alert"])
        XCTAssertEqual(LiveActivityPayload.topic(bundleID: "nl.imdigital.nook.companion"), "nl.imdigital.nook.companion.push-type.liveactivity")
        XCTAssertEqual(LiveActivityPayload.pushType, "liveactivity")
    }
}
