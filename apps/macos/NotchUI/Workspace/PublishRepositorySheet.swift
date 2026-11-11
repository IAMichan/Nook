import SwiftUI

/// Publish: puts a local project on GitHub. Says exactly what will happen (a repository made, private unless you change
/// it, `origin` set, the branch pushed) and does nothing until you press Publish; the action log keeps what was made.
struct PublishRepositorySheet: View {
    let plan: PublishPlan
    var done: (URL?) -> Void
    @EnvironmentObject private var workspace: WorkspaceManager
    @State private var name = ""
    @State private var owner = ""
    @State private var isPrivate = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        SetupSheet(title: tr("sc.publish.title"), subtitle: AgentPathFormat.tilde(plan.folder)) {
            NookSymbol("icloud.and.arrow.up", size: 22).foregroundStyle(NookTheme.textSecondary)
        } content: {
            // The steps of every flow that makes something: its name, where it goes, and what Nook will do.
            SetupStep(number: 1, title: tr("sc.publish.name"), done: RepositoryPublish.isValidName(name)) {
                TextField(tr("sc.publish.name"), text: $name, prompt: Text(plan.name))
                    .textFieldStyle(.roundedBorder)
                if !RepositoryPublish.isValidName(name) { SettingNote(tr("sc.publish.badName"), tone: .warning) }
            }
            SetupStep(number: 2, title: tr("sc.publish.where")) {
                Text(tr("sc.publish.owner")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                TextField(tr("sc.publish.owner"), text: $owner, prompt: Text(tr("sc.publish.ownerPrompt")))
                    .textFieldStyle(.roundedBorder)
                Toggle(tr("sc.publish.private"), isOn: $isPrivate)
            }
            SetupCheckStep(number: 3, title: tr("sc.publish.readyTitle"), detail: summary, state: publishState)
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { done(nil) }
                .keyboardShortcut(.cancelAction)
            Button {
                publish()
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text(tr("sc.publish.action")) }
            }
            .buttonStyle(.nookProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(working || !RepositoryPublish.isValidName(name))
        }
        .onAppear { if name.isEmpty { name = plan.name } }
    }

    /// What Nook will do, one line each, in the last step.
    private var summary: String {
        ([tr("sc.publish.steps") + ":"] + steps).joined(separator: "\n")
    }

    /// Publishing is the check: the last step shows it running and why it failed.
    private var publishState: SetupCheckState {
        if working { return .checking }
        if let error { return .failed(error) }
        return .idle
    }

    private var steps: [String] {
        var result: [String] = []
        if plan.needsRepository { result.append(tr("sc.publish.step.init")) }
        if plan.needsFirstCommit { result.append(tr("sc.publish.step.commit")) }
        let target = (owner.trimmingCharacters(in: .whitespaces).isEmpty ? tr("sc.publish.yourAccount") : owner) + "/" + name
        result.append(tr(isPrivate ? "sc.publish.step.createPrivate" : "sc.publish.step.createPublic", target))
        result.append(tr("sc.publish.step.push"))
        return result
    }

    private func publish() {
        working = true
        error = nil
        let owner = owner.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let page = try await workspace.publishRepository(plan, name: name, owner: owner.isEmpty ? nil : owner,
                                                                 isPrivate: isPrivate)
                ToastCenter.shared.success(tr("sc.publish.done"), action: NookToastAction(title: tr("sc.publish.open")) {
                    BrowserStore.show(page)
                })
                done(page)
            } catch let failure {
                error = failure.localizedDescription
            }
            working = false
        }
    }
}
