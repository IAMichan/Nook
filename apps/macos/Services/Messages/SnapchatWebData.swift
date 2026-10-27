import Foundation

// Snapchat in the Chats tab. Snapchat has no API for your own chats and no bridge in Nook's chat helper, so Nook reads
// Snapchat for Web (snapchat.com/web) the way you would: signed in once in a window of Nook's own, the website stays
// open out of sight (`SnapchatWebSession`), and the scripts below read what it shows: the chat list, and a chat's
// messages once you open that chat in Nook. Answers are typed into the website's own field. This is the part without
// WebKit (the scripts that run in the page and what their answers mean), so it can be tested anywhere.
//
// Snapchat Web names nothing in its page for other programs, so the scripts go by its structure and its ARIA roles,
// not by class names (those change with every release). When the page no longer looks as they expect, they say which
// step failed, and the bridge shows that instead of guessing.

enum SnapchatWebData {
    static let app = "snapchat"
    static let start = URL(string: "https://www.snapchat.com/web")!

    /// Whether a page is Snapchat for Web, where the chat list lives (not the sign-in pages on accounts.snapchat.com).
    static func isChatPage(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        return host == "web.snapchat.com" || (host == "www.snapchat.com" && url.path.hasPrefix("/web"))
    }

    // MARK: The chat list

    /// One chat as the list shows it: its name and the line under it ("New Chat · 3m", "Received · 2h").
    struct Row: Equatable, Sendable {
        /// The conversation's id in the website's address (`/web/<id>`), else its name.
        var id: String
        var name: String
        var status: String
        /// The list shows it in bold, as Snapchat marks what you have not opened.
        var bold: Bool

        /// Something waits for you in it: shown in bold, or its line starts with Snapchat's "New" ("New Chat", "New
        /// Snap"), in the languages Nook speaks.
        var isUnread: Bool {
            let line = status.lowercased()
            return bold || ["new ", "nieuw", "neu", "nouveau", "nouvelle", "nuevo", "nueva"].contains { line.hasPrefix($0) }
        }
    }

    /// How a read of the list ended.
    enum ListOutcome: Equatable {
        case chats([Row])
        /// The website shows its sign-in: only signing in again helps.
        case signedOut
        /// The page is still loading, or shows no chats yet.
        case waiting
        /// The page did not look as expected at this step.
        case failed(String)
    }

    /// The list script's answer (a dictionary from the page) as an outcome.
    static func listOutcome(_ raw: Any?) -> ListOutcome {
        guard let answer = raw as? [String: Any], let status = answer["status"] as? String else { return .failed("answer") }
        switch status {
        case "signedOut": return .signedOut
        case "loading", "empty": return .waiting
        case "ok":
            var seen = Set<String>()
            let rows = ((answer["chats"] as? [Any]) ?? []).compactMap { item -> Row? in
                guard let chat = item as? [String: Any] else { return nil }
                let name = ((chat["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let id = ((chat["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? name
                guard seen.insert(id).inserted else { return nil }
                return Row(id: id, name: name, status: ((chat["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           bold: (chat["bold"] as? Bool) ?? false)
            }
            return rows.isEmpty ? .waiting : .chats(rows)
        default:
            return .failed((answer["step"] as? String) ?? status)
        }
    }

    /// Reads the chat list: every chat with its address, its name and the line under it. Signed out when the page asks
    /// for a password or is not the chat page.
    static let listScript = """
    const uuid = /\\/web\\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
    if (document.querySelector('input[type="password"]') || !/\\/web/.test(location.pathname + location.host)) {
      return {status: 'signedOut'};
    }
    // The open chat's own messages are a list too: leave out whatever shares a part of the page with the field you type in.
    const field = document.querySelector('[contenteditable="true"], textarea');
    let pane = field ? field.parentElement : null;
    while (pane && !pane.querySelector('li, [role="listitem"]')) pane = pane.parentElement;
    const items = [...document.querySelectorAll('[role="listitem"], a[href*="/web/"]')]
      .filter(el => !(pane && pane.contains(el)));
    const chats = [];
    for (const el of items) {
      const link = el.matches('a') ? el : el.querySelector('a[href*="/web/"]');
      const match = link ? (link.getAttribute('href') || '').match(uuid) : null;
      const lines = (el.innerText || '').split('\\n').map(s => s.trim()).filter(Boolean);
      if (!lines.length) continue;
      const status = lines.slice(1).join(' · ');
      const bold = lines.length > 1 && [...el.querySelectorAll('span, div, p')].some(s =>
        (s.innerText || '').trim() === lines[1] && parseInt(getComputedStyle(s).fontWeight, 10) >= 600);
      chats.push({id: match ? match[1] : '', name: lines[0], status, bold});
    }
    if (!chats.length) return {status: document.readyState === 'complete' ? 'empty' : 'loading'};
    return {status: 'ok', chats};
    """

    /// Opens the chat `id` (or named `name`) the way a click in the list does. Answers "opened", "notFound" or
    /// "signedOut".
    static let openScript = """
    if (document.querySelector('input[type="password"]')) return {status: 'signedOut'};
    if (id && location.pathname.includes(id)) return {status: 'opened'};
    const items = [...document.querySelectorAll('[role="listitem"], a[href*="/web/"]')];
    const target = items.find(el => id && el.matches('a') && (el.getAttribute('href') || '').includes(id))
      || items.find(el => id && el.querySelector('a[href*="' + id + '"]'))
      || items.find(el => ((el.innerText || '').split('\\n')[0] || '').trim() === name);
    if (!target) return {status: 'notFound'};
    const clickable = target.matches('a, [role="button"], button') ? target
      : (target.querySelector('a, [role="button"], button') || target);
    clickable.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}));
    clickable.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
    clickable.click();
    return {status: 'opened'};
    """

    // MARK: A chat's messages

    /// One message as the open chat shows it, oldest first: who wrote it (as the heading above it says) and its text,
    /// or a snap, photo or video without text.
    struct Line: Equatable, Sendable {
        var sender: String
        var text: String
        var media: Bool = false

        /// Snapchat heads your own messages with "Me" (in the website's language).
        var isMine: Bool { SnapchatWebData.meWords.contains(sender.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    /// "Me" in the languages Snapchat's website may speak to someone using Nook.
    static let meWords: Set<String> = ["me", "ik", "ich", "moi", "yo"]

    enum ReadOutcome: Equatable {
        case lines([Line])
        case signedOut
        /// No chat is open (yet): the field to type in is missing.
        case noChat
        case failed(String)
    }

    static func readOutcome(_ raw: Any?) -> ReadOutcome {
        guard let answer = raw as? [String: Any], let status = answer["status"] as? String else { return .failed("answer") }
        switch status {
        case "signedOut": return .signedOut
        case "noChat": return .noChat
        case "ok":
            let lines = ((answer["lines"] as? [Any]) ?? []).compactMap { item -> Line? in
                guard let line = item as? [String: Any] else { return nil }
                let text = ((line["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let media = (line["media"] as? Bool) ?? false
                guard !text.isEmpty || media else { return nil }
                return Line(sender: ((line["sender"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            text: text, media: media)
            }
            return .lines(lines)
        default:
            return .failed((answer["step"] as? String) ?? status)
        }
    }

    /// Reads the open chat: the part of the page with the field you type in, from top to bottom. A heading (a header,
    /// or a short line of its own above a group of messages) says who wrote what follows; each piece of text the
    /// website marks with `dir="auto"` is one message; a picture or video larger than a profile photo is a snap.
    static let readScript = """
    if (document.querySelector('input[type="password"]')) return {status: 'signedOut'};
    const field = document.querySelector('[contenteditable="true"], textarea');
    if (!field) return {status: 'noChat'};
    let pane = field.parentElement;
    while (pane && !pane.querySelector('li, [role="listitem"]')) pane = pane.parentElement;
    if (!pane) return {status: 'noChat'};
    const lines = [];
    let sender = '';
    const walker = document.createTreeWalker(pane, NodeFilter.SHOW_ELEMENT);
    for (let el = walker.currentNode; el; el = walker.nextNode()) {
      if (el === field || field.contains(el) || el.contains(field)) continue;
      if (el.matches('header, [role="heading"], h1, h2, h3, h4, h5, h6')) {
        const name = (el.innerText || '').trim().split('\\n')[0];
        if (name) sender = name;
        continue;
      }
      if (el.closest('header, [role="heading"], h1, h2, h3, h4, h5, h6')) continue;
      if (el.matches('[dir="auto"]') && !el.parentElement.closest('[dir="auto"]')) {
        const text = (el.innerText || '').trim();
        if (text) lines.push({sender, text});
        continue;
      }
      if (el.matches('img, video, canvas') && !el.closest('[dir="auto"]')) {
        const box = el.getBoundingClientRect();
        if (box.width > 80 && box.height > 80) lines.push({sender, text: '', media: true});
      }
    }
    return {status: 'ok', lines};
    """

    // MARK: Sending

    enum SendOutcome: Equatable {
        case sent
        case signedOut
        case noChat
        /// The field already holds text you typed and did not send; Nook leaves it alone.
        case draft
        /// The text is typed, but pressing Return did not empty the field.
        case notSent
        case failed(String)
    }

    static func sendOutcome(_ raw: Any?) -> SendOutcome {
        guard let answer = raw as? [String: Any], let status = answer["status"] as? String else { return .failed("answer") }
        switch status {
        case "sent": return .sent
        case "signedOut": return .signedOut
        case "noChat": return .noChat
        case "draft": return .draft
        case "notSent": return .notSent
        default: return .failed((answer["step"] as? String) ?? status)
        }
    }

    /// The longest message Nook types into Snapchat in one go.
    static let maxText = 4_000

    /// Types `text` into the open chat's field and presses Return, as you would. Runs with `callAsyncJavaScript`, so
    /// `text` comes in as an argument and is never part of the script.
    static let sendScript = """
    if (document.querySelector('input[type="password"]')) return {status: 'signedOut'};
    const field = document.querySelector('[contenteditable="true"], textarea');
    if (!field) return {status: 'noChat'};
    const current = () => (field.value !== undefined ? field.value : field.innerText || '').trim();
    if (current()) return {status: 'draft'};
    field.focus();
    if (!document.execCommand('insertText', false, text)) {
      if (field.value !== undefined) field.value = text; else field.textContent = text;
      field.dispatchEvent(new InputEvent('input', {bubbles: true, data: text, inputType: 'insertText'}));
    }
    await new Promise(r => setTimeout(r, 150));
    if (!current()) return {status: 'failed', step: 'type'};
    for (const type of ['keydown', 'keypress', 'keyup']) {
      field.dispatchEvent(new KeyboardEvent(type, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true}));
    }
    for (let i = 0; i < 20 && current(); i++) await new Promise(r => setTimeout(r, 100));
    return {status: current() ? 'notSent' : 'sent'};
    """

    // MARK: Messages in Nook

    /// A message Nook keeps of a chat: what the website showed, with the id and time Nook gave it when it first saw it.
    struct Kept: Equatable, Sendable {
        var id: String
        var line: Line
        var date: Date
    }

    /// The website shows no ids and no times, and drops what Snapchat deletes after it was seen. So the messages of a
    /// new read are matched to the ones Nook already keeps by their order: the longest run of the newest kept messages
    /// found in the new read anchors it. What comes after that run is new, gets a fresh id and the time of this read
    /// (each a moment after the one before, so their order holds); what the read shows before it keeps its id when
    /// Nook knew it. The first read dates its messages just before `now`, in their order: Nook cannot know when they
    /// were sent.
    static func align(_ kept: [Kept], with read: [Line], chat: String, now: Date) -> [Kept] {
        guard !read.isEmpty else { return kept }
        guard !kept.isEmpty else {
            return read.enumerated().map { index, line in
                Kept(id: id(chat: chat, line: line, index: index, now: now), line: line,
                     date: now.addingTimeInterval(Double(index - read.count)))
            }
        }
        // The longest tail of the kept messages that appears in the read, and where it ends there.
        var anchor: (length: Int, end: Int)?
        for length in stride(from: min(kept.count, read.count), through: 1, by: -1) {
            let tail = kept.suffix(length).map(\.line)
            if let start = (0...(read.count - length)).last(where: { Array(read[$0..<($0 + length)]) == tail }) {
                anchor = (length, start + length - 1)
                break
            }
        }
        guard let anchor else {
            // Nothing in common: everything in the read is new (the chat was cleared and filled again).
            return kept + read.enumerated().map { index, line in
                Kept(id: id(chat: chat, line: line, index: index, now: now), line: line, date: now.addingTimeInterval(Double(index) * 0.001))
            }
        }
        let fresh = read[(anchor.end + 1)...].enumerated().map { offset, line in
            Kept(id: id(chat: chat, line: line, index: offset, now: now), line: line,
                 date: max(now, (kept.last?.date ?? now).addingTimeInterval(1)).addingTimeInterval(Double(offset) * 0.001))
        }
        return kept + fresh
    }

    /// An id for a message Nook sees for the first time: the chat, the moment and its place in that read.
    private static func id(chat: String, line: Line, index: Int, now: Date) -> String {
        "snapchat:\(chat):\(Int(now.timeIntervalSince1970 * 1000)):\(index)"
    }

    /// A chat as the inbox takes it: the messages Nook keeps of it, the list's word on whether something waits, and
    /// listed, so it shows in the Chats tab before its messages were read. A chat with more than one other person
    /// heading messages is a group: there each message names who wrote it.
    static func chat(_ row: Row, kept: [Kept], snapLabel: String) -> BridgedChat {
        let others = Set(kept.map(\.line).filter { !$0.isMine && !$0.sender.isEmpty }.map(\.sender))
        let group = others.count > 1
        let messages = kept.map { item in
            InboxMessage(id: item.id, sender: group && !item.line.isMine ? item.line.sender : "",
                         text: item.line.media && item.line.text.isEmpty ? snapLabel : item.line.text,
                         date: item.date, fromMe: item.line.isMine)
        }
        return BridgedChat(app: app, name: row.name, messages: messages, unread: row.isUnread ? 1 : 0,
                           members: group ? others.sorted() : nil, listed: true)
    }
}
