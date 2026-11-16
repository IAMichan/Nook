import Foundation

// OpenTelemetry export to a receiver of your own (Settings › Maintenance › Diagnostics › OpenTelemetry export): which
// OTLP/HTTP endpoint each signal goes to, with which headers and protocol. Saved in Settings, or set by the standard
// `OTEL_EXPORTER_OTLP_*` variables in Nook's environment, which win. Nook's own spans and metrics go there
// (`NookTelemetry`), and every coding agent Nook starts is told the same receiver in its own words (`AgentTelemetry`).
// Foundation only, so the tests check the precedence without the app.

/// One kind of OpenTelemetry data, each with an endpoint of its own.
enum OTLPSignal: String, CaseIterable, Identifiable, Sendable {
    case traces, metrics, logs

    var id: String { rawValue }

    /// The path a receiver takes this signal on, appended to a base endpoint (`http://localhost:4318` + `/v1/traces`).
    var path: String { "/v1/" + rawValue }

    /// The signal's part of the standard variable names: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_TRACES_EXPORTER`.
    var environmentName: String { rawValue.uppercased() }

    var endpointVariable: String { "OTEL_EXPORTER_OTLP_\(environmentName)_ENDPOINT" }
    var exporterVariable: String { "OTEL_\(environmentName)_EXPORTER" }
}

/// How the payload is encoded on the wire. Nook's own export is always JSON (written by hand, no SDK); the choice is
/// passed on to the agents, which bring their own exporters.
enum OTLPProtocol: String, CaseIterable, Identifiable, Sendable {
    case httpProtobuf = "http/protobuf"
    case httpJSON = "http/json"

    var id: String { rawValue }
}

/// What Settings holds: an endpoint per signal (empty is off), the headers (from the Keychain) and the protocol.
struct OTLPSaved: Equatable, Sendable {
    var endpoints: [OTLPSignal: String] = [:]
    /// `key=value,key2=value2`, the format of `OTEL_EXPORTER_OTLP_HEADERS`.
    var headers: String = ""
    var protocolChoice: OTLPProtocol = .httpProtobuf
}

/// Where a value of the effective configuration came from, so Settings can say "Set by environment" and name the variable.
enum OTLPSource: Equatable, Sendable {
    case settings
    case environment(String)
}

/// The configuration in effect: the saved settings with what Nook's environment overrides.
struct OTLPConfig: Equatable, Sendable {
    var endpoints: [OTLPSignal: URL] = [:]
    var endpointSources: [OTLPSignal: OTLPSource] = [:]
    var headers: [OTLPHeader] = []
    var headersSource: OTLPSource = .settings
    var protocolChoice: OTLPProtocol = .httpProtobuf
    var protocolSource: OTLPSource = .settings
    /// `OTEL_SDK_DISABLED=true`: Nook sends nothing of its own (agents read that variable themselves).
    var sdkDisabled = false

    /// Nothing to send anywhere: Nook's own export and the agents' stay off, at no cost.
    var isEmpty: Bool { endpoints.isEmpty }

    func endpoint(_ signal: OTLPSignal) -> URL? { endpoints[signal] }

    /// The base endpoint for agents that take only one (Gemini CLI, OpenCode) and append `/v1/<signal>` themselves:
    /// every configured endpoint with its signal's path taken off, when they all come to the same base. Nil when there is
    /// no endpoint, when one does not end in its signal's path, or when they point at different receivers.
    var baseEndpoint: URL? {
        var bases = Set<String>()
        for (signal, url) in endpoints {
            var text = url.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            guard text.hasSuffix(signal.path) else { return nil }
            bases.insert(String(text.dropLast(signal.path.count)))
        }
        guard bases.count == 1, let base = bases.first, !base.isEmpty else { return nil }
        return URL(string: base)
    }

    /// The headers as `OTEL_EXPORTER_OTLP_HEADERS` writes them, values percent-encoded.
    var headersVariable: String { OTLPHeader.format(headers) }
}

/// One header sent with every export (an API key for the receiver).
struct OTLPHeader: Equatable, Sendable {
    var name: String
    var value: String

    /// Reads `key=value,key2=value2`: entries split on commas, each on its first `=`, names and values trimmed and
    /// percent-decoded (the OpenTelemetry format). Entries without a name or `=` are left out.
    static func parse(_ text: String) -> [OTLPHeader] {
        text.split(separator: ",").compactMap { entry in
            guard let equals = entry.firstIndex(of: "=") else { return nil }
            let name = entry[..<equals].trimmingCharacters(in: .whitespaces)
            let value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let decodedName = name.removingPercentEncoding ?? name
            guard !decodedName.isEmpty, decodedName.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
            return OTLPHeader(name: decodedName, value: value.removingPercentEncoding ?? value)
        }
    }

    /// Writes headers back in the `key=value,key2=value2` format, with what would break it percent-encoded.
    static func format(_ headers: [OTLPHeader]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ",=%")
        return headers.map { header in
            let name = header.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? header.name
            let value = header.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? header.value
            return name + "=" + value
        }.joined(separator: ",")
    }
}

enum OTLPResolver {
    static let baseEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"
    static let headersVariable = "OTEL_EXPORTER_OTLP_HEADERS"
    static let protocolVariable = "OTEL_EXPORTER_OTLP_PROTOCOL"
    static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// The saved settings with Nook's environment on top, per signal: `OTEL_EXPORTER_OTLP_<SIGNAL>_ENDPOINT` as written,
    /// else `OTEL_EXPORTER_OTLP_ENDPOINT` with the signal's path appended, else the saved endpoint. Headers and protocol
    /// come from `OTEL_EXPORTER_OTLP_HEADERS` and `OTEL_EXPORTER_OTLP_PROTOCOL` when set. A signal whose
    /// `OTEL_<SIGNAL>_EXPORTER` is `none` is off, whatever its endpoint.
    static func resolve(saved: OTLPSaved, environment: [String: String]) -> OTLPConfig {
        var config = OTLPConfig()
        let base = value(baseEndpointVariable, in: environment).flatMap(httpURL)
        for signal in OTLPSignal.allCases {
            if value(signal.exporterVariable, in: environment)?.lowercased() == "none" { continue }
            if let text = value(signal.endpointVariable, in: environment), let url = httpURL(text) {
                config.endpoints[signal] = url
                config.endpointSources[signal] = .environment(signal.endpointVariable)
            } else if let base, let url = appending(signal.path, to: base) {
                config.endpoints[signal] = url
                config.endpointSources[signal] = .environment(baseEndpointVariable)
            } else if let text = saved.endpoints[signal], let url = httpURL(text) {
                config.endpoints[signal] = url
                config.endpointSources[signal] = .settings
            }
        }
        if let headers = value(headersVariable, in: environment) {
            config.headers = OTLPHeader.parse(headers)
            config.headersSource = .environment(headersVariable)
        } else {
            config.headers = OTLPHeader.parse(saved.headers)
        }
        if let text = value(protocolVariable, in: environment), let choice = OTLPProtocol(rawValue: text.lowercased()) {
            config.protocolChoice = choice
            config.protocolSource = .environment(protocolVariable)
        } else {
            config.protocolChoice = saved.protocolChoice
        }
        config.sdkDisabled = value(sdkDisabledVariable, in: environment)?.lowercased() == "true"
        return config
    }

    /// An http or https URL with a host, from what was typed or set; nil for anything else.
    static func httpURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func value(_ name: String, in environment: [String: String]) -> String? {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func appending(_ path: String, to base: URL) -> URL? {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + path)
    }
}
