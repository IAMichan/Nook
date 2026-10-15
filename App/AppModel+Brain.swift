import Foundation

/// Choosing and installing the local brain: Nook proposes the model that suits this Mac and sets it up in one click.
extension AppModel {
    /// Models currently served by Ollama and LM Studio on this Mac (empty when they are not running).
    func localServerModels() async -> [ServerModel] {
        let ollamaURL = OllamaConversation.baseURL + "/api/tags"
        let lmstudioURL = AIProvider.lmstudio.baseURL + "/models"
        async let ollama = Self.fetchModels(ollamaURL, server: .ollama)
        async let lmstudio = Self.fetchModels(lmstudioURL, server: .lmstudio)
        return await ollama + lmstudio
    }

    private nonisolated static func fetchModels(_ address: String, server: ServerModel.Server) async -> [ServerModel] {
        guard let url = URL(string: address) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let list = (object["models"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["name"] as? String) ?? ($0["id"] as? String) }.map { ServerModel(server: server, name: $0) }
    }

    /// Best local choices for this Mac, best first.
    func brainRecommendations() async -> [ModelAdvisor.Recommendation] {
        let servers = await localServerModels()
        return ModelAdvisor.recommend(hardware: .current, installedMLX: EmbeddedModel.shared.installed, serverModels: servers)
    }

    /// Makes a recommendation the active brain, downloading a built-in model first if needed.
    func useRecommendation(_ recommendation: ModelAdvisor.Recommendation, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        switch recommendation.choice {
        case .mlx(let option):
            if !EmbeddedModel.shared.installed.contains(option.id) {
                try await EmbeddedModel.shared.install(option.id, progress: progress)
            }
            settings.useLocal = true
            settings.localModel = option.id
        case .server(let model):
            settings.useLocal = false
            settings.provider = model.server == .ollama ? .ollama : .lmstudio
            settings.setProviderModel(model.name)
        case .unavailable:
            throw NookError(recommendation.reason)
        }
    }

    static func title(of recommendation: ModelAdvisor.Recommendation) -> String {
        switch recommendation.choice {
        case .mlx(let option): return option.title
        case .server(let model): return tr("brain.advice.server", model.name, model.server == .ollama ? "Ollama" : "LM Studio")
        case .unavailable: return tr("brain.advice.none")
        }
    }

    /// Shown when the local brain has no model yet: proposes the best one for this Mac and installs it on one click.
    func presentLocalSetupCard() {
        Task { @MainActor in
            let options = await brainRecommendations()
            guard let best = options.first else { return }
            let token = "setup-local-" + UUID().uuidString
            viewModel.register("\(token)#choose") { [weak self] in self?.openSettings(section: .brain) }
            guard best.choice != .unavailable else {
                viewModel.show(.card(NookCard(
                    id: token, mood: .waiting, context: tr("setup.local.context"), title: tr("setup.none.title"),
                    detail: .facts([Fact(label: tr("brain.advice.why"), value: best.reason)]),
                    primary: CardAction(label: tr("setup.local.choose"), outcome: .callback("\(token)#choose", "")),
                    secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
                    contentHeight: 168
                )))
                return
            }
            let name = Self.title(of: best)
            viewModel.register("\(token)#use") { [weak self] in
                guard let self else { return }
                self.viewModel.show(.card(self.answerCard(tr("setup.local.installing", name))))
                Task { @MainActor in
                    do {
                        try await self.useRecommendation(best)
                        self.viewModel.show(.card(self.answerCard(tr("setup.local.installed", name))))
                    } catch {
                        self.viewModel.show(.card(self.errorCard(error.localizedDescription)))
                    }
                }
            }
            let title: String
            if case .server(let model) = best.choice {
                title = tr("setup.local.server", model.name, model.server == .ollama ? "Ollama" : "LM Studio")
            } else {
                title = tr("setup.local.title")
            }
            viewModel.show(.card(NookCard(
                id: token, mood: .waiting, context: tr("setup.local.context"), title: title,
                detail: .facts([Fact(label: name, value: best.reason)]),
                primary: CardAction(label: best.ready ? tr("setup.local.use") : tr("setup.local.install", name), outcome: .callback("\(token)#use", "")),
                secondary: CardAction(label: tr("setup.local.choose"), outcome: .callback("\(token)#choose", "")),
                contentHeight: 168
            )))
        }
    }
}
