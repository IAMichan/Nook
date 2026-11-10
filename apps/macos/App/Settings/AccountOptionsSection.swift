import SwiftUI

/// What lets you set per provider instance, for any agent account in Settings › Agents: the switch that turns it
/// off, the program it runs, the arguments added to every launch, the environment variables it runs with, and the models
/// that no list offers. Folded away under "Advanced", because most accounts need none of it.
struct AccountOptionsSection: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile

    @State private var program = ""
    @State private var arguments = ""
    @State private var models = ""
    @State private var rows: [VariableRow] = []
    @State private var loaded = false

    private var current: AgentProfile { app.profiles.profile(id: profile.id) ?? profile }

    var body: some View {
        SheetPart(tr("accounts.enabled")) {
            SettingToggle(tr("accounts.enabled.toggle"), detail: tr("accounts.enabled.help"),
                          isOn: Binding(get: { current.isEnabled }, set: { app.profiles.setEnabled(profile.id, $0) }))
        }
        SheetPart(tr("accounts.advanced")) {
            DisclosureGroup(tr("accounts.advanced.fold")) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    field(tr("accounts.program"), help: tr("accounts.program.help", profile.kind.command)) {
                        HStack {
                            TextField(app.history.executables[profile.kind] ?? profile.kind.command, text: $program)
                                .textFieldStyle(.roundedBorder)
                                .font(NookTheme.TextStyle.code)
                                .onSubmit(saveProgram)
                            Button(tr("accounts.program.choose"), action: chooseProgram)
                        }
                    }
                    field(tr("accounts.arguments"), help: tr("accounts.arguments.help")) {
                        lines($arguments, onChange: { app.profiles.setExtraArguments(profile.id, Self.split($0)) })
                    }
                    field(tr("accounts.variables"), help: tr("accounts.variables.help")) { variablesView }
                    field(tr("accounts.models"), help: tr("accounts.models.help")) {
                        lines($models, onChange: { app.profiles.setCustomModels(profile.id, Self.split($0)) })
                    }
                }
                .padding(.top, NookTheme.Spacing.sm)
            }
        }
        .onAppear(perform: load)
        .onDisappear { saveProgram(); saveVariables() }
    }

    // MARK: Parts

    private func field<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(title).font(NookTheme.TextStyle.strong)
            content()
            SettingNote(help)
        }
    }

    /// One entry per line, saved as you type.
    private func lines(_ text: Binding<String>, onChange: @escaping (String) -> Void) -> some View {
        TextEditor(text: text)
            .font(NookTheme.TextStyle.code)
            .scrollContentBackground(.hidden)
            .padding(NookTheme.Spacing.xs)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.smoke))
            .onChange(of: text.wrappedValue) { onChange($0) }
    }

    private var variablesView: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach($rows) { $row in
                HStack(spacing: NookTheme.Spacing.sm) {
                    TextField(tr("accounts.variables.name"), text: $row.name)
                        .textFieldStyle(.roundedBorder)
                        .font(NookTheme.TextStyle.code)
                        .frame(maxWidth: 180)
                    if row.sensitive {
                        SecureField(row.hasStoredValue ? tr("accounts.variables.stored") : tr("accounts.variables.value"), text: $row.value)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(tr("accounts.variables.value"), text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .font(NookTheme.TextStyle.code)
                    }
                    Toggle(isOn: $row.sensitive) { Image(icon: "key.fill") }
                        .toggleStyle(.button)
                        .help(tr("accounts.variables.secret"))
                    Button { rows.removeAll { $0.id == row.id }; saveVariables() } label: { Image(icon: "minus.circle") }
                        .buttonStyle(.plain)
                        .help(tr("accounts.variables.remove"))
                        .accessibilityLabel(tr("accounts.variables.remove"))
                }
                .onSubmit(saveVariables)
            }
            HStack {
                Button { rows.append(VariableRow()) } label: { Label(tr("accounts.variables.add"), systemImage: "plus") }
                    .controlSize(.small)
                Spacer()
                Button(tr("button.save"), action: saveVariables).controlSize(.small)
            }
            if let clash = clashing {
                SettingNote(tr("accounts.variables.clash", clash), tone: .error)
            }
        }
    }

    /// A variable Nook sets itself for this account, which yours cannot replace.
    private var clashing: String? {
        guard let name = current.kind.homeVariable, current.home != nil else { return nil }
        return rows.contains { $0.name == name } ? name : nil
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        program = current.executablePath ?? ""
        arguments = (current.extraArguments ?? []).joined(separator: "\n")
        models = (current.customModels ?? []).joined(separator: "\n")
        rows = current.activeVariables.map {
            VariableRow(name: $0.name, value: $0.sensitive ? "" : $0.value, sensitive: $0.sensitive,
                        hasStoredValue: $0.sensitive && !app.profiles.value(of: $0, for: current).isEmpty)
        }
    }

    private func saveProgram() {
        guard loaded else { return }
        app.profiles.setExecutablePath(profile.id, program)
        app.history.refresh(minimumInterval: 0)
    }

    private func saveVariables() {
        guard loaded else { return }
        app.profiles.setVariables(profile.id, rows.filter { !$0.name.isEmpty }.map {
            AccountVariable(name: $0.name, value: $0.value, sensitive: $0.sensitive)
        })
        // A typed secret now lives in the Keychain; the field shows that instead of the value.
        for index in rows.indices where rows[index].sensitive && !rows[index].value.isEmpty {
            rows[index].value = ""
            rows[index].hasStoredValue = true
        }
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        program = url.path
        saveProgram()
    }

    /// Non-empty lines, trimmed.
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    struct VariableRow: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
        var sensitive = false
        var hasStoredValue = false
    }
}
