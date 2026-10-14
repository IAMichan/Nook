import SwiftUI

/// Al je draaiende agents in één blik, met de gekozen agent in detail.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var draft = ""

    var body: some View {
        let sessions = app.agentSessions
        Group {
            if sessions.isEmpty {
                emptyState
            } else {
                content(sessions)
            }
        }
        .onAppear { app.hub.refreshDetected() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ik zie nu geen agent draaien")
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text("Ik zoek op je Mac naar Claude Code, Codex, Gemini CLI, Aider en OpenCode. Start er een in de terminal en hij staat hier binnen tien seconden. Koppel hem via Instellingen › Agents voor voortgang en om te vragen of iets mag.")
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            NookGhostButton(title: "Open instellingen") { app.openSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(_ sessions: [AgentSession]) -> some View {
        let waiting = sessions.filter { $0.status == .waiting }.count
        let selected = sessions.first { $0.id == viewModel.selectedAgentID } ?? sessions[0]

        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sessions.count) actief · \(waiting) wacht op jou")
                    .font(NookTheme.font(11.5, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                ForEach(sessions) { session in
                    AgentRow(session: session, selected: session.id == selected.id) {
                        viewModel.selectedAgentID = session.id
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 220)

            Rectangle().fill(NookTheme.line).frame(width: 1)

            detail(selected)
        }
    }

    private func detail(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name).font(NookTheme.font(15, .semibold)).foregroundStyle(NookTheme.paper)
                + Text("  ·  \(session.project)").font(NookTheme.font(15, .medium)).foregroundStyle(NookTheme.textTertiary)
                Spacer()
                Text(session.status.label)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(session.status.color)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(step.symbol)
                            .foregroundStyle(step.color)
                            .frame(width: 12)
                        Text(step.text)
                            .foregroundStyle(Color(hex: 0xC9C7D2))
                    }
                    .font(NookTheme.font(13))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(session.file)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(session.diff) { line in
                    Text(line.text).foregroundStyle(line.color)
                }
                Spacer(minLength: 0)
            }
            .font(NookTheme.mono(11.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))
            .clipped()

            HStack(spacing: 4) {
                if app.demoMode {
                    if session.status == .waiting {
                        NookPrimaryButton(title: "Toestaan") { viewModel.finish("Toegestaan · npm install draait") }
                        NookGhostButton(title: "Weigeren") { viewModel.show(.idle) }
                    }
                    TextField(
                        "",
                        text: $draft,
                        prompt: Text(session.placeholder).foregroundStyle(NookTheme.textTertiary)
                    )
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(13))
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(NookTheme.field))
                    NookIconButton(systemName: "arrow.up", label: "Versturen", filled: true) { draft = "" }
                } else {
                    Text(session.placeholder)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(NookTheme.font(13.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text("\(session.project) · \(session.status.label)")
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
