import Foundation

/// What Slack's Web API answers, turned into chats for the Chats tab: your direct messages and group messages with their
/// newest messages. Foundation only, so it can be tested anywhere; `SlackBridge` makes the calls.
/// Methods used: auth.test, users.list, conversations.list (types im, mpim), conversations.history; and to write, after
/// your own click: chat.postMessage, chat.update, chat.delete, reactions.add, reactions.remove, conversations.mark,
/// files.getUploadURLExternal and files.completeUploadExternal.
enum SlackData {
    /// One direct or group conversation.
    struct Conversation: Equatable, Sendable {
        var id: String
        /// The other person in a direct message.
        var user: String?
        /// Slack's own name for a group message: "mpdm-anna--jan--you-1".
        var name: String
        var isGroup: Bool
        /// When it last changed, as Slack lists it (seconds); 0 when Slack does not say.
        var updated: Double
    }

    /// What Slack is asked with: a token, and after signing in on slack.com (`SlackWebSession`) the `d` cookie the
    /// website's own token only works with.
    struct Auth: Codable, Equatable, Sendable {
        var token: String
        var cookie: String?
        /// The workspace, as Slack's website names it; empty for a token you pasted.
        var team: String = ""

        /// The headers of every request to Slack.
        var headers: [String: String] {
            var headers = ["Authorization": "Bearer " + token]
            if let cookie, !cookie.isEmpty { headers["Cookie"] = "d=" + cookie }
            return headers
        }
    }

    /// The website's sign-in once you signed in on slack.com: the token Slack's web client keeps for the workspace you
    /// used last (its `localConfig_v2` in local storage) and the `d` cookie it goes with. Nil until both are there.
    static func webAuth(localConfig: String?, cookie: String?) -> Auth? {
        guard let cookie, cookie.hasPrefix("xoxd-"), let data = localConfig?.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let teams = json["teams"] as? [String: [String: Any]] else { return nil }
        let signedIn = teams.filter { ($0.value["token"] as? String)?.hasPrefix("xoxc-") == true }
        guard let team = (json["lastActiveTeamId"] as? String).flatMap({ signedIn[$0] })
            ?? signedIn.sorted(by: { $0.key < $1.key }).first?.value,
            let token = team["token"] as? String else { return nil }
        return Auth(token: token, cookie: cookie, team: (team["name"] as? String) ?? "")
    }

    /// Slack answers 200 with `"ok": false` and the reason ("invalid_auth", "missing_scope"…). A missing scope says
    /// which one the token needs: "missing_scope (chat:write)".
    static func error(_ json: [String: Any]) -> String? {
        guard (json["ok"] as? Bool) != true else { return nil }
        let error = (json["error"] as? String) ?? "unknown_error"
        if let needed = json["needed"] as? String, !needed.isEmpty { return "\(error) (\(needed))" }
        return error
    }

    /// Slack's reasons that mean the sign-in itself is gone (signed out on the website, a revoked or expired token, a
    /// deactivated account): no read or send works until you sign in again, so reading stops instead of retrying.
    static let signedOutErrors: Set<String> = ["invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"]

    /// Whether Slack's answer says the sign-in is gone (`signedOutErrors`).
    static func signedOut(_ json: [String: Any]) -> Bool {
        (json["ok"] as? Bool) != true && signedOutErrors.contains((json["error"] as? String) ?? "")
    }

    /// The cursor of the next page, nil on the last.
    static func nextCursor(_ json: [String: Any]) -> String? {
        let cursor = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        return cursor.isEmpty ? nil : cursor
    }

    /// Your own user id, from auth.test.
    static func me(_ json: [String: Any]) -> String? {
        json["user_id"] as? String
    }

    /// Names per user id, from users.list: the display name people chose, else their real name, else the handle.
    static func users(_ json: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for member in json["members"] as? [[String: Any]] ?? [] {
            guard let id = member["id"] as? String else { continue }
            let profile = member["profile"] as? [String: Any] ?? [:]
            let candidates = [profile["display_name"], profile["real_name"], member["real_name"], member["name"]]
            if let name = candidates.compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                names[id] = name
            }
        }
        return names
    }

    /// Each person's profile picture (users.list, `profile.image_72`): a public address, fetched without the token.
    static func avatars(_ json: [String: Any]) -> [String: String] {
        var pictures: [String: String] = [:]
        for member in json["members"] as? [[String: Any]] ?? [] {
            guard let id = member["id"] as? String, let profile = member["profile"] as? [String: Any],
                  let image = (profile["image_72"] as? String) ?? (profile["image_48"] as? String),
                  image.hasPrefix("https://") else { continue }
            pictures[id] = image
        }
        return pictures
    }

    /// The direct and group messages from conversations.list, without the ones that were closed or belong to a user
    /// that was deleted.
    static func conversations(_ json: [String: Any]) -> [Conversation] {
        (json["channels"] as? [[String: Any]] ?? []).compactMap { channel in
            guard let id = channel["id"] as? String else { return nil }
            if channel["is_user_deleted"] as? Bool == true || channel["is_archived"] as? Bool == true { return nil }
            let isIM = channel["is_im"] as? Bool == true
            let isGroup = channel["is_mpim"] as? Bool == true
            guard isIM || isGroup else { return nil }
            // `updated` is in milliseconds; `created` in seconds.
            let updated = (channel["updated"] as? Double).map { $0 > 10_000_000_000 ? $0 / 1000 : $0 }
                ?? (channel["created"] as? Double) ?? 0
            return Conversation(id: id, user: channel["user"] as? String, name: (channel["name"] as? String) ?? "",
                                isGroup: isGroup, updated: updated)
        }
    }

    /// What the chat is called in Nook: the person in a direct message, the people in a group (yourself left out).
    static func chatName(_ conversation: Conversation, users: [String: String], me: String?) -> String {
        if let user = conversation.user, !conversation.isGroup { return users[user] ?? user }
        // "mpdm-anna--jan--you-1" → "anna, jan".
        var handle = conversation.name
        if handle.hasPrefix("mpdm-") { handle.removeFirst(5) }
        if let dash = handle.lastIndex(of: "-"), handle[handle.index(after: dash)...].allSatisfy(\.isNumber) {
            handle = String(handle[..<dash])
        }
        let mine = me.flatMap { users[$0] }?.lowercased()
        let people = handle.components(separatedBy: "--").filter { !$0.isEmpty && $0.lowercased() != mine }
        return people.isEmpty ? conversation.name : people.joined(separator: ", ")
    }

    /// The messages of conversations.history, oldest first. Joins, leaves and other notices are left out; a message
    /// with only a file shows its name.
    static func messages(_ json: [String: Any], conversation: Conversation, users: [String: String], me: String?) -> [InboxMessage] {
        let skipped: Set<String> = ["channel_join", "channel_leave", "group_join", "group_leave", "bot_add", "bot_remove",
                                    "channel_topic", "channel_purpose", "channel_name", "message_deleted", "message_changed",
                                    // What stays of a deleted message that had answers: "This message was deleted."
                                    "tombstone"]
        let messages: [InboxMessage] = (json["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let ts = message["ts"] as? String, let seconds = Double(ts) else { return nil }
            if let subtype = message["subtype"] as? String, skipped.contains(subtype) { return nil }
            var text = clean((message["text"] as? String) ?? "", users: users)
            // An app (GitHub, Jira…) often writes nothing itself and puts everything in its attachments.
            if text.isEmpty { text = clean(attachmentText(message), users: users) }
            // A huddle shows as a call, as every app's calls do.
            if let huddle = huddle(message) { text = huddle.line }
            let media = (message["files"] as? [[String: Any]])?.first.flatMap(Self.file)
            guard !text.isEmpty || media != nil else { return nil }
            let user = (message["user"] as? String) ?? (message["bot_id"] as? String) ?? ""
            let mine = me != nil && user == me
            let sender = mine || !conversation.isGroup ? "" : (users[user] ?? (message["username"] as? String) ?? user)
            var inbox = InboxMessage(id: messageID(conversation: conversation.id, ts: ts), sender: sender, text: text,
                                     date: Date(timeIntervalSince1970: seconds), fromMe: mine, media: media)
            // Slack keeps no delivery or read receipts: your message is on Slack, and that is all it says.
            if mine { inbox.receipt = .sent }
            // Always set, also when there are none: an emoji taken back in Slack leaves the message in Nook too.
            inbox.reactions = Self.reactions(message, me: me, users: users)
            inbox.quote = Self.quote(message, conversation: conversation, users: users, me: me)
            return inbox
        }
        return messages.sorted { $0.date < $1.date }
    }

    /// A huddle in a conversation (`subtype: huddle_thread`, its `room`) as a call: how long it lasted once it ended,
    /// or that nobody answered. Nil for any other message, and for a huddle still going.
    static func huddle(_ message: [String: Any]) -> ChatCall? {
        guard message["subtype"] as? String == "huddle_thread", let room = message["room"] as? [String: Any] else { return nil }
        let start = (room["date_start"] as? NSNumber)?.doubleValue ?? 0
        let end = (room["date_end"] as? NSNumber)?.doubleValue ?? 0
        let missed = room["was_missed"] as? Bool == true || room["was_rejected"] as? Bool == true
        let ended = room["has_ended"] as? Bool == true && end > start && start > 0
        // A huddle still going says nothing yet: it shows once it ended (or was missed).
        guard ended || missed else { return nil }
        return ChatCall(missed: missed, seconds: ended && !missed ? end - start : nil)
    }

    /// Where you stand in each direct conversation, from `client.counts` (Slack's website asks it too): the newest
    /// message you read (`last_read`, a `ts`) by the conversation's id. Empty for an answer without them (a pasted
    /// token Slack does not answer this for).
    static func readMarks(_ json: [String: Any]) -> [String: String] {
        var marks: [String: String] = [:]
        for key in ["ims", "mpims"] {
            for conversation in json[key] as? [[String: Any]] ?? [] {
                guard let id = conversation["id"] as? String, let read = conversation["last_read"] as? String else { continue }
                marks[id] = read
            }
        }
        return marks
    }

    /// How many messages of others came after `lastRead` (a `ts`) among `messages` (`ts`, whether yours).
    static func unread(_ messages: [(ts: Double, mine: Bool)], lastRead: String) -> Int {
        // Half a microsecond of slack: a `ts` that went through `Date` comes back a hair off.
        let read = (Double(lastRead) ?? 0) + 0.000_000_5
        return messages.filter { !$0.mine && $0.ts > read }.count
    }

    /// A message's id in Nook: its conversation and Slack's `ts` of it ("slack-D1-1700000010.000100").
    static func messageID(conversation: String, ts: String) -> String {
        "slack-\(conversation)-\(ts)"
    }

    /// Slack's `ts` of a message by its id in Nook; nil when it is not a message of `conversation` read from Slack.
    static func ts(of id: String, conversation: String) -> String? {
        let prefix = messageID(conversation: conversation, ts: "")
        guard id.hasPrefix(prefix) else { return nil }
        let ts = String(id.dropFirst(prefix.count))
        return Double(ts) == nil ? nil : ts
    }

    /// The message an answer in a thread answers (it has a `thread_ts` that is not its own `ts`): the thread's first
    /// message, by its id in Nook. An answer also sent to the conversation (`thread_broadcast`) brings that message
    /// along as `root`, so the quote shows it even when Nook does not have it. Nil for a message outside a thread.
    static func quote(_ message: [String: Any], conversation: Conversation, users: [String: String], me: String?) -> InboxQuote? {
        guard let thread = message["thread_ts"] as? String, let ts = message["ts"] as? String, thread != ts else { return nil }
        var quote = InboxQuote(id: messageID(conversation: conversation.id, ts: thread))
        if let root = message["root"] as? [String: Any] {
            let author = (root["user"] as? String) ?? ""
            quote.mine = me != nil && author == me
            quote.sender = quote.mine ? "" : (users[author] ?? "")
            quote.text = clean((root["text"] as? String) ?? "", users: users)
        }
        return quote
    }

    /// The emoji on a message (`reactions: [{name, count, users}]`), the most used first; yours when your id is among
    /// its people. A skin tone counts with the emoji itself; a workspace's own emoji (no Unicode one) is left out.
    static func reactions(_ message: [String: Any], me: String?, users: [String: String] = [:]) -> [InboxReaction] {
        var result: [InboxReaction] = []
        for reaction in message["reactions"] as? [[String: Any]] ?? [] {
            guard let name = reaction["name"] as? String, let character = Self.emoji(shortcode: name) else { continue }
            let people = reaction["users"] as? [String] ?? []
            let count = max((reaction["count"] as? Int) ?? people.count, 1)
            let mine = me.map { people.contains($0) } ?? false
            let names = people.filter { $0 != me }.compactMap { users[$0] }
            if let index = result.firstIndex(where: { $0.emoji == character }) {
                result[index].count += count
                result[index].mine = result[index].mine || mine
                if !names.isEmpty { result[index].people = (result[index].people ?? []) + names }
            } else {
                result.append(InboxReaction(emoji: character, count: count, mine: mine, people: names.isEmpty ? nil : names))
            }
        }
        return result.enumerated().sorted {
            $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
        }.map(\.element)
    }

    /// The people of a conversation (`conversations.members` → `members: [user id]`) by name, yourself left out.
    static func members(_ json: [String: Any], users: [String: String], me: String?) -> [String] {
        (json["members"] as? [String] ?? []).filter { $0 != me }.map { users[$0] ?? $0 }
    }

    /// What an app's message holds in its attachments: per attachment its lead line, its title and its text (else its
    /// fallback), one under the other.
    static func attachmentText(_ message: [String: Any]) -> String {
        (message["attachments"] as? [[String: Any]] ?? []).map { attachment in
            let lines = ["pretext", "title", "text"].compactMap { (attachment[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
            return (attachment["fallback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A file in a message (`files[]`): what it is, its name, and Slack's address to fetch it with the token. A clip
    /// recorded in Slack is a voice message.
    static func file(_ file: [String: Any]) -> ChatMedia? {
        let name = (file["name"] as? String) ?? (file["title"] as? String)
        let size = (file["size"] as? Int) ?? 0
        // A file too large to fetch for a chat opens in Slack instead.
        let source = size > ChatMedia.maxBytes ? nil : (file["url_private_download"] as? String) ?? (file["url_private"] as? String)
        guard name != nil || source != nil else { return nil }
        let voice = (file["subtype"] as? String) == "slack_audio"
        let milliseconds = (file["duration_ms"] as? Double) ?? (file["duration_ms"] as? Int).map(Double.init)
        return ChatMedia(kind: ChatMedia.kind(mimeType: file["mimetype"] as? String, name: name, voice: voice), name: name,
                         seconds: milliseconds.map { $0 / 1000 }, source: source)
    }

    /// Whether an address is Slack's own, the only place the token may go.
    static func isSlack(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "slack.com" || host.hasSuffix(".slack.com") || host.hasSuffix(".slack-edge.com")
    }

    /// Slack's markup as plain text: `<@U1>` → "@Anna", `<#C1|general>` → "#general", `<https://x|label>` → "label",
    /// `<https://x>` → the link, and the three escaped characters back.
    static func clean(_ text: String, users: [String: String]) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            result += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? ""
            let label = parts.count > 1 ? parts[1] : nil
            if target.hasPrefix("@") {
                let id = String(target.dropFirst())
                result += "@" + (label ?? users[id] ?? id)
            } else if target.hasPrefix("#") {
                result += "#" + (label ?? String(target.dropFirst()))
            } else if target.hasPrefix("!") {
                // <!here>, <!channel>, <!subteam^ID|@team>
                result += label ?? "@" + target.dropFirst()
            } else {
                result += label ?? target
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing

    /// Your text as Slack's markup wants it: only `&`, `<` and `>` escaped, so it shows exactly as typed.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The body of a write method, as a form (`application/x-www-form-urlencoded`), the values escaped.
    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// What chat.postMessage gets: your text, and as an answer (`thread`, the `ts` of the thread's first message) in
    /// that thread, also shown in the conversation itself, so it reads as an answer there as in every other app.
    static func postFields(channel: String, text: String, thread: String?) -> [String: String] {
        var fields = ["channel": channel, "text": escape(text)]
        if let thread {
            fields["thread_ts"] = thread
            fields["reply_broadcast"] = "true"
        }
        return fields
    }

    /// Where files.getUploadURLExternal says to send the file's bytes, and the file's id to complete it with. Nil when
    /// Slack names no address of its own.
    static func uploadTarget(_ json: [String: Any]) -> (url: URL, file: String)? {
        guard let address = json["upload_url"] as? String, let url = URL(string: address), isSlack(url),
              let file = json["file_id"] as? String, !file.isEmpty else { return nil }
        return (url, file)
    }

    /// What files.completeUploadExternal gets: the uploaded file shared in the conversation (in the thread of `thread`
    /// when it answers a message), with your caption as its message.
    static func completeFields(channel: String, file: String, title: String, caption: String, thread: String?) -> [String: String] {
        let files = [["id": file, "title": title]]
        let json = (try? JSONSerialization.data(withJSONObject: files, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var fields = ["files": json, "channel_id": channel]
        let comment = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { fields["initial_comment"] = escape(comment) }
        if let thread { fields["thread_ts"] = thread }
        return fields
    }

    /// The `ts` of the newest message in a conversations.history answer, to mark the conversation read up to it.
    static func newestTS(_ json: [String: Any]) -> String? {
        (json["messages"] as? [[String: Any]])?.compactMap { $0["ts"] as? String }
            .max { (Double($0) ?? 0) < (Double($1) ?? 0) }
    }

    // MARK: Emoji

    /// The emoji of one of Slack's emoji names ("+1", "joy", "+1::skin-tone-3"), the skin tone left out. Nil for a name
    /// Nook does not know, such as a workspace's own emoji.
    static func emoji(shortcode: String) -> String? {
        var name = shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if let tone = name.range(of: "::skin-tone-") { name = String(name[..<tone.lowerBound]) }
        return emojiByName[name.lowercased()]
    }

    /// Slack's name of an emoji, for reactions.add and reactions.remove, with its skin tone when it has one
    /// ("+1::skin-tone-3"). Nil for an emoji Nook knows no name of.
    static func shortcode(emoji: String) -> String? {
        var tone: Int?
        var base = String.UnicodeScalarView()
        for scalar in emoji.unicodeScalars {
            if (0x1F3FB...0x1F3FF).contains(scalar.value) { tone = Int(scalar.value - 0x1F3FB) + 2; continue }
            if scalar.value == 0xFE0F { continue }
            base.append(scalar)
        }
        guard let name = nameByEmoji[String(base)] else { return nil }
        return tone.map { name + "::skin-tone-\($0)" } ?? name
    }

    /// The emoji per Slack name, every alias included.
    private static let emojiByName: [String: String] = emojiTable.reduce(into: [:]) { result, entry in
        for name in entry.names where result[name] == nil { result[name] = entry.emoji }
    }

    /// Slack's own (first) name per emoji, keyed without the variation selector.
    private static let nameByEmoji: [String: String] = emojiTable.reduce(into: [:]) { result, entry in
        let key = entry.emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
        if result[key] == nil, let name = entry.names.first { result[key] = name }
    }

    private static let emojiTable: [(emoji: String, names: [String])] = emojiNames.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (emoji: parts[0], names: Array(parts.dropFirst()))
    }

    /// `emoji name [aliases…]` as Slack names them; the first name is the one Nook sends. Nook's own row of reactions
    /// (`ChatReactions.quick`) first, then the ones used most.
    private static let emojiNames = """
    👍 +1 thumbsup
    ❤️ heart
    😂 joy
    😮 open_mouth
    😢 cry
    🙏 pray
    👎 -1 thumbsdown
    🔥 fire
    🎉 tada
    👀 eyes
    ✅ white_check_mark
    🙌 raised_hands
    👏 clap
    😄 smile
    😀 grinning
    😃 smiley
    😁 grin
    😆 laughing satisfied
    😅 sweat_smile
    🤣 rolling_on_the_floor_laughing rofl
    🙂 slightly_smiling_face simple_smile
    🙃 upside_down_face
    😉 wink
    😊 blush
    😇 innocent
    😍 heart_eyes
    🥰 smiling_face_with_3_hearts
    😘 kissing_heart
    😋 yum
    😛 stuck_out_tongue
    😜 stuck_out_tongue_winking_eye
    🤪 zany_face
    🤗 hugging_face hugs
    🤩 star-struck star_struck
    🥳 partying_face
    😎 sunglasses
    🤓 nerd_face
    🤔 thinking_face
    🤨 face_with_raised_eyebrow
    😐 neutral_face
    😑 expressionless
    😶 no_mouth
    🙄 face_with_rolling_eyes
    😏 smirk
    😬 grimacing
    😌 relieved
    😔 pensive
    😴 sleeping
    😕 confused
    🙁 slightly_frowning_face
    😞 disappointed
    😟 worried
    😯 hushed
    😲 astonished
    😳 flushed
    🥺 pleading_face
    😭 sob
    😱 scream
    😓 sweat
    😩 weary
    😤 triumph
    😠 angry
    😡 rage
    🤯 exploding_head
    🤢 nauseated_face
    🤐 zipper_mouth_face
    🤑 money_mouth_face
    🫠 melting_face
    🫡 saluting_face
    😈 smiling_imp
    💀 skull
    💩 hankey poop shit
    👻 ghost
    🤖 robot_face
    🙈 see_no_evil
    💯 100
    🚀 rocket
    👌 ok_hand
    👋 wave
    ✌️ v
    🤞 crossed_fingers hand_with_index_and_middle_fingers_crossed
    🤝 handshake
    💪 muscle
    👉 point_right
    ☝️ point_up
    ✋ raised_hand hand
    ✍️ writing_hand
    🫶 heart_hands
    🤦 face_palm
    🤷 shrug
    🙇 bow
    💃 dancer
    🕺 man_dancing
    💔 broken_heart
    🧡 orange_heart
    💛 yellow_heart
    💚 green_heart
    💙 blue_heart
    💜 purple_heart
    🖤 black_heart
    🤍 white_heart
    💖 sparkling_heart
    💕 two_hearts
    ✔️ heavy_check_mark
    ❌ x
    ➕ heavy_plus_sign
    ⚠️ warning
    ❗ exclamation heavy_exclamation_mark
    ❓ question
    ✨ sparkles
    ⭐ star
    ⚡ zap
    💥 boom collision
    💡 bulb
    📝 memo pencil
    📌 pushpin
    🔗 link
    🔒 lock
    📈 chart_with_upwards_trend
    💰 moneybag
    💸 money_with_wings
    🐛 bug
    🎯 dart
    🏆 trophy
    🎂 birthday
    🎁 gift
    🎈 balloon
    🍾 champagne
    🍻 beers
    ☕ coffee
    🍕 pizza
    ⌛ hourglass
    ⏰ alarm_clock
    📆 calendar
    🌈 rainbow
    ☀️ sunny
    ❄️ snowflake
    🦄 unicorn_face
    🐶 dog
    🐱 cat
    """
}
