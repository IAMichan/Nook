import SwiftUI

/// Settings › Instructions: how Nook words its answers (the default style; each conversation can pick its own), the
/// prompts you saved, the spaces with their instructions, and the context inspector that shows what the last answer
/// sent to the model and how big it was. A new prompt or space is added from its list's header, in a sheet.
struct InstructionsSettingsSection: View {
    @ObservedObject private var store = InstructionStore.shared
    @State private var style = ResponseStyleStore.shared.defaultStyle

    @State private var addingPrompt = false
    @State private var addingSpace = false

    var body: some View {
        Group {
            styleSection
            promptsSection
            spacesSection
            inspectorSection
        }
    }

    // MARK: Style

    private var styleSection: some View {
        Section {
            Picker(tr("instructions.style.default"), selection: $style) {
                ForEach(ResponseStyle.allCases) { Text(tr("instructions.style." + $0.rawValue)).tag($0) }
            }
            .onChange(of: style) { _, value in ResponseStyleStore.shared.defaultStyle = value }
            SettingNote(tr("instructions.style.detail"))
        } header: {
            SettingsSectionTitle(tr("instructions.style.title"))
        }
    }

    // MARK: Saved prompts

    private var promptsSection: some View {
        Section {
            if store.prompts.prompts.isEmpty {
                ConnectionListEmpty(title: tr("instructions.prompts.empty"), detail: tr("instructions.prompts.emptyDetail"))
            }
            ForEach(store.prompts.prompts) { prompt in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(prompt.title)
                        Text((prompt.trigger.isEmpty ? "" : "/" + prompt.trigger + "  ") + prompt.body)
                            .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(2)
                    }
                    Spacer()
                    ConfirmedButton(symbol: "trash", title: tr("instructions.delete"), question: tr("confirm.remove", prompt.title)) {
                        store.removePrompt(prompt.id)
                    }
                    .labelled(tr("instructions.delete"))
                }
            }
        } header: {
            ConnectionListHeader(title: tr("instructions.prompts.title"), info: tr("instructions.prompts.detail"),
                                 add: (tr("instructions.prompts.new"), { addingPrompt = true }))
        }
        .sheet(isPresented: $addingPrompt) { AddPromptSheet() }
    }

    // MARK: Spaces

    private var spacesSection: some View {
        Section {
            if store.spaces.spaces.isEmpty {
                ConnectionListEmpty(title: tr("instructions.spaces.emptyTitle"), detail: tr("instructions.spaces.empty"))
            }
            ForEach(store.spaces.spaces) { space in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    HStack {
                        Text(space.name).font(NookTheme.TextStyle.strong)
                        Text(tr("instructions.spaces.count", store.spaces.conversations(in: space.id).count))
                            .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                        Spacer()
                        ConfirmedButton(symbol: "trash", title: tr("instructions.delete"), question: tr("confirm.remove", space.name)) {
                            store.removeSpace(space.id)
                        }
                        .labelled(tr("instructions.delete"))
                    }
                    TextField(tr("instructions.spaces.instructions"), text: instructions(of: space), axis: .vertical).lineLimit(2...8)
                }
            }
        } header: {
            ConnectionListHeader(title: tr("instructions.spaces.title"), info: tr("instructions.spaces.detail"),
                                 add: (tr("instructions.spaces.add"), { addingSpace = true }))
        }
        .sheet(isPresented: $addingSpace) { AddSpaceSheet() }
    }

    private func instructions(of space: NookSpace) -> Binding<String> {
        Binding(get: { store.spaces.spaces.first { $0.id == space.id }?.instructions ?? "" },
                set: { value in
                    guard var current = store.spaces.spaces.first(where: { $0.id == space.id }) else { return }
                    current.instructions = value
                    store.saveSpace(current)
                })
    }

    // MARK: Context inspector

    private var inspectorSection: some View {
        Section {
            if let context = store.lastContext {
                ForEach(context.parts) { part in
                    DisclosureGroup {
                        Text(part.text.count > 4_000 ? String(part.text.prefix(4_000)) + "…" : part.text)
                            .font(NookTheme.TextStyle.code).foregroundStyle(NookTheme.textSecondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack {
                            Text(tr("instructions.context.part." + part.kind.rawValue))
                            Spacer()
                            Text(tr("instructions.context.tokens", part.tokens))
                                .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                }
                LabeledContent(tr("instructions.context.total")) {
                    let fill = context.fill.map { " · " + String(Int(($0 * 100).rounded())) + "%" } ?? ""
                    Text(tr("instructions.context.tokens", context.totalTokens) + fill).foregroundStyle(NookTheme.textSecondary)
                }
            } else {
                SettingNote(tr("instructions.context.empty"))
            }
            SettingNote(tr("instructions.context.detail"))
        } header: {
            SettingsSectionTitle(tr("instructions.context.title"))
        }
    }
}

/// A new saved prompt: its name, the trigger that fills it in, and its text. A form, so Cancel and Save.
private struct AddPromptSheet: View {
    @State private var title = ""
    @State private var trigger = ""
    @State private var text = ""
    @State private var rejected = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SetupSheet(title: tr("instructions.prompts.sheetTitle"), subtitle: tr("instructions.prompts.detail")) {
            SettingsTile(.instructions, size: 40)
        } content: {
            Text(tr("instructions.prompts.name")).font(NookTheme.TextStyle.strong)
            TextField("", text: $title).settingsField()
            Text(tr("instructions.form.trigger")).font(NookTheme.TextStyle.strong)
            TextField("", text: $trigger, prompt: Text(tr("instructions.prompts.trigger")).foregroundStyle(NookTheme.textTertiary)).settingsField()
                .font(NookTheme.TextStyle.code)
            Text(tr("instructions.form.prompt")).font(NookTheme.TextStyle.strong)
            TextField("", text: $text, prompt: Text(tr("instructions.prompts.body")).foregroundStyle(NookTheme.textTertiary), axis: .vertical)
                .settingsField()
                .lineLimit(4...10)
            if rejected { SettingNote(tr("instructions.prompts.rejected"), tone: .warning) }
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .sheetCancelButton()
            Button(tr("instructions.prompts.add"), action: save)
                .sheetPrimaryButton()
                .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard canSave else { return }
        let prompt = SavedPrompt(title: title, body: text, trigger: trigger)
        rejected = !InstructionStore.shared.savePrompt(prompt)
        if !rejected {
            ToastCenter.shared.success(tr("connection.added", prompt.title))
            dismiss()
        }
    }
}

/// A new space: its name and the instructions sent with every question in it. A form, so Cancel and Add.
private struct AddSpaceSheet: View {
    @State private var name = ""
    @State private var instructions = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SetupSheet(title: tr("instructions.spaces.sheetTitle"), subtitle: tr("instructions.spaces.detail")) {
            SettingsTile(.instructions, size: 40)
        } content: {
            Text(tr("instructions.prompts.name")).font(NookTheme.TextStyle.strong)
            TextField("", text: $name, prompt: Text(tr("instructions.spaces.name")).foregroundStyle(NookTheme.textTertiary)).settingsField()
            Text(tr("instructions.form.instructions")).font(NookTheme.TextStyle.strong)
            TextField("", text: $instructions, prompt: Text(tr("instructions.spaces.instructions")).foregroundStyle(NookTheme.textTertiary), axis: .vertical)
                .settingsField()
                .lineLimit(4...10)
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .sheetCancelButton()
            Button(tr("instructions.spaces.add"), action: save)
                .sheetPrimaryButton()
                .disabled(cleanName.isEmpty)
        }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() {
        guard !cleanName.isEmpty else { return }
        var space = NookSpace(name: cleanName)
        space.instructions = instructions
        InstructionStore.shared.saveSpace(space)
        ToastCenter.shared.success(tr("connection.added", cleanName))
        dismiss()
    }
}
