import SwiftUI

/// The agent, its account and the model in one menu, the same when you start a session and while you talk to one
/// (model picker): every connected agent with its accounts, the models of the chosen agent below. In a running
/// session a model counts from the next turn, and another account or agent moves the session there with a summary of what
/// happened, shown in the timeline.
struct AgentPickerMenu: View {
    @EnvironmentObject private var app: AppModel
    let provider: RunProvider
    let profileID: String
    let model: String
    /// The model the agent said it ran, for the tooltip.
    var resolvedModel: String? = nil
    var disabled = false
    let pickAccount: (RunProvider, AgentProfile) -> Void
    let pickModel: (String) -> Void

    var body: some View {
        let profile = app.profiles.profile(id: profileID)
        let name = profile.map { AccountLabel.name($0, app: app) }
        let modelName = model.isEmpty ? nil : app.modelName(model, for: provider)
        Menu {
            // Only agents and accounts you connected; the rest would only clutter the choice.
            if app.connectedProviders.isEmpty {
                Text(tr("agents.noneConnected"))
            }
            ForEach(app.connectedProviders) { candidate in
                Section(candidate.displayName) {
                    ForEach(app.connectedProfiles(for: candidate)) { account in
                        Button {
                            pickAccount(candidate, account)
                        } label: {
                            if candidate == provider && account.id == profileID {
                                Label(AccountLabel.line(account, app: app), systemImage: "checkmark")
                            } else {
                                Text(AccountLabel.line(account, app: app))
                            }
                        }
                    }
                }
            }
            Divider()
            Section(tr("ws.new.model")) {
                ForEach(app.models(for: provider), id: \.self) { option in
                    Button {
                        pickModel(option)
                    } label: {
                        let title = app.modelName(option, for: provider)
                        if model == option { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
        } label: {
            ComposerPill(agent: provider.displayName, account: profile.map { AccountKind.of($0, app: app) },
                         text: [provider.displayName, name, modelName].compactMap { $0 }.joined(separator: " · "))
        }
        .composerMenu()
        .disabled(disabled)
        .help(resolvedModel ?? tr("ws.new.model"))
    }
}
