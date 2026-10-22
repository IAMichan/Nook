import XCTest

/// Sending more than text from a chat: what a file goes as, polls, places and contact cards, and the requests each
/// gateway (GOWA, OpenWA, Beeper) and Telegram get for them.
final class ChatComposeTests: XCTestCase {
    private func file(_ name: String, _ kind: ChatMedia.Kind, caption: String = "", seconds: Double? = nil) -> ChatAttachment {
        ChatAttachment(path: "/tmp/" + name, kind: kind, name: name,
                       mimeType: ChatAttachment.mimeType(forExtension: (name as NSString).pathExtension), bytes: 1_000,
                       seconds: seconds, caption: caption)
    }

    // MARK: Files

    func testAFileGoesAsWhatItLooksLike() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, kind) in [("beach.jpg", ChatMedia.Kind.photo), ("party.gif", .gif), ("clip.mov", .video),
                             ("song.mp3", .audio), ("plan.pdf", .file)] {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            XCTAssertEqual(ChatAttachment(url: url)?.kind, kind, name)
        }
        let url = folder.appendingPathComponent("beach.jpg")
        XCTAssertEqual(ChatAttachment(url: url, as: .sticker)?.kind, .sticker)
        XCTAssertEqual(ChatAttachment(url: url)?.bytes, 1)
        XCTAssertNil(ChatAttachment(url: folder), "a folder is no file to send")
        XCTAssertNil(ChatAttachment(url: folder.appendingPathComponent("gone.png")))
    }

    func testAFileCanGoAsAnotherKind() {
        XCTAssertEqual(file("a.png", .photo).alternatives, [.photo, .sticker, .file])
        XCTAssertEqual(file("a.gif", .gif).alternatives, [.gif, .sticker, .file])
        XCTAssertEqual(file("a.mp4", .video).alternatives, [.video, .gif, .file])
        XCTAssertEqual(file("a.m4a", .voice).alternatives, [.audio, .voice, .file])
        XCTAssertEqual(file("a.zip", .file).alternatives, [.file])
        XCTAssertEqual(file("a.png", .photo).sent(as: .sticker).kind, .sticker)
    }

    func testTypesByExtension() {
        XCTAssertEqual(ChatAttachment.mimeType(forExtension: "JPG"), "image/jpeg")
        XCTAssertEqual(ChatAttachment.mimeType(forExtension: "heic"), "image/heic")
        XCTAssertEqual(ChatAttachment.mimeType(forExtension: "mov"), "video/quicktime")
        XCTAssertEqual(ChatAttachment.mimeType(forExtension: "m4a"), "audio/m4a")
        XCTAssertEqual(ChatAttachment.mimeType(forExtension: "docx"),
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(ChatAttachment.mimeType(forExtension: "xyz"), "application/octet-stream")
    }

    func testTooLarge() {
        var big = file("film.mp4", .video)
        big.bytes = ChatAttachment.maxBytes + 1
        XCTAssertTrue(big.tooLarge)
        XCTAssertFalse(file("film.mp4", .video).tooLarge)
    }

    // MARK: Polls

    func testAPollNeedsAQuestionAndTwoDifferentOptions() {
        var poll = ChatPollDraft()
        XCTAssertEqual(poll.problem, "chat.compose.poll.noQuestion")
        poll.question = "  Lunch?  "
        XCTAssertEqual(poll.problem, "chat.compose.poll.tooFew")
        poll.options = ["Sushi", " sushi ", ""]
        XCTAssertEqual(poll.problem, "chat.compose.poll.duplicate")
        poll.options = ["Sushi", " Pizza ", ""]
        XCTAssertNil(poll.problem)
        XCTAssertEqual(poll.cleanQuestion, "Lunch?")
        XCTAssertEqual(poll.cleanOptions, ["Sushi", "Pizza"])
        poll.options = (1...13).map { "Option \($0)" }
        XCTAssertEqual(poll.problem, "chat.compose.poll.tooMany")
        poll.options = ["Sushi", String(repeating: "x", count: 101)]
        XCTAssertEqual(poll.problem, "chat.compose.poll.optionTooLong")
    }

    func testAPollFormKeepsOneEmptyOption() {
        var poll = ChatPollDraft(question: "Lunch?", options: ["Sushi", "Pizza"])
        poll = poll.withSpareOption()
        XCTAssertEqual(poll.options, ["Sushi", "Pizza", ""])
        XCTAssertEqual(poll.withSpareOption().options.count, 3, "one empty option is enough")
        poll.options = (1...12).map { "Option \($0)" }
        XCTAssertEqual(poll.withSpareOption().options.count, 12, "no more than twelve")
    }

    func testASentPollHasNoVotesYet() {
        let poll = ChatPollDraft(question: "Lunch?", options: ["Sushi", "Pizza", ""], multiple: true).chatPoll
        XCTAssertEqual(poll.question, "Lunch?")
        XCTAssertEqual(poll.options.map(\.text), ["Sushi", "Pizza"])
        XCTAssertEqual(poll.total, 0)
        XCTAssertTrue(poll.multiple)
    }

    // MARK: Places and contacts

    func testCoordinatesTypedOrInAMapLink() {
        let typed = ChatPlace.coordinates(in: "52.37403, 4.88969")
        XCTAssertEqual(typed?.latitude ?? 0, 52.37403, accuracy: 0.00001)
        XCTAssertEqual(typed?.longitude ?? 0, 4.88969, accuracy: 0.00001)
        XCTAssertEqual(ChatPlace.coordinates(in: "https://maps.apple.com/?ll=52.3,4.9&q=Dam")?.latitude ?? 0, 52.3, accuracy: 0.0001)
        XCTAssertEqual(ChatPlace.coordinates(in: "https://www.google.com/maps/place/Dam/@52.373,4.8925,17z")?.longitude ?? 0,
                       4.8925, accuracy: 0.0001)
        XCTAssertEqual(ChatPlace.coordinates(in: "-33.8568 151.2153")?.latitude ?? 0, -33.8568, accuracy: 0.0001)
        XCTAssertNil(ChatPlace.coordinates(in: "Café de Jaren"))
        XCTAssertNil(ChatPlace.coordinates(in: "95, 4"), "no latitude beyond the pole")
        XCTAssertNil(ChatPlace.coordinates(in: "0, 0"))
    }

    func testAPlaceIsCalledByItsName() {
        XCTAssertEqual(ChatPlace(latitude: 52.37, longitude: 4.89, name: "Dam", address: "Amsterdam").title, "Dam")
        XCTAssertEqual(ChatPlace(latitude: 52.37, longitude: 4.89, address: "Amsterdam").title, "Amsterdam")
        XCTAssertEqual(ChatPlace(latitude: 52.37, longitude: 4.89).title, "52.37000, 4.89000")
        XCTAssertTrue(ChatPlace(latitude: 52.37, longitude: 4.89, name: "Dam & Co").mapsLink
            .hasPrefix("https://maps.apple.com/?ll=52.370000,4.890000&q=Dam%20%26%20Co"))
    }

    func testAContactCard() {
        let card = ChatContactCard(name: "Anna de Vries", phone: "+31 (6) 12-34 56 78")
        XCTAssertEqual(card.cleanPhone, "+31612345678")
        XCTAssertTrue(card.isValid)
        XCTAssertFalse(ChatContactCard(name: "Anna", phone: "123").isValid)
        XCTAssertFalse(ChatContactCard(name: " ", phone: "+31612345678").isValid)
        XCTAssertEqual(card.vCard, "BEGIN:VCARD\nVERSION:3.0\nFN:Anna de Vries\nTEL;TYPE=CELL:+31612345678\nEND:VCARD")
    }

    func testOneLineForTheChatList() {
        XCTAssertEqual(ChatOutgoing.poll(ChatPollDraft(question: "Lunch?", options: ["A", "B"])).line, "📊 Lunch?")
        XCTAssertEqual(ChatOutgoing.location(ChatPlace(latitude: 52.37, longitude: 4.89, name: "Dam")).line, "📍 Dam")
        XCTAssertEqual(ChatOutgoing.contact(ChatContactCard(name: "Anna", phone: "+31612345678")).line, "👤 Anna")
        XCTAssertEqual(ChatOutgoing.file(file("plan.pdf", .file, caption: "voor morgen")).line, "plan.pdf: voor morgen")
        XCTAssertEqual(ChatOutgoing.poll(ChatPollDraft(question: "Lunch?", options: ["A", "B"])).kind, .poll)
        XCTAssertEqual(ChatOutgoing.file(file("a.gif", .gif)).kind, .gif)
        XCTAssertFalse(ChatOutgoing.Kind.noPolls.contains(.poll))
        XCTAssertTrue(ChatOutgoing.Kind.noPolls.contains(.voice))
    }

    // MARK: GOWA

    func testGOWATakesAFileAsFormData() {
        let photo = WASend.gowa(.file(file("beach.jpg", .photo, caption: " Zon! ")), chat: "31612345678@s.whatsapp.net", replyTo: "ABC")
        XCTAssertEqual(photo.path, "/send/image")
        XCTAssertNil(photo.json)
        XCTAssertEqual(photo.upload, WAUpload(field: "image", path: "/tmp/beach.jpg", name: "beach.jpg", mimeType: "image/jpeg"))
        XCTAssertEqual(photo.fields, [WAFormField(name: "phone", value: "31612345678@s.whatsapp.net"),
                                      WAFormField(name: "caption", value: "Zon!"),
                                      WAFormField(name: "reply_message_id", value: "ABC")])

        let gif = WASend.gowa(.file(file("party.mp4", .gif)), chat: "x@g.us", replyTo: nil)
        XCTAssertEqual(gif.path, "/send/video")
        XCTAssertTrue(gif.fields.contains(WAFormField(name: "gif_playback", value: "true")))

        let voice = WASend.gowa(.file(file("note.m4a", .voice)), chat: "x@g.us", replyTo: nil)
        XCTAssertEqual(voice.path, "/send/audio")
        XCTAssertEqual(voice.upload?.field, "audio")
        XCTAssertTrue(voice.fields.contains(WAFormField(name: "ptt", value: "true")))

        let sticker = WASend.gowa(.file(file("cat.png", .sticker, caption: "no")), chat: "x@g.us", replyTo: "ABC")
        XCTAssertEqual(sticker.path, "/send/sticker")
        XCTAssertEqual(sticker.fields, [WAFormField(name: "phone", value: "x@g.us")], "a sticker has no caption and no reply")

        XCTAssertEqual(WASend.gowa(.file(file("plan.pdf", .file)), chat: "x@g.us", replyTo: nil).path, "/send/file")
    }

    func testGOWATakesTheRestAsJSON() {
        let poll = WASend.gowa(.poll(ChatPollDraft(question: "Lunch?", options: ["Sushi", "Pizza", ""], multiple: true)),
                               chat: "x@g.us", replyTo: nil)
        XCTAssertEqual(poll.path, "/send/poll")
        XCTAssertEqual(poll.json?["question"] as? String, "Lunch?")
        XCTAssertEqual(poll.json?["options"] as? [String], ["Sushi", "Pizza"])
        XCTAssertEqual(poll.json?["max_answer"] as? Int, 2)
        XCTAssertEqual(WASend.gowa(.poll(ChatPollDraft(question: "Q", options: ["A", "B"])), chat: "x", replyTo: nil)
            .json?["max_answer"] as? Int, 1)

        let place = WASend.gowa(.location(ChatPlace(latitude: 52.5, longitude: 4.25)), chat: "x", replyTo: nil)
        XCTAssertEqual(place.path, "/send/location")
        XCTAssertEqual(place.json?["latitude"] as? String, "52.5")
        XCTAssertEqual(place.json?["longitude"] as? String, "4.25")

        let contact = WASend.gowa(.contact(ChatContactCard(name: " Anna ", phone: "+31 6 1234 5678")), chat: "x", replyTo: nil)
        XCTAssertEqual(contact.path, "/send/contact")
        XCTAssertEqual(contact.json?["contact_name"] as? String, "Anna")
        XCTAssertEqual(contact.json?["contact_phone"] as? String, "+31612345678")
    }

    func testAMultipartBody() {
        let body = WAMultipart.body(boundary: "B", fields: [WAFormField(name: "phone", value: "123")],
                                    upload: WAUpload(field: "image", path: "/tmp/a.jpg", name: "a\"b.jpg", mimeType: "image/jpeg"),
                                    data: Data("JPEG".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), """
        --B\r
        Content-Disposition: form-data; name="phone"\r
        \r
        123\r
        --B\r
        Content-Disposition: form-data; name="image"; filename="a_b.jpg"\r
        Content-Type: image/jpeg\r
        \r
        JPEG\r
        --B--\r

        """)
        XCTAssertEqual(WAMultipart.contentType(boundary: "B"), "multipart/form-data; boundary=B")
    }

    // MARK: OpenWA

    func testOpenWATakesEverythingAsJSON() {
        let photo = WASend.openwa(.file(file("beach.jpg", .photo, caption: "Zon")), chatId: "316@c.us", replyTo: "Q",
                                  data: Data("JPEG".utf8))
        XCTAssertEqual(photo.path, "/messages/send-image")
        XCTAssertEqual(photo.json?["chatId"] as? String, "316@c.us")
        XCTAssertEqual(photo.json?["base64"] as? String, Data("JPEG".utf8).base64EncodedString())
        XCTAssertEqual(photo.json?["mimetype"] as? String, "image/jpeg")
        XCTAssertEqual(photo.json?["filename"] as? String, "beach.jpg")
        XCTAssertEqual(photo.json?["caption"] as? String, "Zon")
        XCTAssertEqual(photo.json?["quotedMessageId"] as? String, "Q")

        let voice = WASend.openwa(.file(file("note.m4a", .voice, caption: "x")), chatId: "c", replyTo: nil, data: Data())
        XCTAssertEqual(voice.path, "/messages/send-audio")
        XCTAssertEqual(voice.json?["ptt"] as? Bool, true)
        XCTAssertNil(voice.json?["caption"], "OpenWA keeps no caption for audio")
        XCTAssertNil(voice.json?["quotedMessageId"])

        XCTAssertEqual(WASend.openwa(.file(file("a.gif", .gif)), chatId: "c", replyTo: nil).path, "/messages/send-video")
        XCTAssertEqual(WASend.openwa(.file(file("a.webp", .sticker)), chatId: "c", replyTo: nil).path, "/messages/send-sticker")
        XCTAssertEqual(WASend.openwa(.file(file("a.pdf", .file)), chatId: "c", replyTo: nil).path, "/messages/send-document")

        let poll = WASend.openwa(.poll(ChatPollDraft(question: "Lunch?", options: ["A", "B"], multiple: true)), chatId: "c", replyTo: nil)
        XCTAssertEqual(poll.path, "/messages/send-poll")
        XCTAssertEqual(poll.json?["name"] as? String, "Lunch?")
        XCTAssertEqual(poll.json?["options"] as? [String], ["A", "B"])
        XCTAssertEqual(poll.json?["allowMultipleAnswers"] as? Bool, true)

        let place = WASend.openwa(.location(ChatPlace(latitude: 52.5, longitude: 4.25, name: "Dam")), chatId: "c", replyTo: nil)
        XCTAssertEqual(place.json?["latitude"] as? Double, 52.5)
        XCTAssertEqual(place.json?["description"] as? String, "Dam")
        XCTAssertNil(place.json?["address"], "OpenWA refuses fields it does not know, and empty ones are left out")

        let contact = WASend.openwa(.contact(ChatContactCard(name: "Anna", phone: "06 12345678")), chatId: "c", replyTo: nil)
        XCTAssertEqual(contact.path, "/messages/send-contact")
        XCTAssertEqual(contact.json?["contactNumber"] as? String, "0612345678")
    }

    // MARK: Beeper

    func testBeeperUploadsFirst() throws {
        let photo = file("beach.jpg", .photo, caption: "Zon")
        let upload = WASend.beeperUpload(photo, data: Data("JPEG".utf8))
        XCTAssertEqual(upload.path, "/v1/assets/upload/base64")
        XCTAssertEqual(upload.json?["fileName"] as? String, "beach.jpg")
        XCTAssertEqual(WASend.beeperUploadID(Data(#"{"uploadID":"up1","mimeType":"image/jpeg"}"#.utf8)), "up1")
        XCTAssertNil(WASend.beeperUploadID(Data(#"{"error":"too big"}"#.utf8)))

        let message = WASend.beeperMessage(.file(photo), path: "/v1/chats/c/messages", uploadID: "up1", replyTo: "m1")
        let attachment = try XCTUnwrap(message.json?["attachment"] as? [String: Any])
        XCTAssertEqual(attachment["uploadID"] as? String, "up1")
        XCTAssertEqual(attachment["type"] as? String, "image")
        XCTAssertEqual(message.json?["text"] as? String, "Zon")
        XCTAssertEqual(message.json?["replyToMessageID"] as? String, "m1")
        XCTAssertEqual(WASend.beeperType(.voice), "voice-note")

        let place = WASend.beeperMessage(.location(ChatPlace(latitude: 52.37, longitude: 4.89, name: "Dam")),
                                         path: "/v1/chats/c/messages", uploadID: nil, replyTo: nil)
        XCTAssertNil(place.json?["attachment"])
        XCTAssertTrue((place.json?["text"] as? String)?.hasPrefix("📍 Dam\nhttps://maps.apple.com/?ll=52.370000,4.890000") == true)
    }

    // MARK: Telegram

    func testTelegramContentInBothShapes() throws {
        let photo = TelegramData.content(.file(file("beach.jpg", .photo, caption: "Zon")))
        XCTAssertEqual(photo["@type"] as? String, "inputMessagePhoto")
        let wrapped = try XCTUnwrap(photo["photo"] as? [String: Any])
        XCTAssertEqual(wrapped["@type"] as? String, "inputPhoto")
        XCTAssertEqual((wrapped["photo"] as? [String: Any])?["path"] as? String, "/tmp/beach.jpg")
        XCTAssertEqual((photo["caption"] as? [String: Any])?["text"] as? String, "Zon")

        let legacy = TelegramData.content(.file(file("beach.jpg", .photo)), legacy: true)
        XCTAssertEqual((legacy["photo"] as? [String: Any])?["@type"] as? String, "inputFileLocal")

        let voice = TelegramData.content(.file(file("note.m4a", .voice, seconds: 4.4)))
        XCTAssertEqual(voice["@type"] as? String, "inputMessageVoiceNote")
        XCTAssertEqual((voice["voice_note"] as? [String: Any])?["duration"] as? Int, 4)
        XCTAssertEqual(TelegramData.content(.file(file("note.m4a", .voice, seconds: 4.4)), legacy: true)["duration"] as? Int, 4)

        XCTAssertEqual(TelegramData.content(.file(file("a.gif", .gif)))["@type"] as? String, "inputMessageAnimation")
        XCTAssertEqual(TelegramData.content(.file(file("a.webp", .sticker)))["@type"] as? String, "inputMessageSticker")
        XCTAssertEqual(TelegramData.content(.file(file("a.png", .sticker)))["@type"] as? String, "inputMessagePhoto",
                       "Telegram takes stickers as WebP only")
        XCTAssertEqual(TelegramData.content(.file(file("a.pdf", .file)))["@type"] as? String, "inputMessageDocument")
    }

    func testTelegramPollPlaceAndContact() throws {
        let draft = ChatPollDraft(question: "Lunch?", options: ["A", "B"], multiple: true)
        let poll = TelegramData.content(.poll(draft))
        XCTAssertEqual(poll["allows_multiple_answers"] as? Bool, true)
        XCTAssertEqual((poll["options"] as? [[String: Any]])?.first?["@type"] as? String, "inputPollOption")
        let legacy = TelegramData.content(.poll(draft), legacy: true)
        XCTAssertEqual((legacy["type"] as? [String: Any])?["allow_multiple_answers"] as? Bool, true)
        XCTAssertEqual((legacy["options"] as? [[String: Any]])?.first?["text"] as? String, "A")

        let place = TelegramData.content(.location(ChatPlace(latitude: 52.37, longitude: 4.89)))
        XCTAssertEqual((place["location"] as? [String: Any])?["latitude"] as? Double, 52.37)

        let contact = try XCTUnwrap(TelegramData.content(.contact(ChatContactCard(name: "Anna de Vries", phone: "+31 6 12345678")))["contact"] as? [String: Any])
        XCTAssertEqual(contact["first_name"] as? String, "Anna")
        XCTAssertEqual(contact["last_name"] as? String, "de Vries")
        XCTAssertEqual(contact["phone_number"] as? String, "+31612345678")

        let request = TelegramData.sendMessage(chat: 42, content: TelegramData.textContent("Hoi"), replyTo: 7, extra: "send:1")
        XCTAssertEqual(request["@type"] as? String, "sendMessage")
        XCTAssertEqual(request["@extra"] as? String, "send:1")
        XCTAssertEqual((request["reply_to"] as? [String: Any])?["message_id"] as? Int64, 7)
        XCTAssertNil(TelegramData.sendMessage(chat: 42, content: [:], replyTo: nil, extra: "x")["reply_to"])
        XCTAssertTrue(TelegramData.isPending(["sending_state": ["@type": "messageSendingStatePending"]]))
        XCTAssertFalse(TelegramData.isPending(["id": 1]))
    }

    // MARK: Stickers you sent

    func testStickersYouSentComeBackNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = folder.appendingPathComponent("source", isDirectory: true)
        let kept = folder.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatComposeTests-\(UUID().uuidString)"))
        let cat = source.appendingPathComponent("cat.webp")
        let party = source.appendingPathComponent("party.gif")
        try Data("cat".utf8).write(to: cat)
        try Data("party".utf8).write(to: party)

        ChatStickers.remember(cat, gif: false, defaults: defaults, in: kept)
        ChatStickers.remember(party, gif: true, defaults: defaults, in: kept)
        var recent = ChatStickers.recent(defaults: defaults, in: kept)
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(ChatStickers.isGIF(recent[0]))
        XCTAssertFalse(ChatStickers.isGIF(recent[1]))

        // The same sticker again moves up instead of being kept twice.
        ChatStickers.remember(cat, gif: false, defaults: defaults, in: kept)
        recent = ChatStickers.recent(defaults: defaults, in: kept)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(try Data(contentsOf: recent[0]), Data("cat".utf8))
    }

    // MARK: GIFs from GIPHY

    func testGiphyAsksForTrendingOrASearch() throws {
        let trending = try XCTUnwrap(Giphy.request(query: "  ", key: "K"))
        XCTAssertEqual(trending.host, "api.giphy.com")
        XCTAssertEqual(trending.path, "/v1/gifs/trending")
        let items = URLComponents(url: trending, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "api_key", value: "K")))
        XCTAssertFalse(items.contains { $0.name == "q" })

        let search = try XCTUnwrap(Giphy.request(query: "happy cat", key: "K", language: "nl", offset: 30))
        XCTAssertEqual(search.path, "/v1/gifs/search")
        let words = URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(words.contains(URLQueryItem(name: "q", value: "happy cat")))
        XCTAssertTrue(words.contains(URLQueryItem(name: "lang", value: "nl")))
        XCTAssertTrue(words.contains(URLQueryItem(name: "offset", value: "30")))
    }

    func testGiphyAnswersBecomeGIFsToSend() {
        let json = #"""
        {"data":[
          {"id":"a1","title":"Happy Cat","images":{
            "fixed_width_small":{"url":"https://media1.giphy.com/media/a1/100w.gif","width":"100","height":"75"},
            "original":{"url":"https://media1.giphy.com/media/a1/giphy.gif","mp4":"https://media1.giphy.com/media/a1/giphy.mp4"}}},
          {"id":"b2","title":"","images":{
            "fixed_width":{"url":"https://media2.giphy.com/media/b2/200w.gif"},
            "original":{"url":"https://media2.giphy.com/media/b2/giphy.gif"}}},
          {"id":"evil","images":{
            "fixed_width_small":{"url":"https://example.com/x.gif"},
            "original":{"mp4":"https://media.giphy.com/x.mp4"}}},
          {"id":"plain","images":{
            "fixed_width_small":{"url":"http://media.giphy.com/x.gif"},
            "original":{"mp4":"https://media.giphy.com/x.mp4"}}}
        ],"meta":{"status":200,"msg":"OK"}}
        """#
        let gifs = Giphy.gifs(Data(json.utf8))
        XCTAssertEqual(gifs.map(\.id), ["a1", "b2"], "a preview off GIPHY or over plain HTTP is never fetched")
        XCTAssertEqual(gifs[0].file.pathExtension, "mp4", "the MP4 goes, as WhatsApp sends a GIF")
        XCTAssertEqual(gifs[0].previewSize, CGSize(width: 100, height: 75))
        XCTAssertEqual(gifs[1].file.lastPathComponent, "giphy.gif", "without an MP4 the GIF itself goes")
        XCTAssertEqual(Giphy.fileName(gifs[0]), "GIF.mp4")
        XCTAssertEqual(Giphy.fileName(gifs[0], preview: true), "preview.gif")
        XCTAssertTrue(Giphy.gifs(Data("{}".utf8)).isEmpty)
    }

    func testYourOwnGiphyKeyTakesNooksPlace() {
        XCTAssertEqual(Giphy.key(own: "mine"), "mine")
        XCTAssertEqual(Giphy.key(own: nil), Giphy.builtInKey)
        XCTAssertEqual(Giphy.key(own: "  "), Giphy.builtInKey, "a blank key is no key")
        XCTAssertFalse(Giphy.builtInKey.isEmpty)
    }

    func testGiphySaysWhyItRefused() {
        XCTAssertEqual(Giphy.problem(Data(#"{"meta":{"status":401,"msg":"Unauthorized"}}"#.utf8)), "Unauthorized")
        XCTAssertEqual(Giphy.problem(Data(#"{"message":"Invalid authentication credentials"}"#.utf8)), "Invalid authentication credentials")
        XCTAssertNil(Giphy.problem(Data("nope".utf8)))
    }

    // MARK: Voice messages as Ogg Opus

    func testOpusPacketsSayHowLongTheyAre() {
        XCTAssertEqual(OggOpus.samples(Data([0xF8, 1, 2])), 960, "CELT 20 ms, one frame")
        XCTAssertEqual(OggOpus.samples(Data([0x08])), 960, "SILK 20 ms")
        XCTAssertEqual(OggOpus.samples(Data([0x18])), 2880, "SILK 60 ms")
        XCTAssertEqual(OggOpus.samples(Data([0xF9])), 1920, "two frames")
        XCTAssertEqual(OggOpus.samples(Data([0xFB, 0x03])), 2880, "a frame count byte")
        XCTAssertEqual(OggOpus.samples(Data()), 0)
    }

    func testOggChecksumIsOggsOwn() {
        // Polynomial 0x04C11DB7, not reflected, no initial or final XOR: the standard check string.
        XCTAssertEqual(OggOpus.crc(Data("123456789".utf8)), 0x89A1_897F)
    }

    func testAVoiceMessageBecomesAnOggOpusFile() {
        let packets = (0..<120).map { index in Data([0xF8] + [UInt8](repeating: UInt8(index % 251), count: index == 7 ? 255 : 60)) }
        let file = OggOpus.file(packets: packets)
        let pages = Self.pages(file)

        XCTAssertEqual(pages.first?.body.prefix(8), Data("OpusHead".utf8))
        XCTAssertEqual(pages.first?.flags, 0x02, "the first page begins the stream")
        XCTAssertEqual(pages.first?.body[9], 1, "one channel")
        XCTAssertEqual(pages[1].body.prefix(8), Data("OpusTags".utf8))
        XCTAssertEqual(pages.last?.flags, 0x04, "the last page ends it")
        XCTAssertEqual(pages.last?.granule, 120 * 960, "the last page counts every sample")
        XCTAssertEqual(pages.map(\.sequence), Array(0..<UInt32(pages.count)))
        for page in pages { XCTAssertTrue(page.checksumMatches) }

        // Every packet comes back whole and in order, the 256-byte one laced as 255 + 1.
        XCTAssertEqual(pages.dropFirst(2).flatMap(\.packets), packets)
    }

    private struct Page {
        var flags: UInt8
        var granule: UInt64
        var sequence: UInt32
        var body: Data
        var packets: [Data]
        var checksumMatches: Bool
    }

    private static func pages(_ file: Data) -> [Page] {
        let bytes = [UInt8](file)
        var pages: [Page] = []
        var at = 0
        func number(_ from: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[from + $1]) << (8 * UInt64($1)) }
        }
        while at + 27 <= bytes.count, Data(bytes[at..<at + 4]) == Data("OggS".utf8) {
            let count = Int(bytes[at + 26])
            let lacing = Array(bytes[at + 27..<at + 27 + count])
            let start = at + 27 + count
            let end = start + lacing.reduce(0) { $0 + Int($1) }
            var packets: [Data] = []
            var current = Data()
            var offset = start
            for value in lacing {
                current.append(contentsOf: bytes[offset..<offset + Int(value)])
                offset += Int(value)
                if value < 255 { packets.append(current); current = Data() }
            }
            var zeroed = Data(bytes[at..<end])
            zeroed.replaceSubrange(22..<26, with: Data(count: 4))
            pages.append(Page(flags: bytes[at + 5], granule: number(at + 6, 8), sequence: UInt32(number(at + 18, 4)),
                              body: Data(bytes[start..<end]), packets: packets,
                              checksumMatches: OggOpus.crc(zeroed) == UInt32(number(at + 22, 4))))
            at = end
        }
        XCTAssertEqual(at, bytes.count, "nothing after the last page")
        return pages
    }
}
