import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// Quoting a passage into the composer, and finding text in the conversation.
extension AgentRunPanel {
    // MARK: Quotes

    /// Picks a passage of an answer for the next message; `ask` also puts the keyboard in the box to ask about it.
    func addQuote(_ text: String, ask: Bool) {
        // Where it was taken from, so the chip can go back there: the newest answer that holds these words.
        let entries = workspace.timeline(runID).filter { $0.kind == .assistant }.map { (id: $0.id, text: $0.text) }
        switch quotes.add(text, source: ComposerQuotes.source(of: text, in: entries)) {
        case .tooLong: ToastCenter.shared.warning(tr("ws.review.quoteTooLong"))
        case .full: ToastCenter.shared.warning(tr("compose.quote.full"))
        case .empty: break
        case nil: if ask { focused = true }
        }
    }

    /// Back to where a quote was taken from in the conversation, lit up for a moment; a note when it is gone.
    func jumpToQuote(_ quote: ComposerQuotes.Quote) {
        guard let source = quote.source, workspace.timeline(runID).contains(where: { $0.id == source }) else {
            ToastCenter.shared.warning(tr("compose.quote.gone"))
            return
        }
        conversationFocus = source
    }

    /// ⇧⌘L / ⌘L on words selected in an answer; false (the key goes on) when nothing is selected there.
    func quoteSelected(ask: Bool) -> Bool {
        guard let text = SelectableProse.selection(in: NSApp.keyWindow) else { return false }
        addQuote(text, ask: ask)
        return true
    }

    /// Sends the first queued message now; false (the key goes on) when nothing waits or it cannot go in yet.
    func steerFirstQueued() -> Bool {
        guard let first = workspace.queued[runID]?.messages.first, workspace.canSendQueuedNow(runID) else { return false }
        workspace.sendQueuedNow(runID, message: first.id)
        return true
    }

    /// Widens the window (`HistoryWindow`) to hold the turn of an event it leaves out; true when it had to.
    @discardableResult
    func revealTurn(of eventID: UUID) -> Bool {
        guard let turn = derived.turn(of: eventID) else { return false }
        let start = historyStart ?? HistoryWindow.initialStart(rowsPerTurn: derived.rowsPerTurn)
        let widened = HistoryWindow.revealing(turn, from: start)
        guard widened < start else { return false }
        historyStart = widened
        return true
    }

    // MARK: Find

    func openFind() {
        finding = true
        scroll.findStarted()
    }

    func closeFind() {
        finding = false
        findQuery = ""
        findIndex = nil
        scroll.findEnded()
    }

    func stepFind(_ found: TimelineSearchResult, blocks: [TimelineBlock], proxy: ScrollViewProxy, forward: Bool) {
        guard let target = forward ? found.next(after: findIndex) : found.previous(before: findIndex) else { return }
        findIndex = target
        reveal(found, at: target, blocks: blocks, proxy: proxy)
    }

    /// Opens the groups around the match, then scrolls to it.
    func reveal(_ found: TimelineSearchResult, at index: Int, blocks: [TimelineBlock], proxy: ScrollViewProxy) {
        guard found.matches.indices.contains(index) else { return }
        let id = found.matches[index].eventID
        // Find searches the whole session: a match in a turn the window leaves out widens it.
        revealTurn(of: id)
        for key in TimelineContainers.keys(blocks)[id] ?? [] { openBlocks.insert(key) }
        DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
    }
}
