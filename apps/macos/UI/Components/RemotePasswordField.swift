import SwiftUI

/// Unlocks a machine that logs in with a password (see RemotePasswords): one secure field, checked with a real ssh login
/// before Nook keeps the password: in memory for the rest of this run, or also in the Keychain when you tick Keep in
/// Keychain, so it is not asked again after a restart. The new-session composer, a session on that machine, and
/// Settings › Machines all use it, so a password is typed once wherever you meet the machine first.
struct RemotePasswordField: View {
    let machine: RemoteMachine
    var unlocked: (RemoteMachine) -> Void = { _ in }
    @State private var password = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var keep = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: "key.fill").foregroundStyle(NookTheme.textTertiary)
                SecureField(tr("remote.password.placeholder", machine.name), text: $password)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.body)
                    .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                    .frame(minWidth: 160)
                    .frame(height: 30)
                    .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
                    .onSubmit(unlock)
                    .disabled(checking)
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    SmallGhostButton(title: tr("remote.password.unlock"), action: unlock)
                        .disabled(password.isEmpty)
                }
            }
            Toggle(tr("remote.password.keep"), isOn: $keep)
                .toggleStyle(.checkbox)
                .font(NookTheme.TextStyle.caption)
                .disabled(checking)
            Text(problem ?? tr(keep ? "remote.password.note.kept" : "remote.password.note"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(problem == nil ? NookTheme.textTertiary : NookTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One login with the password; only a password that got in is kept.
    private func unlock() {
        guard !password.isEmpty, !checking else { return }
        let typed = password
        let machine = machine
        let keep = keep
        checking = true
        problem = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RemoteShell.check(machine, password: typed, commands: [])
            }.value
            checking = false
            switch result {
            case .success:
                password = ""
                // Not kept in the Keychain (access denied): it still works for this run.
                if !RemotePasswords.shared.set(typed, for: machine.id, keep: keep) {
                    ToastCenter.shared.show(tr("remote.password.keepFailed"), kind: .warning)
                }
                let updated = RemoteMachines.update(id: machine.id) {
                    $0.passwordLogin = true
                    $0.lastUsedAt = Date()
                }
                unlocked(updated ?? machine)
            case .failure(let error):
                problem = error.needsPassword ? tr("remote.password.wrong")
                    : (error.message.isEmpty ? tr("remote.test.failed", Int(error.status)) : error.message)
            }
        }
    }
}
