import Foundation
import AppKit

/// The cards Nook can display. Each card: one sentence, one detail line, at most two buttons.
enum CardScene: String, Equatable {
    case suggestion, reminder, listening, plan, approval
}

enum CardOutcome: Equatable {
    case done(String)       // executed: show a brief confirmation with Undo
    case show(CardScene)    // proceed to the next card
    case dismiss            // return to idle
    case callback(String, String)  // execute a registered action; second value is the confirmation (empty = show nothing)
}

struct CardAction: Equatable {
    var label: String
    var outcome: CardOutcome
    /// An SF Symbol shown before the label (e.g. "terminal"), or nil for text only.
    var symbol: String? = nil
}

enum StepTone: Equatable {
    case good, neutral, caution
}

struct PlanStep: Equatable, Identifiable {
    var id: Int { number }
    var number: Int
    var text: String
    var tag: String
    var tone: StepTone
}

/// A choice option for an agent prompt.
struct ChoiceOption: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var description: String
}

/// A prompt with options. `id` references a handler that calls `NotchViewModel.choose`.
struct ChoiceSet: Equatable {
    var id: String
    var options: [ChoiceOption]
    var multiSelect: Bool
}

/// A single row in a summary, such as "Time with agents · 6 hrs 12 mins".
struct Fact: Equatable, Identifiable {
    /// Label and value: two of today's events can share a time.
    var id: String { label + "\u{1F}" + value }
    var label: String
    var value: String
}

/// A message in a chat card (WhatsApp) or the Chats tab: incoming on the left, your own on the right.
struct ChatBubble: Equatable, Identifiable {
    var id: String
    var text: String
    var time: String
    /// When it was sent, for the line where a new day starts; nil when it is not known.
    var date: Date? = nil
    /// In a group: who wrote it. Empty in a private chat, where the card's title already says who.
    var sender: String = ""
    var fromMe: Bool = false
    /// A file that came with the message (a document's name, "photo"…): the bubble shows it as a button that opens it.
    var attachment: String? = nil
    /// How the file shows once Nook has it: a photo as itself, a video that plays in the bubble, any other file as a row.
    var media: BubbleMedia = .file
    /// A picture of the file: the photo, the video's first frame or the document's first page.
    var image: NSImage? = nil
    /// Your own message's ticks next to its time; nil shows none (their message, or a status that isn't known).
    var ticks: BubbleTicks? = nil
    /// Your own message in a group: everyone in it and how far the message got with them (read, has it, not yet), as
    /// its info lists them. Empty where the app does not say it per person.
    var readers: [ChatReader] = []
    /// The file on this Mac, when Nook already has it: a click opens it from there.
    var file: URL? = nil
    /// The message this one answers, shown small at the top of the bubble.
    var quote: BubbleQuote? = nil
    /// The emoji on it, the most used first.
    var reactions: [BubbleReaction] = []
    /// A poll this message asks, with the votes so far.
    var poll: ChatPoll? = nil
}

/// The message a bubble answers, as a chat app shows it above the answer: who wrote it and the start of its text.
struct BubbleQuote: Equatable {
    /// Who wrote it ("You" for your own); empty when it is not known.
    var sender: String
    var text: String
    /// Your own message.
    var mine = false
}

/// One emoji on a message, with how many people put it there and whether you are one of them.
struct BubbleReaction: Equatable, Identifiable {
    var emoji: String
    var count: Int
    var mine: Bool

    var id: String { emoji }
}

extension ChatBubble {
    /// A conversation as plain text for the pasteboard, one message per line: "[12:04] Anna: See you at eight".
    /// `contact` names the other side of a private chat, where the bubbles carry no sender.
    static func transcript(_ bubbles: [ChatBubble], contact: String) -> String {
        bubbles.map { $0.line(contact: contact) }.joined(separator: "\n")
    }

    /// This message as an answer quotes it: who wrote it (`contact` in a private chat) and its text.
    func quote(contact: String) -> BubbleQuote {
        BubbleQuote(sender: fromMe ? tr("chat.you") : (sender.isEmpty ? contact : sender), text: copyText, mine: fromMe)
    }

    /// The message's own text, or the file's name when it came without one.
    var copyText: String {
        text.isEmpty ? (attachment ?? "") : text
    }

    private func line(contact: String) -> String {
        let name = fromMe ? tr("chat.you") : (sender.isEmpty ? contact : sender)
        let stamp = time.isEmpty ? "" : "[\(time)] "
        return name.isEmpty ? stamp + copyText : "\(stamp)\(name): \(copyText)"
    }
}

/// How far your own message got, as WhatsApp shows it.
enum BubbleTicks: Equatable {
    init(_ receipt: ChatReceipt) {
        switch receipt {
        case .failed: self = .failed
        case .pending: self = .pending
        case .sent: self = .sent
        case .delivered: self = .delivered
        case .read: self = .read
        }
    }

    /// Still on its way to the server: a clock.
    case pending
    /// On the server: one grey tick.
    case sent
    /// On their phone: two grey ticks.
    case delivered
    /// Read: two blue ticks.
    case read
    /// It could not be sent.
    case failed
}

enum BubbleMedia: Equatable {
    case file
    /// The photo saved on this Mac, enlarged in the card with a click.
    case photo(URL)
    /// The video saved on this Mac, played in the bubble.
    case video(URL)
    /// A GIF (a real one, or a short video the app loops), playing by itself without sound.
    case gif(URL)
    /// A sticker, on its own without a bubble.
    case sticker(URL)
    /// An audio or voice message, played in the bubble; `seconds` is how long it lasts when the app says so.
    case audio(URL, seconds: Double?)
}

enum CardDetail: Equatable {
    case none
    case event(top: String, big: String, line: String, subline: String)
    case command(String, note: String)
    case waveform
    case steps([PlanStep])
    case choices(ChoiceSet)
    case diff(title: String, lines: [DiffLine], note: String)
    case facts([Fact])
    /// A longer text under a small label, complete and wrapped (the step a takeover asks about).
    case note(String, label: String)
    case chat([ChatBubble])
}

/// A notification's state in a few words ("Done", "Needs approval"), as a tinted pill at the end of the card's header,
/// so a glance tells whether the card needs you. The tone gives it its mark and color: mint done, amber waits on you,
/// coral went wrong.
struct CardStatus: Equatable {
    var text: String
    var tone: DoneTone
}

/// The lines an agent changed, shown as "+12 −3" in the card's header.
struct LineChanges: Equatable {
    var added: Int
    var removed: Int
}

struct NookCard: Equatable, Identifiable {
    var id: String
    var mood: NookMood
    var context: String
    /// The source whose app icon goes before the context ("whatsapp"), as in `SourceBrand`.
    var appIcon: String? = nil
    var title: String
    var detail: CardDetail
    var primary: CardAction
    var secondary: CardAction
    /// Content height below the notch, excluding margins.
    var contentHeight: CGFloat
    /// Displays a text field for immediate follow-up.
    var input: Bool = false
    /// The text field's placeholder when it is not a follow-up question (e.g. "Answer Lisa…").
    var inputPrompt: String? = nil
    /// The field takes the keyboard as soon as the card appears. Off for cards that arrive on their own (an incoming
    /// message, a suggestion): you keep typing where you were, and a click in the field answers.
    var focusesInput: Bool = true
    /// The field answers the chat the card shows (a WhatsApp message): it is the Chats tab's `ChatReplyField`, so "@"
    /// opens the same menu and "@nook …" lets Nook write the message into the field instead of sending it.
    var chatReply: Bool = false
    /// A chat of an app Nook cannot write in (Telegram, Messages…), by that app's name: the field works as in the Chats
    /// tab, so what you type (or let Nook write) is copied and the app opens to paste it; no quotes or emoji.
    var replyCopiesTo: String? = nil
    /// Only the field, with its send button inside it: a small card that asks one thing (the double tap's "what should
    /// Nook do?"). The title stays for VoiceOver and the buttons for Escape, but neither is drawn.
    var compact: Bool = false
    /// The height a compact card started with, kept while its field grows so it can shrink back to it.
    var compactBaseHeight: CGFloat? = nil
    /// Additional muted buttons alongside the two standard buttons (e.g. "Always" and "In terminal").
    var extra: [CardAction] = []
    /// Less common actions, tucked away in a "…" menu at the end of the button row so the row stays calm.
    var more: [CardAction] = []
    /// An agent is waiting on this (permission or prompt): the card takes precedence and persists until answered.
    var urgent: Bool = false
    /// What Nook inspected for this answer ("3 windows", "Calendar", "GitHub"), as small chips below the context.
    var sources: [String] = []
    /// What Nook can do next ("Add to calendar"). Clicking sends the sentence as a new request.
    var offers: [String] = []
    /// A small "OK" at the end of the button row that closes the card at once, for notices that would otherwise wait
    /// out their timeout.
    var acknowledge: CardAction? = nil
    /// Seconds until the card closes by itself (while the pointer is off the notch), shown as a ring on `acknowledge`.
    var countdown: TimeInterval? = nil
    /// Behavior for Esc. Defaults to primary action if nil.
    var escape: CardAction? = nil
    /// A short line above the text field: why what you typed did not work.
    var notice: String? = nil
    /// The answer on its way to the card's chat, shown above the field as it goes out.
    var sending: String? = nil
    /// Text put back into the field, e.g. a reply that could not be sent, so nothing typed is lost.
    var draft: String? = nil
    /// The card's state as a pill at the end of the header; nil shows none (an answer, a suggestion).
    var status: CardStatus? = nil
    /// What an agent changed, next to the status. The context line keeps only who and where.
    var changes: LineChanges? = nil
}

extension NookCard {
    /// A card with a conversation can be dragged larger, like the open panel, to read more of it at once.
    var resizable: Bool {
        if case .chat = detail { return true }
        return false
    }
}
