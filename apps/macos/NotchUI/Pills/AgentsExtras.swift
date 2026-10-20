import SwiftUI
import AppKit

/// The pages the Agents tab opens on the right: your pull requests and the usage of every account (from the buttons
/// under the list), and the tools that are not tied to one session: every terminal, the browser, every worktree.
enum AgentsPage {
    static let pullRequests = "pulls"
    static let usage = "usage"
    static let terminals = "terminals"
    static let browser = "browser"
    static let worktrees = "worktrees"
    static let simulator = "simulator"
    /// The pages that are a tool you work in: the panel widens for them and stays open.
    static let tools: Set<String> = [terminals, browser, worktrees, simulator]
}

/// Pull requests and usage as quiet icons under the list, and Settings at the far end, with the update button beside it
/// when main has something this build lacks. It takes the list's width, so Settings follows the line beside the list
/// when you drag it.
struct AgentsFooter: View {
    let selected: String
    let open: (String) -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            FooterIcon(label: tr("agents.footer.pullRequests"), active: selected == AgentsPage.pullRequests,
                       action: { open(AgentsPage.pullRequests) }) { PullRequestGlyph() }
            FooterIcon(label: tr("agents.footer.usage"), active: selected == AgentsPage.usage,
                       action: { open(AgentsPage.usage) }) { UsageGlyph() }
            Spacer(minLength: 0)
            UpdateFooterButton()
            FooterIcon(label: tr("agents.footer.settings"), active: false,
                       action: openSettings) { ToolGlyph(symbol: "gearshape") }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FooterIcon<Glyph: View>: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @ViewBuilder var glyph: () -> Glyph
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph()
                .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textTertiary)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(NookTheme.rowFill(selected: active, hovering: hovering, rest: .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Two nodes joined by a line, and a third one the line bends to: the pull request mark, drawn in the same line weight
/// as the rest of the list.
private struct PullRequestGlyph: View {
    var body: some View { PullRequestStateGlyph(glyph: .open) }
}

/// The pull request marks GitHub uses, drawn on a 16-point grid so they stay crisp at any size: open (a node, a line,
/// and a second line that bends back with an arrow), draft (the bend replaced by dots), merged (a branch curving back
/// into the main line), closed (the arrow replaced by a cross), a conflict (an exclamation mark beside the line) and a
/// stack (three nodes in a chain).
struct PullRequestStateGlyph: View {
    let glyph: PullRequestBadge.Glyph
    var size: CGFloat = 16
    /// In grid units; a small glyph wants a heavier line to read as the same weight.
    var lineWidth: CGFloat = 1.3
    var nodeRadius: CGFloat = 1.6

    var body: some View {
        Canvas { context, canvas in
            let unit = min(canvas.width, canvas.height) / 16
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            let style = StrokeStyle(lineWidth: lineWidth * unit, lineCap: .round, lineJoin: .round)
            let r = nodeRadius
            var lines = Path()
            var nodes: [CGPoint] = []
            var dots: [CGPoint] = []

            func trunk() {
                lines.move(to: point(4, 3.6 + r)); lines.addLine(to: point(4, 12.4 - r))
                nodes += [point(4, 3.6), point(4, 12.4)]
            }

            switch glyph {
            case .open:
                trunk()
                lines.move(to: point(12, 12.4 - r)); lines.addLine(to: point(12, 7))
                lines.addQuadCurve(to: point(10, 4.8), control: point(12, 4.8))
                lines.addLine(to: point(8.6, 4.8))
                lines.move(to: point(10.2, 3.2)); lines.addLine(to: point(8.6, 4.8)); lines.addLine(to: point(10.2, 6.4))
                nodes.append(point(12, 12.4))
            case .draft:
                trunk()
                lines.move(to: point(12, 12.4 - r)); lines.addLine(to: point(12, 8.6))
                nodes.append(point(12, 12.4))
                dots += [point(12, 6), point(12, 3.4)]
            case .closed:
                trunk()
                lines.move(to: point(12, 12.4 - r)); lines.addLine(to: point(12, 8.2))
                lines.move(to: point(10.2, 2.8)); lines.addLine(to: point(13.8, 6.4))
                lines.move(to: point(13.8, 2.8)); lines.addLine(to: point(10.2, 6.4))
                nodes.append(point(12, 12.4))
            case .conflict:
                trunk()
                lines.move(to: point(12, 2.8)); lines.addLine(to: point(12, 9))
                dots.append(point(12, 12.6))
            case .merged:
                trunk()
                lines.move(to: point(4, 3.6 + r))
                lines.addQuadCurve(to: point(12 - r, 9.6), control: point(4, 9.6))
                nodes.append(point(12, 9.6))
            case .stack:
                nodes += [point(3.6, 12.4), point(8, 8), point(12.4, 3.6)]
                let step = r * 0.7071
                lines.move(to: point(3.6 + step, 12.4 - step)); lines.addLine(to: point(8 - step, 8 + step))
                lines.move(to: point(8 + step, 8 - step)); lines.addLine(to: point(12.4 - step, 3.6 + step))
            }

            context.stroke(lines, with: .foreground, style: style)
            for center in nodes {
                let node = Path(ellipseIn: CGRect(x: center.x - r * unit, y: center.y - r * unit, width: 2 * r * unit, height: 2 * r * unit))
                context.stroke(node, with: .foreground, style: style)
            }
            let dot = lineWidth * 0.75
            for center in dots {
                context.fill(Path(ellipseIn: CGRect(x: center.x - dot * unit, y: center.y - dot * unit, width: 2 * dot * unit, height: 2 * dot * unit)),
                             with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A tool's symbol at the size of the drawn glyphs beside it.
private struct ToolGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .regular))
            .frame(width: 16, height: 16)
    }
}

/// Three bars of different height.
private struct UsageGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 16
            let style = StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round)
            var bars = Path()
            for (x, top) in [(3.5, 9.0), (8.0, 3.0), (12.5, 6.0)] as [(CGFloat, CGFloat)] {
                bars.move(to: CGPoint(x: x * unit, y: 13.5 * unit))
                bars.addLine(to: CGPoint(x: x * unit, y: top * unit))
            }
            context.stroke(bars, with: .foreground, style: style)
        }
        .frame(width: 16, height: 16)
    }
}
