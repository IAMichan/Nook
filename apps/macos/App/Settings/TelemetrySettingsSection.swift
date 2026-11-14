import SwiftUI

/// Settings › Maintenance › OpenTelemetry export: an OTLP/HTTP endpoint per signal, the headers (in the Keychain) and
/// the protocol, with a Test per signal that sends an empty export. A value set by `OTEL_EXPORTER_OTLP_*` in Nook's
/// environment wins; its row says "Set by environment" with the variable's name, and its Test checks that endpoint.
/// Nook's own records and every agent it starts use the result (`NookTelemetry`, `AgentTelemetry`).
struct TelemetrySettingsSection: View {
    @State private var config = NookTelemetry.shared.current
    @State private var drafts: [OTLPSignal: String] = [:]
    @State private var protocolChoice = OTLPSettings.load(readHeaders: false).protocolChoice
    @State private var headersDraft = ""
    @State private var hasHeaders = false
    @State private var testing: Set<OTLPSignal> = []
    @State private var results: [OTLPSignal: (ok: Bool, message: String)] = [:]

    var body: some View {
        Section {
            ForEach(OTLPSignal.allCases) { signal in
                endpointRow(signal)
            }
            protocolRow
            headersRow
            SettingNote(tr("otel.footer"))
        } header: {
            SettingsSectionTitle(tr("otel.title"), info: tr("otel.info"))
        }
        .onAppear(perform: load)
    }

    // MARK: Rows

    @ViewBuilder private func endpointRow(_ signal: OTLPSignal) -> some View {
        let variable = environmentVariable(config.endpointSources[signal])
        HStack(spacing: NookTheme.Spacing.md) {
            if variable != nil {
                LabeledContent {
                    Text(verbatim: config.endpoint(signal)?.absoluteString ?? "")
                        .font(NookTheme.TextStyle.code)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                } label: {
                    SettingText("otel.signal." + signal.rawValue)
                }
            } else {
                SettingFieldRow(tr("otel.signal." + signal.rawValue)) {
                    TextField(tr("otel.signal." + signal.rawValue), text: binding(signal),
                              prompt: Text(verbatim: "http://localhost:4318" + signal.path).foregroundStyle(NookTheme.textTertiary))
                        .onSubmit { save(signal) }
                }
            }
            if testing.contains(signal) { ProgressView().controlSize(.small) }
            Button(tr("otel.test")) { Task { await test(signal) } }
                .controlSize(.small)
                .disabled(testing.contains(signal) || testURL(signal) == nil)
        }
        if let variable {
            SettingNote(tr("otel.setByEnvironment", variable))
        }
        if let result = results[signal] {
            SettingNote(result.message, tone: result.ok ? .success : .error)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var protocolRow: some View {
        let variable = environmentVariable(config.protocolSource)
        Picker(selection: Binding(get: { variable == nil ? protocolChoice : config.protocolChoice }, set: { choice in
            protocolChoice = choice
            OTLPSettings.saveProtocol(choice)
            reload()
        })) {
            ForEach(OTLPProtocol.allCases) { choice in
                Text(verbatim: choice.rawValue).tag(choice)
            }
        } label: {
            SettingLabel(tr("otel.protocol"), hint: tr("otel.protocol.hint"))
        }
        .disabled(variable != nil)
        if let variable { SettingNote(tr("otel.setByEnvironment", variable)) }
    }

    @ViewBuilder private var headersRow: some View {
        if let variable = environmentVariable(config.headersSource) {
            LabeledContent {
                Text(tr("otel.headers.count", config.headers.count))
                    .foregroundStyle(NookTheme.textSecondary)
            } label: {
                SettingText("otel.headers")
            }
            SettingNote(tr("otel.setByEnvironment", variable))
        } else if hasHeaders {
            LabeledContent {
                Button(tr("otel.headers.remove")) {
                    OTLPSettings.saveHeaders("")
                    hasHeaders = false
                    reload()
                }
                .controlSize(.small)
            } label: {
                SettingLabel(tr("otel.headers"), detail: tr("otel.headers.saved"))
            }
        } else {
            HStack {
                SettingFieldRow(tr("otel.headers")) {
                    SecureField(tr("otel.headers"), text: $headersDraft, prompt: Text(verbatim: "Authorization=Bearer …").foregroundStyle(NookTheme.textTertiary))
                        .onSubmit(saveHeaders)
                }
                Button(tr("button.save"), action: saveHeaders)
                    .controlSize(.small)
                    .disabled(headersDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            SettingNote(tr("otel.headers.hint"))
        }
    }

    // MARK: Actions

    private func binding(_ signal: OTLPSignal) -> Binding<String> {
        Binding(get: { drafts[signal] ?? "" }, set: { text in
            drafts[signal] = text
            results[signal] = nil
        })
    }

    private func load() {
        let saved = OTLPSettings.load(readHeaders: false)
        for signal in OTLPSignal.allCases { drafts[signal] = saved.endpoints[signal] ?? "" }
        protocolChoice = saved.protocolChoice
        hasHeaders = OTLPSettings.hasSavedHeaders
        config = NookTelemetry.shared.current
    }

    private func save(_ signal: OTLPSignal) {
        let text = (drafts[signal] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, OTLPResolver.httpURL(text) == nil {
            results[signal] = (false, tr("otel.invalid"))
            return
        }
        OTLPSettings.saveEndpoint(text, for: signal)
        reload()
    }

    private func saveHeaders() {
        let text = headersDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !OTLPHeader.parse(text).isEmpty else {
            ToastCenter.shared.error(tr("otel.headers.invalid"))
            return
        }
        if OTLPSettings.saveHeaders(text) {
            headersDraft = ""
            hasHeaders = true
            reload()
        } else {
            ToastCenter.shared.error(tr("otel.headers.notSaved"))
        }
    }

    private func reload() {
        NookTelemetry.shared.reload()
        config = NookTelemetry.shared.current
    }

    /// The endpoint Test checks: the one set by the environment, else what the field holds (saved or not).
    private func testURL(_ signal: OTLPSignal) -> URL? {
        if environmentVariable(config.endpointSources[signal]) != nil { return config.endpoint(signal) }
        return OTLPResolver.httpURL(drafts[signal] ?? "")
    }

    private func test(_ signal: OTLPSignal) async {
        guard let url = testURL(signal) else { return }
        // The headers (often a key) only go to the endpoint in effect, never to one that is only typed.
        let headers = url == config.endpoint(signal) ? config.headers : []
        testing.insert(signal)
        defer { testing.remove(signal) }
        switch await NookTelemetry.shared.test(signal, url: url, headers: headers) {
        case .ok(let status): results[signal] = (true, tr("otel.test.ok", status))
        case .rejected(let status): results[signal] = (false, tr("otel.test.rejected", status))
        case .unreachable(let message): results[signal] = (false, tr("otel.test.unreachable", message))
        }
    }

    private func environmentVariable(_ source: OTLPSource?) -> String? {
        if case .environment(let name) = source { return name }
        return nil
    }
}
