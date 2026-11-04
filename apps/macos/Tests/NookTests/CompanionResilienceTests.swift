import XCTest

/// What keeps the companion useful while the Mac is out of reach (`packages/protocol/Sources/CompanionResilience.swift`,
/// docs/COMPANION.md › When the Mac is out of reach): the clock offset, stale notifications, notification retries, the
/// phone's cache, resuming a conversation, the foreground rule, and what the outbox queues.
final class CompanionResilienceTests: XCTestCase {
    // MARK: The clock

    func testClockOffsetFollowsTheMacAndIsCappedAtADay() {
        XCTAssertEqual(CompanionClock.offset(macTime: 1_000_300, phoneTime: 1_000_000), 300)
        XCTAssertEqual(CompanionClock.offset(macTime: 1_000_000, phoneTime: 1_000_090), -90)
        XCTAssertEqual(CompanionClock.offset(macTime: 1_000_000 + 3 * 86_400, phoneTime: 1_000_000), CompanionClock.maxOffset)
        XCTAssertEqual(CompanionClock.offset(macTime: 1_000_000, phoneTime: 1_000_000 + 3 * 86_400), -CompanionClock.maxOffset)
        XCTAssertNil(CompanionClock.offset(macTime: 0, phoneTime: 1_000_000))
        XCTAssertNil(CompanionClock.offset(macTime: .nan, phoneTime: 1_000_000))
    }

    func testRequestTimeCarriesTheOffsetSoTheMacTakesIt() throws {
        let phone = 1_700_000_000.0
        let mac = phone + 600
        let offset = try XCTUnwrap(CompanionClock.offset(macTime: mac, phoneTime: phone))
        let sent = CompanionClock.sent(phone, offset: offset)
        var guardian = RequestGuard()
        let request = CompanionRequest(id: "r", sent: sent, op: .list)
        XCTAssertNil(guardian.admit(request, now: Date(timeIntervalSince1970: mac)), "with the offset the request is fresh")
        var plain = RequestGuard()
        XCTAssertEqual(plain.admit(CompanionRequest(id: "p", sent: phone, op: .list), now: Date(timeIntervalSince1970: mac)), .stale)
        XCTAssertEqual(CompanionClock.sent(phone, offset: 10 * 86_400), phone + CompanionClock.maxOffset, "capped when used too")
    }

    func testOnlyAMeaningfulChangeRetriesAtOnce() {
        XCTAssertTrue(CompanionClock.changed(0, 300))
        XCTAssertFalse(CompanionClock.changed(300, 302))
    }

    func testStaleRefusalCarriesTheMacTimeOnTheWire() throws {
        var response = CompanionResponse.failure("a", .stale)
        response.macTime = 1_700_000_000
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertEqual(object["macTime"] as? Double, 1_700_000_000)
        // An older phone reads it without the field.
        let old = try JSONDecoder().decode(CompanionResponse.self, from: Data(#"{"id":"a","ok":false,"error":"stale"}"#.utf8))
        XCTAssertNil(old.macTime)
    }

    // MARK: Notifications

    func testDeliveredNotificationsOfAnsweredItemsGo() {
        let delivered = [
            DeliveredNotifications.Delivered(id: "n1", session: "s", item: "i1", mac: "m1"),
            DeliveredNotifications.Delivered(id: "n2", session: "s", item: "i2", mac: "m1"),
            DeliveredNotifications.Delivered(id: "n3", session: "s", item: "i1", mac: "m2"),
            DeliveredNotifications.Delivered(id: "n4", session: "s", item: nil, mac: "m1"),
            DeliveredNotifications.Delivered(id: "n5", session: "s", item: "i9", mac: nil),
        ]
        XCTAssertEqual(DeliveredNotifications.stale(delivered, pending: ["i2"], mac: "m1", onlyMac: false), ["n1"],
                       "only this Mac's, only an item that no longer waits; another Mac's and a finished turn stay")
        XCTAssertEqual(DeliveredNotifications.stale(delivered, pending: ["i2"], mac: "m1", onlyMac: true), ["n1", "n5"],
                       "with one Mac, a notification from before `mac` is its")
    }

    func testDeliveredReadsTheNookDictionary() {
        let note = DeliveredNotifications.Delivered(id: "x", nook: ["session": "s", "item": "i", "mac": "m"])
        XCTAssertEqual(note, DeliveredNotifications.Delivered(id: "x", session: "s", item: "i", mac: "m"))
        let session = SessionDigest(id: "s", title: "", agent: "", attention: "approval", folder: "", updated: 0, excerpt: "",
                                    items: [.init(id: "a", kind: .approval, title: "", detail: "", canAllow: true, options: []),
                                            .init(id: "q", kind: .question, title: "", detail: "", canAllow: true, options: [])])
        XCTAssertEqual(DeliveredNotifications.pending([session]), ["a", "q"])
    }

    func testPushPayloadsNameTheirMac() throws {
        let event = PushEvent(kind: .approval, session: "S1", item: "I1", agent: "Claude", title: "")
        let payload = APNsPayload.make(event, title: "t", body: "b", badge: 1, mac: "0123456789abcdef")
        XCTAssertEqual((payload["nook"] as? [String: Any])?["mac"] as? String, "0123456789abcdef")
        XCTAssertNil((APNsPayload.make(event, title: "t", body: "b", badge: 1)["nook"] as? [String: Any])?["mac"])

        let content = RelayPushContent(title: "t", body: "b", category: PushCategory.approvalDeny, thread: "S1", session: "S1",
                                       item: "I1", badge: 1, mac: "0123456789abcdef")
        XCTAssertEqual((content.userInfo["nook"] as? [String: Any])?["mac"] as? String, "0123456789abcdef")
        let back = try JSONDecoder().decode(RelayPushContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(back.mac, "0123456789abcdef")
        // What an older Mac seals has no `mac`: it still opens.
        let old = try JSONDecoder().decode(RelayPushContent.self, from: Data(
            #"{"title":"t","body":"b","category":"NOOK_INFO","thread":"S1","session":"S1","badge":0}"#.utf8))
        XCTAssertNil(old.mac)
        XCTAssertNil((old.userInfo["nook"] as? [String: Any])?["mac"])
    }

    func testRetriesKeepDenyAndReplyButNeverAllow() {
        var retries = NotificationRetries()
        let now = Date()
        let deny = CompanionRequest(id: "d", op: .decide, session: "s", item: "i", allow: false)
        let allow = CompanionRequest(id: "a", op: .decide, session: "s", item: "i", allow: true)
        let reply = CompanionRequest(id: "r", op: .send, session: "s", text: "go on")
        XCTAssertTrue(retries.add(deny, mac: "m1", now: now))
        XCTAssertFalse(retries.add(allow, mac: "m1", now: now), "allowing later than meant is another decision")
        XCTAssertTrue(retries.add(reply, mac: "m2", now: now))
        XCTAssertTrue(retries.add(reply, mac: "m2", now: now), "the same once")
        XCTAssertFalse(retries.add(CompanionRequest(op: .stop, session: "s"), mac: "m1", now: now))
        XCTAssertEqual(retries.entries.count, 2)
        XCTAssertEqual(retries.waiting(for: "m1").map(\.id), ["d"])
        XCTAssertEqual(retries.macs, ["m1", "m2"])
        XCTAssertTrue(retries.expire(now: now.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(retries.expire(now: now.addingTimeInterval(NotificationRetries.lifetime + 1)).count, 2)
        XCTAssertTrue(retries.entries.isEmpty)
    }

    // MARK: The cache

    private func session(_ id: String) -> SessionDigest {
        SessionDigest(id: id, title: id, agent: "Claude", attention: "idle", folder: "app", updated: 0, excerpt: "", items: [])
    }

    private func entry(_ id: String, _ text: String = "") -> TimelineEntry {
        TimelineEntry(id: id, kind: .assistant, text: text.isEmpty ? id : text, detail: nil, date: 0, failed: false)
    }

    func testCacheNeverTakesOlderOverNewer() {
        var cache = CompanionCache()
        let now = Date()
        XCTAssertNil(cache.savedAt)
        XCTAssertTrue(cache.record(sessions: [session("new")], at: now))
        XCTAssertFalse(cache.record(sessions: [session("old")], at: now.addingTimeInterval(-60)))
        XCTAssertEqual(cache.sessions.map(\.id), ["new"])
        XCTAssertEqual(cache.savedAt, Date(timeIntervalSince1970: now.timeIntervalSince1970))
    }

    func testCacheKeepsTheLastFewConversationsWithTheirNewestEntries() throws {
        var cache = CompanionCache()
        let now = Date()
        let long = (0..<(CompanionCache.maxEntries + 50)).map { entry("e\($0)") }
        cache.record(timeline: long, session: "s0", at: now)
        XCTAssertEqual(cache.timeline("s0")?.count, CompanionCache.maxEntries)
        XCTAssertEqual(cache.timeline("s0")?.last?.id, "e\(CompanionCache.maxEntries + 49)", "the newest are kept")
        for index in 1...CompanionCache.maxTimelines { cache.record(timeline: [entry("x")], session: "s\(index)", at: now) }
        XCTAssertNil(cache.timeline("s0"), "the least recent goes past the limit")
        XCTAssertEqual(cache.allTimelines.count, CompanionCache.maxTimelines)
        XCTAssertFalse(cache.record(timeline: [entry("old")], session: "s1", at: now.addingTimeInterval(-1)))
        XCTAssertEqual(cache.timeline("s1")?.map(\.id), ["x"])

        let data = try JSONEncoder().encode(cache)
        XCTAssertEqual(try JSONDecoder().decode(CompanionCache.self, from: data), cache)
    }

    func testResumeSendsFromTheLastEntryThePhoneHas() throws {
        let mac = [entry("a"), entry("b"), entry("c", "c, finished"), entry("d")]
        let resumed = try XCTUnwrap(TimelineDelta.resume(mac, from: "c"))
        XCTAssertEqual(resumed.after, "b")
        XCTAssertEqual(resumed.entries.map(\.id), ["c", "d"], "the phone's last entry comes again, as it is now")
        XCTAssertNil(TimelineDelta.resume(mac, from: "a"), "nothing before it to build on: all of it")
        XCTAssertNil(TimelineDelta.resume(mac, from: "gone"))
        XCTAssertNil(TimelineDelta.resume(mac, from: nil))

        // The phone puts it after its own copy, and its half-written last entry is replaced.
        let phone = [entry("a"), entry("b"), entry("c", "c, half")]
        let merged = try XCTUnwrap(TimelineDelta.apply(resumed.entries, after: resumed.after, to: phone))
        XCTAssertEqual(merged, mac)
    }

    // MARK: Foreground

    func testPushIsLeftOutOnlyForAPhoneInFrontThatWasHeardLately() {
        let now = Date()
        XCTAssertTrue(ForegroundPolicy.skipsPush(live: true, foreground: true, lastHeard: now.addingTimeInterval(-3), now: now))
        XCTAssertFalse(ForegroundPolicy.skipsPush(live: true, foreground: true, lastHeard: now.addingTimeInterval(-30), now: now),
                       "a phone that went quiet gets its pushes again")
        XCTAssertFalse(ForegroundPolicy.skipsPush(live: true, foreground: false, lastHeard: now, now: now))
        XCTAssertFalse(ForegroundPolicy.skipsPush(live: true, foreground: nil, lastHeard: now, now: now), "a phone that never said")
        XCTAssertFalse(ForegroundPolicy.skipsPush(live: false, foreground: true, lastHeard: now, now: now))
    }

    // MARK: The outbox

    func testOutboxQueuesWhatYouWroteAndNothingThatMeansSomethingOnlyNow() {
        for op in [CompanionOp.send, .start, .ask, .inboxSend] {
            XCTAssertTrue(CompanionOutbox.queues(op), op.rawValue)
            // A repeat from the outbox must get the Mac's first answer, never a second run.
            XCTAssertTrue(CommandReceipts.keeps(op), op.rawValue)
        }
        for op in [CompanionOp.decide, .answer, .stop, .chatStop, .manage, .list, .watch] {
            XCTAssertFalse(CompanionOutbox.queues(op), op.rawValue)
        }
    }

    func testOutboxSortsWhatWaitsByWhereItGoes() {
        var outbox = CompanionOutbox()
        let now = Date()
        let launch = LaunchRequest(agent: "claude", project: "/p", task: "Fix it")
        outbox.enqueue(CompanionRequest(id: "m", op: .send, session: "s", text: "hi"), now: now)
        outbox.enqueue(CompanionRequest(id: "st", op: .start, launch: launch), now: now)
        outbox.enqueue(CompanionRequest(id: "q1", op: .ask, text: "new?"), now: now)
        outbox.enqueue(CompanionRequest(id: "q2", op: .ask, text: "more", conversation: "c"), now: now)
        outbox.enqueue(CompanionRequest(id: "w", op: .inboxSend, item: "chat", text: "on my way"), now: now)
        XCTAssertEqual(outbox.waiting(for: "s").map(\.id), ["m"])
        XCTAssertEqual(outbox.starts.map(\.id), ["st"])
        XCTAssertEqual(outbox.questions(in: nil).map(\.id), ["q1"])
        XCTAssertEqual(outbox.questions(in: "c").map(\.id), ["q2"])
        XCTAssertEqual(outbox.chatMessages(to: "chat").map(\.id), ["w"])
    }

    // MARK: Features

    func testNewFeaturesAreListedAndAboutTheConnection() {
        for feature in [CompanionFeature.clock, CompanionFeature.revoke, CompanionFeature.foreground, CompanionFeature.resume] {
            XCTAssertTrue(CompanionFeature.all.contains(feature), feature)
        }
        // Resuming a conversation is reading it; the rest are about the connection and always offered.
        XCTAssertEqual(CompanionScopes.featureScopes[CompanionFeature.resume], .read)
        XCTAssertNil(CompanionScopes.featureScopes[CompanionFeature.clock])
        XCTAssertNil(CompanionScopes.featureScopes[CompanionFeature.revoke])
    }

    func testRevokedSurvivesRedactionForAPhoneThatMayReadNothing() {
        var response = CompanionResponse(id: "sub", ok: false, error: .notAllowedFromPhone, seq: 4)
        response.revoked = true
        XCTAssertEqual(CompanionScopes.redact(response, granted: []).revoked, true)
    }
}
