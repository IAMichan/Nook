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

/// A message in a chat card (WhatsApp): incoming on the left, your own on the right.
struct ChatBubble: Equatable, Identifiable {
    var id: String
    var text: String
    var time: String
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
}

/// How far your own message got, as WhatsApp shows it.
enum BubbleTicks: Equatable {
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
    case chat([ChatBubble])
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
    /// Displays a text field for immediate follow-up. The field gains focus as soon as the card appears.
    var input: Bool = false
    /// The text field's placeholder when it is not a follow-up question (e.g. "Answer Lisa…").
    var inputPrompt: String? = nil
    /// Additional muted buttons alongside the two standard buttons (e.g. "Always" and "In terminal").
    var extra: [CardAction] = []
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
    /// A short line above the text field: what is happening with what you typed ("Sending…") or why it did not work.
    var notice: String? = nil
    /// Text put back into the field, e.g. a reply that could not be sent, so nothing typed is lost.
    var draft: String? = nil
}

extension NookCard {
    /// A card with a conversation can be dragged larger, like the open panel, to read more of it at once.
    var resizable: Bool {
        if case .chat = detail { return true }
        return false
    }
}
