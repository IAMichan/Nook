import Foundation

/// Why signing in on a chat app's website, in a window of Nook's own, did not link it (or added nothing new): the same
/// reasons in the same words for every chat app Nook signs in to on the web (Teams, Slack, Snapchat, and the login pages
/// of the chat service on this Mac). The sheet shows it right where you signed in, with a way to try again, until the
/// next sign-in starts.
enum WebSignInFeedback: Equatable, Sendable {
    /// The window closed while a sign-in page still showed: signing in had not finished.
    case closedEarly
    /// The app itself was open in the window, but Nook could not take over its sign-in.
    case notTaken
    /// A personal Microsoft account (Teams free, teams.live.com): Nook reads work or school accounts.
    case personalAccount
    /// The account you signed in with was linked already (its name), so nothing was added; its sign-in was renewed.
    case alreadyLinked(String)

    /// Something went wrong; otherwise it only says what happened.
    var isError: Bool {
        if case .alreadyLinked = self { return false }
        return true
    }

    /// Whether trying again can help: not for an account Nook cannot read.
    var canRetry: Bool {
        switch self {
        case .closedEarly, .notTaken: return true
        case .personalAccount, .alreadyLinked: return false
        }
    }

    /// The row's title, for the app `name` ("Teams").
    func title(_ name: String) -> String {
        switch self {
        case .closedEarly: return tr("chats.signIn.closedEarly")
        case .notTaken: return tr("chats.signIn.notTaken", name)
        case .personalAccount: return tr("chats.signIn.personal")
        case .alreadyLinked: return tr("chats.signIn.alreadyLinked")
        }
    }

    /// What happened and what to do now, for the app `name`.
    func detail(_ name: String) -> String {
        switch self {
        case .closedEarly: return tr("chats.signIn.closedEarlyDetail", name)
        case .notTaken: return tr("chats.signIn.notTakenDetail", name)
        case .personalAccount: return tr("chats.signIn.personalDetail")
        case .alreadyLinked(let account): return tr("chats.signIn.alreadyLinkedDetail", account)
        }
    }

    /// Why a sign-in window closed without linking, from where it stood: `reachedApp` says whether the app itself
    /// (not a sign-in page) was open in it.
    static func closed(reachedApp: Bool) -> WebSignInFeedback {
        reachedApp ? .notTaken : .closedEarly
    }

    /// Why Teams' sign-in window closed without linking, from the address it showed last: Teams free for a personal
    /// account, Teams for work or school itself, or still a sign-in page (Microsoft's, Google's, an organization's).
    static func teamsClosed(at url: URL?) -> WebSignInFeedback {
        guard let host = url?.host?.lowercased() else { return .closedEarly }
        if host == "teams.live.com" || host.hasSuffix(".teams.live.com") { return .personalAccount }
        let teams = ["teams.microsoft.com", "teams.cloud.microsoft"]
        return closed(reachedApp: teams.contains { host == $0 || host.hasSuffix("." + $0) })
    }
}
