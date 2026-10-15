import SwiftUI

/// The Workspace tab in the notch: terminals, the browser and worktrees, without opening another window.
/// One quiet row of tools, the tool itself below it.
struct NotchWorkspaceTab: View {
    @AppStorage("workbench.tool") private var tool: WorkbenchView.Tool = .terminals

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(WorkbenchView.Tool.allCases) { item in
                    ToolPill(title: item.title, symbol: item.symbol, selected: item == tool) { tool = item }
                }
                Spacer(minLength: 0)
            }
            Group {
                switch tool {
                case .terminals: TerminalsView()
                case .browser: BrowserView()
                case .worktrees: WorktreesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.field))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NookTheme.line2.opacity(0.6), lineWidth: 1))
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookWorkbenchTool)) { note in
            if let raw = note.object as? String, let target = WorkbenchView.Tool(rawValue: raw) { tool = target }
        }
    }
}

/// A calm segmented choice: text with a soft background only on the selected one.
struct ToolPill: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(NookTheme.font(12.5, .medium))
            }
            .foregroundStyle(selected ? NookTheme.paper : (hovering ? NookTheme.textSecondary : NookTheme.textTertiary))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(selected ? NookTheme.smoke : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
