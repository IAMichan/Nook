import SwiftUI

/// The expanded panel: Nook (home and chat in one), Agents, and Music while something plays.
struct PanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    @Namespace private var underline
    @ObservedObject private var settings = AppSettings.shared
    private var large: Bool { settings.panelLarge }

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
                ForEach(PanelTab.visible(musicAvailable: viewModel.app?.nowPlaying.current != nil || tab == .music)) { t in
                    Button {
                        viewModel.show(.panel(t))
                    } label: {
                        HStack(spacing: 6) {
                            Text(t.title)
                                .font(NookTheme.font(13.5, .medium))
                                .foregroundStyle(t == tab ? NookTheme.paper : NookTheme.textTertiary)
                            if t == .chat, viewModel.app?.chat.anyBusy == true {
                                Circle()
                                    .fill(NookTheme.iris)
                                    .frame(width: 5, height: 5)
                            }
                        }
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
                NookIconButton(systemName: "mic", label: tr("button.talk")) { viewModel.startListening() }
                NookIconButton(
                    systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: tr(large ? "button.shrink" : "button.enlarge")
                ) {
                    AppSettings.shared.panelLarge.toggle()
                    viewModel.show(.panel(tab))
                }
                NookIconButton(systemName: "gearshape", label: tr("button.settings")) { viewModel.app?.openSettings() }
                NookIconButton(systemName: "xmark", label: tr("button.close")) { viewModel.show(.idle) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nook, .chat, .connect, .shelf: NookChatTab(viewModel: viewModel)
        case .agents: AgentsTab(viewModel: viewModel)
        case .music: MusicTab()
        }
    }
}
