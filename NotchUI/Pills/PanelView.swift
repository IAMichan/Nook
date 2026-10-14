import SwiftUI

/// Het uitgeklapte paneel met vier tabs. De tabbalk staat altijd bovenaan.
struct PanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    @Namespace private var underline

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .id(tab)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(PanelTab.allCases) { t in
                    Button {
                        viewModel.show(.panel(t))
                    } label: {
                        Text(t.title)
                            .font(NookTheme.font(13.5, .medium))
                            .foregroundStyle(t == tab ? NookTheme.paper : NookTheme.textTertiary)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                if t == tab {
                                    Rectangle()
                                        .fill(NookTheme.paper)
                                        .frame(height: 1.5)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                NookIconButton(systemName: "mic", label: "Praat met Nook") { viewModel.startListening() }
                NookIconButton(systemName: "gearshape", label: "Instellingen") { viewModel.app?.openSettings() }
                NookIconButton(systemName: "xmark", label: "Sluiten") { viewModel.show(.idle) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nook: NookTab(viewModel: viewModel)
        case .agents: AgentsTab(viewModel: viewModel)
        case .connect: ConnectTab(viewModel: viewModel)
        case .music: MusicTab()
        case .shelf: ShelfTab()
        }
    }
}
