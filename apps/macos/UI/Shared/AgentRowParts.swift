import SwiftUI

// A coding agent's session in a list, as both apps show it (apps/ios/project.yml compiles this file too): the Mac's
// `AgentListRow` and the phone's `AgentRow` fill the same layout, so a session reads the same on either.

/// Three lines: the folder with the status or how long ago on the right; the session's name;
/// and the branch (with what changed and its pull request, where the app knows them) with the agent's logo at its end.
/// Without anything for the third line the logo moves up beside the name and the row keeps two lines.
struct AgentRowLayout<Slot: View, Title: View, Logo: View, Meta: View>: View {
    let folder: String
    /// The folder's full path, on hover on the Mac.
    var folderHelp = ""
    /// Something for the third line: a branch, changes or a pull request.
    let hasMeta: Bool
    /// The right end of the first line: the status, or how long ago.
    @ViewBuilder var slot: () -> Slot
    /// The name, with any quiet marks before it (pinned, forked).
    @ViewBuilder var title: () -> Title
    @ViewBuilder var logo: () -> Logo
    @ViewBuilder var meta: () -> Meta
    /// The project's badge in place of the folder symbol (its icon, or its initials on its tint), so a list of sessions from
    /// several projects shows at a glance which project each is from.
    var mark: () -> AnyView? = { nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if let mark = mark() {
                    mark.padding(.trailing, NookTheme.Spacing.xxs)
                } else {
                    Image(icon: "folder").font(NookTheme.textFont(9.5, .semibold))
                }
                Text(folder)
                    .lineLimit(1)
                    .sharedTip(folderHelp)
                Spacer(minLength: NookTheme.Spacing.sm)
                slot()
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .frame(minHeight: 20, maxHeight: SharedMetrics.isPhone ? nil : 20)

            HStack(spacing: NookTheme.Spacing.sm) {
                title()
                Spacer(minLength: NookTheme.Spacing.xs)
                if !hasMeta { logo() }
            }
            .frame(minHeight: 20, maxHeight: SharedMetrics.isPhone ? nil : 20)
            .padding(.top, NookTheme.Spacing.xs)

            if hasMeta {
                HStack(spacing: NookTheme.Spacing.sm) {
                    meta()
                    logo()
                }
                .frame(minHeight: 16, maxHeight: SharedMetrics.isPhone ? nil : 16)
                .padding(.top, NookTheme.Spacing.xxs)
            }
        }
    }
}

/// A session's name in its row: medium paper while it matters, regular grey once it recedes. It gives way last, so the
/// status and the pull request shrink to their marks first.
struct AgentRowTitle: View {
    let title: String
    var receded = false
    var dimmed = false

    var body: some View {
        Text(title)
            .font(receded ? NookTheme.TextStyle.body : NookTheme.TextStyle.strong)
            .foregroundStyle(dimmed || receded ? NookTheme.textSecondary : NookTheme.paper)
            .lineLimit(1)
            .layoutPriority(1)
    }
}

/// The branch on a session's third line, cut in the middle when it is long. It starts in the title's column for every
/// session; a worktree says so in its tooltip rather than with a mark that would push its branch to the right.
struct AgentRowBranch: View {
    let branch: String
    var worktree = false

    var body: some View {
        if worktree {
            label.sharedTip(sharedText("agents.row.worktree", "Works in its own worktree"))
        } else {
            label
        }
    }

    private var label: some View {
        Text(branch)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

extension View {
    /// A short label on hover for a part of a row: on the Mac the fast window tip (`nookTip`, NookTooltip.swift), which
    /// is Mac-only, so the iPhone app, which shares this file, keeps `help`. Empty text or `enabled: false` adds none.
    @ViewBuilder
    func sharedTip(_ text: String, enabled: Bool = true) -> some View {
        #if os(macOS)
        nookTip(text, enabled: enabled)
        #else
        if enabled, !text.isEmpty { help(text) } else { self }
        #endif
    }
}
