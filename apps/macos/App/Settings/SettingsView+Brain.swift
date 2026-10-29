import SwiftUI
import AppKit

/// Settings › Brain: local-first model choice, advice, external AI.
extension SettingsView {
    // MARK: Brain

    enum BrainKind: Hashable { case local, external }
    enum LocalRuntime: Hashable { case builtIn, ollama, lmstudio }

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

    /// The online AI in one choice: Claude with a key or your subscription, or any other service. No second picker.
    var externalProvider: Binding<AIProvider> {
        Binding(
            get: { settings.provider.isLocalServer ? .claude : settings.provider },
            set: { provider in
                guard provider != settings.provider else { return }
                testResult = nil
                fetchedModels = []
                settings.provider = provider
            }
        )
    }

    var brainSection: some View {
        Group {
            // What Nook thinks with right now, and the one way to check it works, said once at the top.
            Section {
                StatusRow(title: settings.brainReady ? tr("settings.checklist.brain.ready", settings.activeModelName) : tr("settings.checklist.brain"),
                          // Local or external is the choice right below; the row only explains itself while not ready.
                          detail: settings.brainReady ? "" : tr("settings.checklist.brain.notReady"),
                          state: settings.brainReady ? .done : .todo) {
                    if testing { ProgressView().controlSize(.small) }
                    Button(tr("button.testConnection")) { Task { await testConnection() } }
                        .disabled(!settings.brainReady || testing)
                }
                if let result = testResult {
                    SettingNote(result.message, tone: result.ok ? .success : .error)
                        .textSelection(.enabled)
                }
            }

            // Step 1: on this Mac, or an online service. Each step below follows from the one before it.
            Section {
                Picker(tr("settings.brain.where"), selection: brainKind) {
                    Text(tr("settings.brain.localChoice")).tag(BrainKind.local)
                    Text(tr("settings.brain.externalChoice")).tag(BrainKind.external)
                }
                .pickerStyle(.segmented)
                .help(tr("settings.brain.localDefault"))
            } header: {
                stepTitle(1, tr("brain.step.where"))
            } footer: {
                // Local needs no warning (its explanation is on hover); leaving the Mac is said out loud.
                if !settings.isLocalBrain {
                    Text(tr("settings.brain.externalWarning"))
                }
            }

            if settings.isLocalBrain {
                // Step 2: the models Nook advises for this Mac; every other model and runtime is folded away.
                Section {
                    adviceRows
                    DisclosureGroup(tr("brain.local.all")) {
                        Picker(tr("settings.brain.localRuntime"), selection: localRuntime) {
                            Text(tr("settings.brain.builtIn")).tag(LocalRuntime.builtIn)
                            Text("Ollama").tag(LocalRuntime.ollama)
                            Text("LM Studio").tag(LocalRuntime.lmstudio)
                        }
                        .pickerStyle(.segmented)
                        if settings.useLocal {
                            localFields
                        } else {
                            providerSignIn
                            providerModel
                        }
                    }
                } header: {
                    stepTitle(2, tr("brain.step.model"))
                }
            } else {
                // Step 2: which service, step 3: signing in to it, step 4: its model.
                Section {
                    Picker(tr("settings.brain.provider"), selection: externalProvider) {
                        // Signing in with your own account comes first: your subscription needs no key at all.
                        Section(tr("brain.service.withAccount")) {
                            ForEach(AIProvider.allCases.filter(\.isSubscription)) { provider in
                                Label { Text(serviceName(provider)) } icon: { LogoImage.brand(BrandLogo.forProvider(provider)) }
                                    .tag(provider)
                            }
                        }
                        Section(tr("brain.service.withKey")) {
                            ForEach(AIProvider.allCases.filter { !$0.isSubscription && !$0.isLocalServer }) { provider in
                                Label { Text(serviceName(provider)) } icon: { LogoImage.brand(BrandLogo.forProvider(provider)) }
                                    .tag(provider)
                            }
                        }
                    }
                    .help(brainExplanation)
                } header: {
                    stepTitle(2, tr("brain.step.service"))
                }
                Section {
                    providerSignIn
                } header: {
                    stepTitle(3, tr("brain.step.signIn"))
                }
                Section {
                    providerModel
                } header: {
                    stepTitle(4, tr("brain.step.model"))
                }
                ScreenBrainSection(settings: settings)
            }

            if settings.brainProfile.isSmall { LocalQualitySection(settings: settings) }
        }
        .task { recommendations = await app.brainRecommendations() }
    }

    /// The models Nook proposes for this Mac, best first, with one button to use or install each.
    var adviceRows: some View {
        Group {
            SettingNote(tr("brain.advice.memory", EmbeddedModel.memoryGB))
            ForEach(Array(recommendations.prefix(3).enumerated()), id: \.offset) { index, recommendation in
                HStack(alignment: .firstTextBaseline) {
                    ModelLogo(name: AppModel.title(of: recommendation))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Text(AppModel.title(of: recommendation)).fontWeight(index == 0 ? .semibold : .regular)
                            if index == 0, recommendation.choice != .unavailable {
                                Image(systemName: "star.fill").font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
                            }
                        }
                        Text(recommendation.reason).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
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
            InUseLabel(tr("brain.advice.inUse"))
        case .server(let model) where !settings.useLocal && settings.activeProviderModel == model.name
                && settings.provider == (model.server == .ollama ? .ollama : .lmstudio):
            InUseLabel(tr("brain.advice.inUse"))
        case .mlx(let option) where !recommendation.ready:
            Button(tr("brain.advice.install")) { Task { await install(option.id) } }
                .disabled(installing != nil)
        default:
            Button(tr("brain.advice.use")) {
                Task {
                    usingRecommendation = true
                    defer { usingRecommendation = false }
                    do {
                        try await app.useRecommendation(recommendation)
                    } catch {
                        ToastCenter.shared.error(error, title: tr("settings.brain.useFailed"))
                    }
                    testResult = nil
                }
            }
            .disabled(usingRecommendation)
        }
    }

    var brainExplanation: String {
        if [.claude, .claudeCode].contains(settings.provider) || settings.provider.isSubscription {
            return tr("settings.brain.claudeExplanation")
        }
        return tr("settings.brain.otherExplanation")
    }

    /// A section header with its step number: "2  Service".
    func stepTitle(_ number: Int, _ title: String) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text("\(number)")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.onIris)
                .frame(width: 16, height: 16)
                .background(Circle().fill(NookTheme.iris))
            Text(title)
        }
    }

    /// Signing in to the chosen service: the subscription found on this Mac, a key, or the app that must run.
    var providerSignIn: some View {
        Group {
            if settings.provider.isSubscription {
                subscriptionStatus
            } else if settings.provider == .openrouter {
                // OpenRouter signs in on its own page and hands Nook a key itself; pasting one is folded away.
                openRouterSignIn
                DisclosureGroup(tr("settings.display.advanced")) {
                    keyFields.padding(.top, NookTheme.Spacing.xs)
                }
            } else if settings.provider.needsKey {
                keyFields
            } else if let url = settings.provider.keyURL {
                HStack {
                    SettingNote(tr("settings.brain.providerMustRun", settings.provider.title))
                    Spacer()
                    Link(tr("button.download"), destination: url).font(NookTheme.TextStyle.detail)
                }
            }
        }
    }

    /// Signing in to OpenRouter: one button, its progress, and what went wrong.
    @ViewBuilder
    var openRouterSignIn: some View {
        let hasKey = settings.hasKey(for: .openrouter)
        HStack {
            if hasKey {
                Label(tr("brain.openrouter.signedIn"), systemImage: "checkmark.seal.fill").foregroundStyle(NookTheme.mint)
                Spacer()
            }
            switch openRouter.phase {
            case .waiting:
                ProgressView().controlSize(.small)
                Text(tr("connect.waiting", "OpenRouter")).font(NookTheme.TextStyle.detail)
                Button(tr("button.cancel")) { openRouter.cancel() }
            default:
                Button {
                    openRouter.signIn(settings: settings)
                } label: {
                    Label(hasKey ? tr("connect.reauthorize") : tr("hub.signIn.button", "OpenRouter"), systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(hasKey ? .regular : .large)
            }
        }
        // Signed in: test the new key at once, as after pasting one.
        .onChange(of: openRouter.phase) { _, phase in
            if phase == .done { Task { await testConnection() } }
        }
        if case .failed(let message) = openRouter.phase {
            SettingNote(message, tone: .error)
        }
    }

    /// A key for services that only take one: one button to the page that makes it, then the field. Nook picks a
    /// copied key up by itself when you come back.
    var keyFields: some View {
        Group {
            if let url = settings.provider.keyURL, !settings.hasKey(for: settings.provider) {
                Button {
                    NSWorkspace.shared.open(url)
                    keyCatcher.watch()
                } label: {
                    Label(tr("brain.key.get", settings.provider.title), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)
                SettingNote(tr("brain.key.autoPaste"))
            }
            HStack {
                SecureField(settings.provider.keyPlaceholder, text: $keyDraft)
                    .onSubmit { if !keyDraft.isEmpty { saveKey() } }
                Button(tr("button.save"), action: saveKey)
                    .disabled(keyDraft.isEmpty)
            }
            // On this one row: on the Group around it the key would be saved once per row.
            .onDisappear { keyCatcher.stop() }
            // perf: `caught` is set once per copied key and reset right after, so every value is a new key.
            .onReceive(keyCatcher.$caught.compactMap { $0 }) { key in
                // A key copied on the service's page, picked up on the way back: saved and tested at once.
                keyDraft = key
                saveKey()
                keyCatcher.caught = nil
            }
            HStack {
                if settings.hasKey(for: settings.provider) {
                    Label(settings.provider == .claude ? "\(tr("settings.brain.keyInKeychain")): \(settings.maskedKey ?? "")" : tr("settings.brain.keyInKeychain"), systemImage: "key.fill")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                    ConfirmedButton(tr("accounts.removeKey"), question: tr("confirm.removeKey"), detail: tr("confirm.keychain.detail")) {
                        keyDraft = ""
                        saveKey()
                    }
                    .buttonStyle(.borderless)
                    .font(NookTheme.TextStyle.detail)
                } else {
                    SettingNote(tr("settings.brain.keyStaysInKeychain"))
                }
                Spacer()
            }
        }
    }

    /// The model of the chosen service: typed, or picked from what the service offers.
    var providerModel: some View {
        Group {
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
                SettingNote(tr("settings.brain.haikuHint"))
            }
        }
    }

    /// The name of a service in the picker: the account you sign in with, or the API.
    func serviceName(_ provider: AIProvider) -> String {
        switch provider {
        case .claudeCode: return tr("settings.brain.claude") + " · " + tr("settings.brain.claudeCodeSub")
        case .codexCLI: return tr("brain.sub.chatgpt")
        case .geminiCLI: return tr("brain.sub.gemini")
        case .claude: return tr("settings.brain.claude") + " · " + tr("settings.brain.apiKey")
        default: return provider.title
        }
    }

    /// Whose login a subscription signs in with: Claude, ChatGPT or Google.
    func accountBrand(_ provider: AIProvider) -> String {
        switch provider {
        case .claudeCode: return "Claude"
        case .codexCLI: return "ChatGPT"
        case .geminiCLI: return "Google"
        default: return provider.title
        }
    }

    /// Your subscription through its coding agent: installed, signed in, and as whom. One button does what is left
    /// (installing and signing in in the Terminal, or signing in in your browser where the agent can).
    @ViewBuilder
    var subscriptionStatus: some View {
        let _ = refreshTick
        if let kind = settings.provider.subscriptionAgent {
            let profile = app.profiles.preferredProfile(kind)
            let progress = app.agentConnect[profile.id]
            let path = SubscriptionBrain.executable(settings.provider)
            let account = app.history.profileAccounts[profile.id]
            if let progress, progress.isBusy {
                HStack(spacing: NookTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(progress.text).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                }
            } else if path == nil {
                StatusRow(title: tr("brain.sub.notInstalled", kind.name), detail: tr("brain.sub.notInstalledDetail", kind.name),
                          state: .warning) {
                    Button(tr("agents.installAndLogin")) { app.connect(profile) }
                        .buttonStyle(.borderedProminent)
                }
                HStack {
                    Button(tr("button.searchAgain")) {
                        ClaudeCodeBrain.resetLocation()
                        app.history.refresh()
                        refreshTick += 1
                        settings.objectWillChange.send()
                    }
                    if let url = settings.provider.keyURL { Link(tr("brain.sub.more", kind.name), destination: url) }
                }
            } else if let account {
                StatusRow(title: tr("brain.sub.signedIn", accountBrand(settings.provider)), detail: account.name, state: .done) {
                    EmptyView()
                }
            } else {
                StatusRow(title: tr("brain.sub.signedOut", accountBrand(settings.provider)),
                          detail: tr("brain.sub.signedOutDetail", kind.name), state: .todo) {
                    Button(tr("hub.signIn.button", accountBrand(settings.provider))) {
                        if !app.signInInBrowser(profile) { app.connect(profile) }
                    }
                    .buttonStyle(.borderedProminent)
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
            if fetchedModels.isEmpty {
                ToastCenter.shared.warning(tr("settings.brain.noModelsFound"))
            } else {
                ToastCenter.shared.success(tr("settings.brain.modelsFound", fetchedModels.count))
            }
        } catch {
            ToastCenter.shared.error(error, title: tr("settings.brain.modelsFailed"))
        }
    }

    var localFields: some View {
        Group {
            // Apple's own model: already on the Mac (macOS 26 with Apple Intelligence on), nothing to download.
            if AppleIntelligence.status != .unsupported {
                HStack {
                    ModelLogo(name: "Apple")
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(AppleModel.title)
                        Text(AppleIntelligence.isAvailable ? tr("brain.apple.detail") : AppleIntelligence.unavailableReason)
                            .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    }
                    Spacer()
                    if settings.localModel == AppleModel.id {
                        InUseLabel(tr("settings.brain.inUse"))
                    } else if AppleIntelligence.isAvailable {
                        Button(tr("settings.brain.use")) { settings.localModel = AppleModel.id; testResult = nil }
                    }
                }
            }
            ForEach(EmbeddedModel.options) { option in
                HStack {
                    ModelLogo(name: option.title + " " + option.id)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        HStack(spacing: 5) {
                            Text(option.title)
                            if !option.seesImages { NoImagesBadge() }
                        }
                        Text(option.detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    }
                    Spacer()
                    if installing == option.id {
                        ProgressView(value: installFraction).frame(width: 90)
                        Text("\(Int(installFraction * 100))%").font(NookTheme.TextStyle.detail.monospacedDigit())
                    } else if local.installed.contains(option.id) {
                        if settings.localModel == option.id {
                            InUseLabel(tr("settings.brain.inUse"))
                        } else {
                            Button(tr("settings.brain.use")) { settings.localModel = option.id; testResult = nil }
                        }
                    } else if !option.fits {
                        SettingNote(tr("settings.brain.tooHeavyForMemory", EmbeddedModel.memoryGB), tone: .warning)
                    } else {
                        Button(tr("button.download")) { Task { await install(option.id) } }
                            .disabled(installing != nil)
                    }
                }
            }
            SettingNote(tr("settings.brain.localModelDownloadHint", EmbeddedModel.memoryGB))
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
            ToastCenter.shared.success(tr("settings.brain.localReady", local.title(for: id)))
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
                    testResult = (false, tr("brain.key.invalid"))
                }
                if let keychainError = saved.keychainError {
                    ToastCenter.shared.warning(tr("settings.brain.keychainRejected"), detail: keychainError)
                } else {
                    ToastCenter.shared.success(tr("settings.brain.keySaved"))
                }
            } else {
                settings.saveAPIKey("")
                testResult = nil
                ToastCenter.shared.success(tr("settings.brain.keyRemoved"))
                return
            }
        } else {
            let error = settings.saveProviderKey(keyDraft, for: provider)
            let removed = keyDraft.isEmpty
            keyDraft = ""
            if let error {
                ToastCenter.shared.error(tr("settings.brain.keyNotSaved"), detail: error)
            } else {
                ToastCenter.shared.success(removed ? tr("settings.brain.keyRemoved") : tr("settings.brain.keySaved"))
            }
            if removed { return }
        }
        Task { await testConnection() }
    }

    func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await app.brain.test()
            testResult = (true, tr("brain.test.connected", settings.activeModelName, reply))
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
                Image(systemName: "cpu").font(NookTheme.font(14)).foregroundStyle(NookTheme.textSecondary)
            }
        }
        .frame(width: 22)
    }
}

/// A small crossed-out eye next to a model that cannot read pictures; the tooltip explains it.
struct NoImagesBadge: View {
    var body: some View {
        Image(systemName: "eye.slash")
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            .help(tr("brain.noImages.help"))
            .accessibilityLabel(tr("brain.noImages.help"))
    }
}
