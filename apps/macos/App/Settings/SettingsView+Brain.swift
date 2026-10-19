import SwiftUI
import AppKit

/// Settings › Brain: local-first model choice, advice, external AI.
extension SettingsView {
    // MARK: Brain

    enum BrainKind: Hashable { case local, external }
    enum LocalRuntime: Hashable { case builtIn, ollama, lmstudio }
    enum ExternalKind: Hashable { case claude, other }

    /// Local first: the built-in model, Ollama and LM Studio all keep everything on the Mac. External is a deliberate choice.
    var brainKind: Binding<BrainKind> {
        Binding(
            get: { settings.isLocalBrain ? .local : .external },
            set: { kind in
                testResult = nil
                fetchedModels = []
                switch kind {
                case .local:
                    if !settings.isLocalBrain { settings.useLocal = true }
                case .external:
                    settings.useLocal = false
                    if settings.provider.isLocalServer { settings.provider = .claude }
                }
            }
        )
    }

    var localRuntime: Binding<LocalRuntime> {
        Binding(
            get: { settings.useLocal ? .builtIn : (settings.provider == .ollama ? .ollama : .lmstudio) },
            set: { runtime in
                testResult = nil
                fetchedModels = []
                switch runtime {
                case .builtIn: settings.useLocal = true
                case .ollama: settings.useLocal = false; settings.provider = .ollama
                case .lmstudio: settings.useLocal = false; settings.provider = .lmstudio
                }
            }
        )
    }

    var externalKind: Binding<ExternalKind> {
        Binding(
            get: { [.claude, .claudeCode].contains(settings.provider) ? .claude : .other },
            set: { kind in
                testResult = nil
                fetchedModels = []
                switch kind {
                case .claude: if settings.provider != .claudeCode { settings.provider = .claude }
                case .other: if [.claude, .claudeCode].contains(settings.provider) || settings.provider.isLocalServer { settings.provider = .openai }
                }
            }
        )
    }

    var brainSection: some View {
        Group {
            Section {
                Picker(tr("settings.brain.where"), selection: brainKind) {
                    Text(tr("settings.brain.localChoice")).tag(BrainKind.local)
                    Text(tr("settings.brain.externalChoice")).tag(BrainKind.external)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.isLocalBrain ? tr("settings.brain.localDefault") : tr("settings.brain.externalWarning"))
            }

            if settings.isLocalBrain {
                Section(tr("brain.advice.title")) { adviceRows }
                Section {
                    Picker(tr("settings.brain.localRuntime"), selection: localRuntime) {
                        Text(tr("settings.brain.builtIn")).tag(LocalRuntime.builtIn)
                        Text("Ollama").tag(LocalRuntime.ollama)
                        Text("LM Studio").tag(LocalRuntime.lmstudio)
                    }
                    .pickerStyle(.segmented)
                    if settings.useLocal { localFields } else { providerFields }
                }
            } else {
                Section {
                    Picker(tr("settings.brain.thinksWith"), selection: externalKind) {
                        Text(tr("settings.brain.claude")).tag(ExternalKind.claude)
                        Text(tr("settings.brain.otherAI")).tag(ExternalKind.other)
                    }
                    .pickerStyle(.segmented)
                    providerFields
                } footer: {
                    Text(brainExplanation)
                }
            }

            if settings.brainProfile.isSmall { LocalQualitySection(settings: settings) }

            Section {
                HStack {
                    Button(tr("button.testConnection")) { Task { await testConnection() } }
                        .disabled(!settings.brainReady || testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let result = testResult {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(result.ok ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            }

            // The answer language and the sources kept on this Mac have one home each: General and Privacy.
            Section {
                settingsLink(.general, title: tr("settings.brain.answerLanguage"), detail: tr("settings.brain.languageMoved"))
                settingsLink(.privacy, title: tr("settings.private.title"), detail: tr("settings.brain.privateMoved"))
            }
        }
        .task { recommendations = await app.brainRecommendations() }
    }

    /// The models Nook proposes for this Mac, best first, with one button to use or install each.
    var adviceRows: some View {
        Group {
            Text(tr("brain.advice.memory", EmbeddedModel.memoryGB))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(recommendations.prefix(3).enumerated()), id: \.offset) { index, recommendation in
                HStack(alignment: .firstTextBaseline) {
                    ModelLogo(name: AppModel.title(of: recommendation))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(AppModel.title(of: recommendation)).fontWeight(index == 0 ? .semibold : .regular)
                            if index == 0, recommendation.choice != .unavailable {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            }
                        }
                        Text(recommendation.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    adviceButton(recommendation)
                }
            }
        }
    }

    @ViewBuilder
    func adviceButton(_ recommendation: ModelAdvisor.Recommendation) -> some View {
        switch recommendation.choice {
        case .unavailable:
            EmptyView()
        case .mlx(let option) where installing == option.id:
            ProgressView(value: installFraction).frame(width: 90)
        case .mlx(let option) where settings.useLocal && settings.localModel == option.id:
            Label(tr("brain.advice.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .server(let model) where !settings.useLocal && settings.activeProviderModel == model.name
                && settings.provider == (model.server == .ollama ? .ollama : .lmstudio):
            Label(tr("brain.advice.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .mlx(let option) where !recommendation.ready:
            Button(tr("brain.advice.install")) { Task { await install(option.id) } }
                .disabled(installing != nil)
        default:
            Button(tr("brain.advice.use")) {
                Task {
                    try? await app.useRecommendation(recommendation)
                    testResult = nil
                }
            }
        }
    }

    var brainExplanation: String {
        if [.claude, .claudeCode].contains(settings.provider) {
            return tr("settings.brain.claudeExplanation")
        }
        return tr("settings.brain.otherExplanation")
    }

    var providerFields: some View {
        Group {
            if settings.provider.isLocalServer {
                EmptyView()
            } else if [.claude, .claudeCode].contains(settings.provider) {
                Picker(tr("settings.brain.connectVia"), selection: $settings.provider) {
                    Text(tr("settings.brain.apiKey")).tag(AIProvider.claude)
                    Text(tr("settings.brain.claudeCodeSub")).tag(AIProvider.claudeCode)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.provider) { _, _ in testResult = nil }
            } else {
                Picker(tr("settings.brain.provider"), selection: $settings.provider) {
                    ForEach(AIProvider.allCases.filter { $0 != .claude && $0 != .claudeCode && !$0.isLocalServer }) { provider in
                        Label { Text(provider.title) } icon: { LogoImage.brand(BrandLogo.forProvider(provider)) }.tag(provider)
                    }
                }
                .onChange(of: settings.provider) { _, _ in
                    fetchedModels = []
                    testResult = nil
                }
            }

            if settings.provider == .claudeCode {
                claudeCodeStatus
            } else if settings.provider.needsKey {
                HStack {
                    SecureField(settings.provider.keyPlaceholder, text: $keyDraft)
                        .onSubmit(saveKey)
                    Button(tr("button.save"), action: saveKey)
                        .disabled(keyDraft.isEmpty && !settings.hasKey(for: settings.provider))
                }
                HStack {
                    if settings.hasKey(for: settings.provider) {
                        Label(settings.provider == .claude ? "\(tr("settings.brain.keyInKeychain")): \(settings.maskedKey ?? "")" : tr("settings.brain.keyInKeychain"), systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tr("settings.brain.keyStaysInKeychain")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = settings.provider.keyURL {
                        Link(tr("settings.brain.createKey"), destination: url).font(.caption)
                    }
                }
            } else if let url = settings.provider.keyURL {
                HStack {
                    Text(tr("settings.brain.providerMustRun", settings.provider.title)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link(tr("button.download"), destination: url).font(.caption)
                }
            }

            HStack {
                TextField(tr("settings.brain.model"), text: Binding(
                    get: { settings.activeProviderModel },
                    set: { settings.setProviderModel($0) }
                ))
                Menu(tr("button.choose")) {
                    let models = fetchedModels.isEmpty ? settings.provider.suggestedModels : fetchedModels
                    ForEach(models, id: \.self) { id in
                        Button { settings.setProviderModel(id) } label: {
                            Label { Text(id) } icon: { LogoImage.brand(BrandLogo.forName(id) ?? BrandLogo.forProvider(settings.provider)) }
                        }
                    }
                    Divider()
                    Button(tr("button.fetchModels")) { Task { await fetchModels() } }
                }
                .fixedSize()
                if fetchingModels { ProgressView().controlSize(.small) }
                if !settings.provider.seesImages(model: settings.activeProviderModel) { NoImagesBadge() }
            }
            if settings.provider == .claude {
                Text(tr("settings.brain.haikuHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Claude Code detected? Nothing left to do except test.
    var claudeCodeStatus: some View {
        let _ = refreshTick
        let path = ClaudeCodeBrain.executable
        return VStack(alignment: .leading, spacing: 6) {
            if let path {
                Label(tr("settings.brain.claudeFound", path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(tr("settings.brain.claudeLoginHint"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(tr("settings.brain.claudeNotFound"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(tr("settings.brain.claudeInstallHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button(tr("button.searchAgain")) { ClaudeCodeBrain.resetLocation(); refreshTick += 1; settings.objectWillChange.send() }
                    if let url = settings.provider.keyURL { Link(tr("settings.brain.moreAboutClaudeCode"), destination: url) }
                }
            }
        }
    }

    func fetchModels() async {
        fetchingModels = true
        defer { fetchingModels = false }
        do {
            let key = settings.provider == .claude ? settings.apiKey : settings.providerKey
            fetchedModels = try await settings.provider.listModels(key: key)
            status = fetchedModels.isEmpty ? tr("settings.brain.noModelsFound") : tr("settings.brain.modelsFound", fetchedModels.count)
        } catch {
            status = error.localizedDescription
        }
    }

    var localFields: some View {
        Group {
            // Apple's own model: already on the Mac (macOS 26 with Apple Intelligence on), nothing to download.
            if AppleIntelligence.status != .unsupported {
                HStack {
                    ModelLogo(name: "Apple")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppleModel.title)
                        Text(AppleIntelligence.isAvailable ? tr("brain.apple.detail") : AppleIntelligence.unavailableReason)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if settings.localModel == AppleModel.id {
                        Label(tr("settings.brain.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if AppleIntelligence.isAvailable {
                        Button(tr("settings.brain.use")) { settings.localModel = AppleModel.id; testResult = nil }
                    }
                }
            }
            ForEach(EmbeddedModel.options) { option in
                HStack {
                    ModelLogo(name: option.title + " " + option.id)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(option.title)
                            if !option.seesImages { NoImagesBadge() }
                        }
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installing == option.id {
                        ProgressView(value: installFraction).frame(width: 90)
                        Text("\(Int(installFraction * 100))%").font(.caption.monospacedDigit())
                    } else if local.installed.contains(option.id) {
                        if settings.localModel == option.id {
                            Label(tr("settings.brain.inUse"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(tr("settings.brain.use")) { settings.localModel = option.id; testResult = nil }
                        }
                    } else if !option.fits {
                        Text(tr("settings.brain.tooHeavyForMemory", EmbeddedModel.memoryGB)).font(.caption).foregroundStyle(.orange)
                    } else {
                        Button(tr("button.download")) { Task { await install(option.id) } }
                            .disabled(installing != nil)
                    }
                }
            }
            Text(tr("settings.brain.localModelDownloadHint", EmbeddedModel.memoryGB))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func install(_ id: String) async {
        guard installing == nil else { return }
        installing = id
        installFraction = 0
        testResult = nil
        defer { installing = nil }
        do {
            try await local.install(id) { fraction in
                Task { @MainActor in installFraction = fraction }
            }
            settings.useLocal = true
            settings.localModel = id
            recommendations = await app.brainRecommendations()
            status = "\(local.title(for: id)) is ready and currently active."
            await testConnection()
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }

    func saveKey() {
        let provider = settings.provider
        if provider == .claude {
            if !keyDraft.isEmpty {
                let saved = settings.saveAPIKey(keyDraft)
                keyDraft = ""
                if !saved.looksValid {
                    testResult = (false, "This does not look like an Anthropic key: it should start with sk-ant-. Testing anyway.")
                }
                status = saved.keychainError.map { "Keychain rejected the key (\($0)). It will only work until Nook quits." } ?? "Key saved in Keychain."
            } else {
                settings.saveAPIKey("")
                testResult = nil
                status = "Key removed."
                return
            }
        } else {
            let error = settings.saveProviderKey(keyDraft, for: provider)
            let removed = keyDraft.isEmpty
            keyDraft = ""
            status = error ?? (removed ? "Key removed." : "Key saved in Keychain.")
            if removed { return }
        }
        Task { await testConnection() }
    }

    func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await app.brain.test()
            testResult = (true, "Verbonden met \(settings.activeModelName). Antwoord: “\(reply)”")
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}

/// The maker's mark of a model in a settings row, or a plain chip when we don't know the maker.
private struct ModelLogo: View {
    let name: String

    var body: some View {
        Group {
            if let logo = BrandLogo.forName(name) {
                BrandMark(logo: logo, size: 18)
            } else {
                Image(systemName: "cpu").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 22)
    }
}

/// A small crossed-out eye next to a model that cannot read pictures; the tooltip explains it.
struct NoImagesBadge: View {
    var body: some View {
        Image(systemName: "eye.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(tr("brain.noImages.help"))
            .accessibilityLabel(tr("brain.noImages.help"))
    }
}
