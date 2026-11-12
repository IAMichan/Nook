import Foundation

/// Tells every coding agent Nook starts about the OpenTelemetry receiver set in Settings › Maintenance › Diagnostics
/// (`OTLPConfig`), in the words that agent reads. Every agent gets the standard `OTEL_EXPORTER_OTLP_*` variables (an
/// agent or extension that uses the OpenTelemetry SDK picks those up); on top of that each one gets the switch its own
/// telemetry needs. What each agent then sends is in `signals(_:)` and in docs/INTEGRATIONS.md. Nothing here runs: the
/// launch spec is only changed, so the tests check it.
enum AgentTelemetry {
    /// What a launch gains: variables, and for Codex config overrides (`-c key=value`).
    struct Launch: Equatable, Sendable {
        var environment: [String: String] = [:]
        var arguments: [String] = []
    }

    /// The signals the agent itself exports once it is told the receiver, verified against its documentation or its
    /// installed build (see docs/INTEGRATIONS.md). Empty: the agent has no OpenTelemetry export of its own; it still gets
    /// the standard variables, for an extension or SDK inside it.
    static func signals(_ provider: RunProvider) -> Set<OTLPSignal> {
        switch provider {
        // CLAUDE_CODE_ENABLE_TELEMETRY: metrics and log events; traces behind CLAUDE_CODE_ENHANCED_TELEMETRY_BETA.
        case .claude: return [.traces, .metrics, .logs]
        // `[otel]` in config.toml: exporter (logs), trace_exporter, metrics_exporter.
        case .codex: return [.traces, .metrics, .logs]
        // GEMINI_TELEMETRY_*: one base endpoint, all three signals.
        case .gemini: return [.traces, .metrics, .logs]
        // Its observability layer reads OTEL_EXPORTER_OTLP_ENDPOINT: spans, and logs at <base>/v1/logs.
        case .opencode: return [.traces, .logs]
        // Grok Build: GROK_EXTERNAL_OTEL with the OTEL_*_EXPORTER switches; it exports no traces.
        case .grok: return [.metrics, .logs]
        // No OpenTelemetry export of their own: Cursor's CLI does not document one (its Agent SDK does), Antigravity
        // has none (only hooks), Pi only through third-party extensions, which read the standard variables.
        case .cursor, .antigravity, .pi, .acp: return []
        }
    }

    static func launch(_ provider: RunProvider, config: OTLPConfig) -> Launch {
        guard !config.isEmpty else { return Launch() }
        var launch = Launch(environment: standardEnvironment(config))
        let configured = Set(config.endpoints.keys)
        switch provider {
        case .claude:
            launch.environment["CLAUDE_CODE_ENABLE_TELEMETRY"] = "1"
            if configured.contains(.traces) { launch.environment["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"] = "1" }
        case .codex:
            launch.arguments = codexArguments(config)
        case .gemini:
            // One endpoint for everything, with `v1/<signal>` appended: only when the endpoints share a base.
            guard let base = config.baseEndpoint else { break }
            launch.environment["GEMINI_TELEMETRY_ENABLED"] = "true"
            launch.environment["GEMINI_TELEMETRY_TARGET"] = "local"
            launch.environment["GEMINI_TELEMETRY_OTLP_ENDPOINT"] = base.absoluteString
            launch.environment["GEMINI_TELEMETRY_OTLP_PROTOCOL"] = "http"
            if configured.contains(.traces) { launch.environment["GEMINI_TELEMETRY_TRACES_ENABLED"] = "true" }
            if !config.headers.isEmpty { launch.environment["GEMINI_TELEMETRY_OTLP_HEADERS"] = jsonObject(config.headers) }
        case .grok:
            if !configured.isDisjoint(with: [.metrics, .logs]) { launch.environment["GROK_EXTERNAL_OTEL"] = "1" }
        case .opencode, .cursor, .antigravity, .pi, .acp:
            break
        }
        return launch
    }

    /// The launch with the agent's telemetry added. A variable the launch already sets (an ACP agent you added with its
    /// own `OTEL_*`) stays as it is. Codex's overrides go right after its subcommand (`exec`, `app-server`).
    static func apply(_ provider: RunProvider, config: OTLPConfig, to spec: LaunchSpec) -> LaunchSpec {
        let launch = launch(provider, config: config)
        guard launch != Launch() else { return spec }
        var spec = spec
        spec.extraEnvironment.merge(launch.environment) { existing, _ in existing }
        if !launch.arguments.isEmpty {
            let at = ["exec", "app-server"].contains(spec.arguments.first ?? "") ? 1 : 0
            spec.arguments.insert(contentsOf: launch.arguments, at: at)
        }
        return spec
    }

    /// The standard OpenTelemetry variables: each configured signal's endpoint with its exporter on, the others off, the
    /// base endpoint when they share one, the protocol and the headers.
    static func standardEnvironment(_ config: OTLPConfig) -> [String: String] {
        var environment: [String: String] = [:]
        for signal in OTLPSignal.allCases {
            if let url = config.endpoint(signal) {
                environment[signal.endpointVariable] = url.absoluteString
                environment[signal.exporterVariable] = "otlp"
            } else {
                environment[signal.exporterVariable] = "none"
            }
        }
        if let base = config.baseEndpoint { environment[OTLPResolver.baseEndpointVariable] = base.absoluteString }
        environment[OTLPResolver.protocolVariable] = config.protocolChoice.rawValue
        if !config.headers.isEmpty { environment[OTLPResolver.headersVariable] = config.headersVariable }
        return environment
    }

    /// Codex's `[otel]` as `-c` overrides, one inline TOML table per configured signal:
    /// `otel.exporter={otlp-http={endpoint="…",protocol="json",headers={"k"="v"}}}`. Logs go through `otel.exporter`.
    static func codexArguments(_ config: OTLPConfig) -> [String] {
        let keys: [(OTLPSignal, String)] = [(.logs, "otel.exporter"), (.traces, "otel.trace_exporter"), (.metrics, "otel.metrics_exporter")]
        let wire = config.protocolChoice == .httpJSON ? "json" : "binary"
        let headers = config.headers.map { tomlString($0.name) + "=" + tomlString($0.value) }.joined(separator: ",")
        return keys.compactMap { signal, key -> [String]? in
            guard let url = config.endpoint(signal) else { return nil }
            let table = "{otlp-http={endpoint=\(tomlString(url.absoluteString)),protocol=\"\(wire)\",headers={\(headers)}}}"
            return ["-c", key + "=" + table]
        }.flatMap { $0 }
    }

    /// A TOML basic string: quotes, backslashes and control characters escaped, so a header value cannot end the table.
    static func tomlString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func jsonObject(_ headers: [OTLPHeader]) -> String {
        var object: [String: String] = [:]
        for header in headers { object[header.name] = header.value }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
