import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A session row dragged out of the Agents list carries its `SessionLink`. Dropped in an agent's text, the text view
/// inserts the link and the composer turns it into the session's chip; dropped on the rest of the composer, `receive`
/// does it. Elsewhere (another app, a note) it is just the link.
@MainActor
enum SessionLinkDrag {
    /// The session being dragged in Nook now: a drop on the composer's frame is only taken for it, so a web link dragged
    /// in from a browser is left alone.
    private(set) static var current: SessionLink?

    /// The drop types a composer for an agent adds for session rows.
    static let types: [UTType] = [.url]

    static func provider(id: String, title: String) -> NSItemProvider {
        guard let url = SessionLink.build(id: id, title: title), let link = SessionLink.parse(url) else { return NSItemProvider() }
        current = link
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerObject(url.absoluteString as NSString, visibility: .all)
        provider.suggestedName = link.title
        return provider
    }

    /// Takes a dragged session row: true when one was dropped (the chip is added once its link is read).
    static func receive(_ providers: [NSItemProvider], add: @escaping (SessionLink) -> Void) -> Bool {
        guard current != nil,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        current = nil
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                // The link itself decides which session: the drag that started in Nook only said one may come.
                if let url, let link = SessionLink.parse(url) { add(link) }
            }
        }
        return true
    }
}

extension View {
    /// Makes a session row draggable as its link (sessions Nook runs only: other rows pass nil and are not dragged).
    @ViewBuilder
    func sessionLinkDrag(id: String?, title: String) -> some View {
        if let id {
            onDrag { SessionLinkDrag.provider(id: id, title: title) }
        } else {
            self
        }
    }
}
