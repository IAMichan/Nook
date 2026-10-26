import SwiftUI

/// The one icon and color each pull request status gets, wherever it shows: list rows, tabs, the side panel, the pull
/// request page, its timeline, the filters, menus and actions. Ask here instead of naming a symbol or a color by hand,
/// so a status never looks different in two places.
///
/// Colors carry one meaning each: mint is good to go, amber waits on you, coral is broken (closed takes the softer
/// coral), violet is merged, grey has nothing to do yet. A state uses Nook's own drawn marks (`PullRequestStateGlyph`,
/// as `nook.pr.<glyph>` names that `NookSymbol` draws); checks are filled circles and reviews a seal or a speech bubble,
/// so a review never looks like a check.
enum PullRequestIcon {
    // MARK: State

    /// The state's mark by name, for views that take a symbol name (`NookSymbol`, `DropdownRow`, the timeline).
    static func symbol(_ glyph: PullRequestBadge.Glyph) -> String { "nook.pr." + glyph.rawValue }

    static func tint(_ glyph: PullRequestBadge.Glyph) -> Color {
        switch glyph {
        case .open: return NookTheme.mint
        case .draft: return NookTheme.textSecondary
        case .conflict: return NookTheme.coral
        case .merged: return NookTheme.violet
        case .closed: return NookTheme.coralSoft
        case .stack: return NookTheme.amber
        }
    }

    /// Pull requests in general (navigation, Create PR, a `#` suggestion, a link whose state is unknown): the open mark
    /// without a state color.
    static let generic = "nook.pr.open"

    // MARK: Checks

    static func symbol(_ outcome: PullRequestCheck.Outcome) -> String {
        switch outcome {
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .pending: return "smallcircle.filled.circle"
        case .skipped: return "minus.circle.fill"
        }
    }

    /// Running checks wait on CI, not on you: grey, never amber.
    static func tint(_ outcome: PullRequestCheck.Outcome) -> Color {
        switch outcome {
        case .passing: return NookTheme.mint
        case .failing: return NookTheme.coral
        case .pending: return NookTheme.textSecondary
        case .skipped: return NookTheme.textTertiary
        }
    }

    // MARK: Reviews

    enum Review {
        case approved, changesRequested, required, noReviews, commented, dismissed
    }

    static func symbol(_ review: Review) -> String {
        switch review {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .required: return "eye"
        case .noReviews: return "circle.slash"
        case .commented: return "text.bubble"
        case .dismissed: return "xmark.bubble"
        }
    }

    static func tint(_ review: Review) -> Color {
        switch review {
        case .approved: return NookTheme.mint
        case .changesRequested: return NookTheme.amber
        case .required, .commented: return NookTheme.textSecondary
        case .noReviews, .dismissed: return NookTheme.textTertiary
        }
    }

    // MARK: What holds the merge back

    /// Branch protection blocks the merge.
    static let blocked = "lock.fill"
    /// The branch is behind its base; also the Update branch action.
    static let behind = "arrow.triangle.2.circlepath"
    /// Both wait on you.
    static let blockerTint = NookTheme.amber
}

extension PullRequestBadge.Glyph {
    /// The mark for a pull request page's state: an open one that conflicts with its base wears the conflict mark.
    init(_ state: PullRequestDetail.State, conflicted: Bool) {
        switch state {
        case .open: self = conflicted ? .conflict : .open
        case .draft: self = .draft
        case .merged: self = .merged
        case .closed: self = .closed
        }
    }
}

extension PullRequestItem {
    /// The mark for this pull request's state, as its tab and row show it: a conflict wears the conflict mark.
    var stateGlyph: PullRequestBadge.Glyph {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: return conflict ? .conflict : draft ? .draft : .open
        }
    }

    /// The review decision as its icon shows it; nil when there is none to show.
    var reviewIcon: PullRequestIcon.Review? {
        switch review {
        case .approved: return .approved
        case .changesRequested: return .changesRequested
        case .required: return .required
        case .none: return nil
        }
    }

    /// The checks as their icon shows them; nil while unknown.
    var checkOutcome: PullRequestCheck.Outcome? {
        switch ci {
        case .passing: return .passing
        case .failing: return .failing
        case .pending: return .pending
        case .unknown: return nil
        }
    }
}

/// A pull request's state mark in the state's color. `.inline` (12 pt) for rows, pills, tabs and menus; `.header`
/// (16 pt) for a list row's lead and a page header. `tinted: false` takes the color around it (a section title).
struct PullRequestStateIcon: View {
    enum Size {
        case inline, header

        var points: CGFloat { self == .inline ? 12 : 16 }
        /// A small mark wants a heavier line to read as the same weight.
        var lineWidth: CGFloat { self == .inline ? 1.6 : 1.4 }
        var nodeRadius: CGFloat { self == .inline ? 1.8 : 1.7 }
    }

    let glyph: PullRequestBadge.Glyph
    var size: Size = .inline
    var tinted = true

    var body: some View {
        if tinted {
            mark.foregroundStyle(PullRequestIcon.tint(glyph))
        } else {
            mark
        }
    }

    private var mark: some View {
        PullRequestStateGlyph(glyph: glyph, size: size.points, lineWidth: size.lineWidth, nodeRadius: size.nodeRadius)
            .frame(width: size.points, height: size.points)
    }
}

/// A review's verdict, or what a pull request still waits for, in its color.
struct PullRequestReviewIcon: View {
    let review: PullRequestIcon.Review
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: PullRequestIcon.symbol(review))
            .font(NookTheme.font(size, .medium))
            .foregroundStyle(PullRequestIcon.tint(review))
    }
}

/// The outcome of a CI check or one of its steps, or of a pull request's checks together. The list rows, the pull
/// request page, the checks popover and the CI of a watched pull request all use it.
struct CheckOutcomeGlyph: View {
    let outcome: PullRequestCheck.Outcome
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: PullRequestIcon.symbol(outcome))
            .font(NookTheme.font(size, .medium))
            .foregroundStyle(PullRequestIcon.tint(outcome))
    }
}
