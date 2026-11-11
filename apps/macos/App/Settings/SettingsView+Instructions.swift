import SwiftUI

/// Settings › Instructions: how Nook words its answers (the default style; each conversation can pick its own), the
/// prompts you saved, the spaces with their instructions, and the context inspector that shows what the last answer
/// sent to the model and how big it was.
struct InstructionsSettingsSection: View {
    @ObservedObject private var store = InstructionStore.shared
    @State private var style = ResponseStyleStore.shared.defaultStyle

    @State private var promptTitle = ""
    @State private var promptTrigger = ""
    @State private var promptBody = ""
    @State private var promptRejected = false
    @State private var spaceName = ""

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
            if store.prompts.prompts.isEmpty { SettingNote(tr("instructions.prompts.empty")) }
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
            TextField(tr("instructions.prompts.name"), text: $promptTitle)
            TextField(tr("instructions.prompts.trigger"), text: $promptTrigger)
            TextField(tr("instructions.prompts.body"), text: $promptBody, axis: .vertical).lineLimit(2...6)
            Button(tr("instructions.prompts.add")) {
                let saved = store.savePrompt(SavedPrompt(title: promptTitle, body: promptBody, trigger: promptTrigger))
                promptRejected = !saved
                if saved { promptTitle = ""; promptTrigger = ""; promptBody = "" }
            }
            .disabled(promptTitle.trimmingCharacters(in: .whitespaces).isEmpty || promptBody.trimmingCharacters(in: .whitespaces).isEmpty)
            if promptRejected { SettingNote(tr("instructions.prompts.rejected"), tone: .warning) }
            SettingNote(tr("instructions.prompts.detail"))
        } header: {
            SettingsSectionTitle(tr("instructions.prompts.title"))
        }
    }

    // MARK: Spaces

    private var spacesSection: some View {
        Section {
            if store.spaces.spaces.isEmpty { SettingNote(tr("instructions.spaces.empty")) }
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
            HStack {
                TextField(tr("instructions.spaces.name"), text: $spaceName).onSubmit(addSpace)
                Button(tr("instructions.spaces.add"), action: addSpace)
                    .disabled(spaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            SettingNote(tr("instructions.spaces.detail"))
        } header: {
            SettingsSectionTitle(tr("instructions.spaces.title"))
        }
    }

    private func instructions(of space: NookSpace) -> Binding<String> {
        Binding(get: { store.spaces.spaces.first { $0.id == space.id }?.instructions ?? "" },
                set: { value in
                    guard var current = store.spaces.spaces.first(where: { $0.id == space.id }) else { return }
                    current.instructions = value
                    store.saveSpace(current)
                })
    }

    private func addSpace() {
        store.saveSpace(NookSpace(name: spaceName))
        spaceName = ""
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
