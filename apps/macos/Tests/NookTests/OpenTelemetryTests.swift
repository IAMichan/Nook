import XCTest

/// OpenTelemetry export: which settings win over which, what each coding agent is told, the OTLP JSON Nook sends, and
/// how the buffer drops instead of retrying.
final class OpenTelemetryTests: XCTestCase {
    private let traces = "http://localhost:4318/v1/traces"
    private let metrics = "http://localhost:4318/v1/metrics"
    private let logs = "http://localhost:4318/v1/logs"

    private func config(_ endpoints: [OTLPSignal: String], headers: String = "", protocolChoice: OTLPProtocol = .httpProtobuf,
                        environment: [String: String] = [:]) -> OTLPConfig {
        OTLPResolver.resolve(saved: OTLPSaved(endpoints: endpoints, headers: headers, protocolChoice: protocolChoice),
                             environment: environment)
    }

    private var all: OTLPConfig { config([.traces: traces, .metrics: metrics, .logs: logs], headers: "x-api-key=secret") }

    // MARK: Precedence

    func testNothingSetIsOff() {
        let resolved = config([:])
        XCTAssertTrue(resolved.isEmpty)
        for provider in RunProvider.allCases {
            XCTAssertEqual(AgentTelemetry.launch(provider, config: resolved), AgentTelemetry.Launch(), provider.rawValue)
        }
    }

    func testSavedEndpointsAreUsed() {
        let resolved = config([.traces: traces, .metrics: " "], headers: "a=1, b = two%20words")
        XCTAssertEqual(resolved.endpoint(.traces)?.absoluteString, traces)
        XCTAssertNil(resolved.endpoint(.metrics))
        XCTAssertEqual(resolved.endpointSources[.traces], .settings)
        XCTAssertEqual(resolved.headers, [OTLPHeader(name: "a", value: "1"), OTLPHeader(name: "b", value: "two words")])
    }

    func testPerSignalEnvironmentWinsOverBaseAndSettings() {
        let resolved = config([.traces: "http://saved:4318/v1/traces", .logs: logs], environment: [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example:4318/",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://traces.example/custom",
        ])
        XCTAssertEqual(resolved.endpoint(.traces)?.absoluteString, "https://traces.example/custom")
        XCTAssertEqual(resolved.endpointSources[.traces], .environment("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"))
        // The base endpoint gets the signal's path, and overrides the saved one.
        XCTAssertEqual(resolved.endpoint(.logs)?.absoluteString, "https://collector.example:4318/v1/logs")
        XCTAssertEqual(resolved.endpointSources[.logs], .environment("OTEL_EXPORTER_OTLP_ENDPOINT"))
        XCTAssertEqual(resolved.endpoint(.metrics)?.absoluteString, "https://collector.example:4318/v1/metrics")
    }

    func testEnvironmentHeadersAndProtocolWin() {
        let resolved = config([.traces: traces], headers: "saved=1", protocolChoice: .httpProtobuf, environment: [
            "OTEL_EXPORTER_OTLP_HEADERS": "authorization=Bearer%20abc",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
        ])
        XCTAssertEqual(resolved.headers, [OTLPHeader(name: "authorization", value: "Bearer abc")])
        XCTAssertEqual(resolved.headersSource, .environment("OTEL_EXPORTER_OTLP_HEADERS"))
        XCTAssertEqual(resolved.protocolChoice, .httpJSON)
        XCTAssertEqual(resolved.protocolSource, .environment("OTEL_EXPORTER_OTLP_PROTOCOL"))
    }

    func testExporterNoneTurnsASignalOffAndSdkDisabledIsRead() {
        let resolved = config([.traces: traces, .logs: logs], environment: ["OTEL_TRACES_EXPORTER": "none", "OTEL_SDK_DISABLED": "TRUE"])
        XCTAssertNil(resolved.endpoint(.traces))
        XCTAssertNotNil(resolved.endpoint(.logs))
        XCTAssertTrue(resolved.sdkDisabled)
    }

    func testOnlyHTTPAddressesCount() {
        XCTAssertNil(OTLPResolver.httpURL("localhost:4318"))
        XCTAssertNil(OTLPResolver.httpURL("grpc://collector:4317"))
        XCTAssertNotNil(OTLPResolver.httpURL(" https://collector.example/v1/logs \n"))
    }

    func testBaseEndpointOnlyWhenTheSignalsShareOne() {
        XCTAssertEqual(all.baseEndpoint?.absoluteString, "http://localhost:4318")
        XCTAssertNil(config([.traces: traces, .logs: "http://other:4318/v1/logs"]).baseEndpoint)
        XCTAssertNil(config([.traces: "http://localhost:4318/custom"]).baseEndpoint)
    }

    func testHeadersRoundTrip() {
        let headers = [OTLPHeader(name: "Authorization", value: "Bearer a,b=c")]
        XCTAssertEqual(OTLPHeader.parse(OTLPHeader.format(headers)), headers)
        XCTAssertEqual(OTLPHeader.parse("novalue, =x, ok=1"), [OTLPHeader(name: "ok", value: "1")])
    }

    // MARK: What each agent gets

    func testEveryAgentGetsTheStandardVariables() {
        for provider in RunProvider.allCases {
            let env = AgentTelemetry.launch(provider, config: config([.traces: traces], headers: "k=v")).environment
            XCTAssertEqual(env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"], traces, provider.rawValue)
            XCTAssertEqual(env["OTEL_TRACES_EXPORTER"], "otlp", provider.rawValue)
            XCTAssertEqual(env["OTEL_METRICS_EXPORTER"], "none", provider.rawValue)
            XCTAssertEqual(env["OTEL_LOGS_EXPORTER"], "none", provider.rawValue)
            XCTAssertEqual(env["OTEL_EXPORTER_OTLP_ENDPOINT"], "http://localhost:4318", provider.rawValue)
            XCTAssertEqual(env["OTEL_EXPORTER_OTLP_PROTOCOL"], "http/protobuf", provider.rawValue)
            XCTAssertEqual(env["OTEL_EXPORTER_OTLP_HEADERS"], "k=v", provider.rawValue)
        }
    }

    func testClaudeCodeIsSwitchedOn() {
        let env = AgentTelemetry.launch(.claude, config: all).environment
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_TELEMETRY"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"], "1")
        let metricsOnly = AgentTelemetry.launch(.claude, config: config([.metrics: metrics])).environment
        XCTAssertEqual(metricsOnly["CLAUDE_CODE_ENABLE_TELEMETRY"], "1")
        XCTAssertNil(metricsOnly["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"])
    }

    func testCodexGetsConfigOverridesPerSignal() {
        let args = AgentTelemetry.launch(.codex, config: config([.traces: traces, .logs: logs], headers: "x-key=a\"b",
                                                                 protocolChoice: .httpJSON)).arguments
        XCTAssertEqual(args, [
            "-c", #"otel.exporter={otlp-http={endpoint="http://localhost:4318/v1/logs",protocol="json",headers={"x-key"="a\"b"}}}"#,
            "-c", #"otel.trace_exporter={otlp-http={endpoint="http://localhost:4318/v1/traces",protocol="json",headers={"x-key"="a\"b"}}}"#,
        ])
        let binary = AgentTelemetry.launch(.codex, config: config([.metrics: metrics])).arguments
        XCTAssertEqual(binary, ["-c", #"otel.metrics_exporter={otlp-http={endpoint="http://localhost:4318/v1/metrics",protocol="binary",headers={}}}"#])
    }

    func testCodexOverridesGoAfterTheSubcommand() {
        let exec = LaunchSpec(executable: "/bin/codex", arguments: ["exec", "--json", "--", "hi"], extraEnvironment: [:],
                              workingDirectory: "/tmp", initialInput: [], keepsInputOpen: false)
        let placed = AgentTelemetry.apply(.codex, config: config([.logs: logs]), to: exec)
        XCTAssertEqual(Array(placed.arguments.prefix(3)), ["exec", "-c", placed.arguments[2]])
        XCTAssertTrue(placed.arguments[2].hasPrefix("otel.exporter="))
        XCTAssertEqual(placed.arguments.suffix(2), ["--", "hi"])
        var server = exec
        server.arguments = ["app-server"]
        XCTAssertEqual(AgentTelemetry.apply(.codex, config: config([.logs: logs]), to: server).arguments.first, "app-server")
    }

    func testGeminiNeedsASharedBase() {
        var env = AgentTelemetry.launch(.gemini, config: all).environment
        XCTAssertEqual(env["GEMINI_TELEMETRY_ENABLED"], "true")
        XCTAssertEqual(env["GEMINI_TELEMETRY_TARGET"], "local")
        XCTAssertEqual(env["GEMINI_TELEMETRY_OTLP_ENDPOINT"], "http://localhost:4318")
        XCTAssertEqual(env["GEMINI_TELEMETRY_OTLP_PROTOCOL"], "http")
        XCTAssertEqual(env["GEMINI_TELEMETRY_OTLP_HEADERS"], #"{"x-api-key":"secret"}"#)
        env = AgentTelemetry.launch(.gemini, config: config([.traces: traces, .logs: "http://elsewhere/v1/logs"])).environment
        XCTAssertNil(env["GEMINI_TELEMETRY_ENABLED"])
    }

    func testGrokIsSwitchedOnForMetricsAndLogs() {
        XCTAssertEqual(AgentTelemetry.launch(.grok, config: all).environment["GROK_EXTERNAL_OTEL"], "1")
        XCTAssertNil(AgentTelemetry.launch(.grok, config: config([.traces: traces])).environment["GROK_EXTERNAL_OTEL"])
    }

    func testAgentsWithoutExportOfTheirOwnGetOnlyStandardVariables() {
        for provider in RunProvider.allCases where AgentTelemetry.signals(provider).isEmpty {
            let launch = AgentTelemetry.launch(provider, config: all)
            XCTAssertEqual(launch.environment, AgentTelemetry.standardEnvironment(all), provider.rawValue)
            XCTAssertTrue(launch.arguments.isEmpty, provider.rawValue)
        }
    }

    func testAVariableTheLaunchSetsItselfStays() {
        let spec = LaunchSpec(executable: "/bin/sh", arguments: [], extraEnvironment: ["OTEL_EXPORTER_OTLP_PROTOCOL": "grpc"],
                              workingDirectory: "/tmp", initialInput: [], keepsInputOpen: true)
        let placed = AgentTelemetry.apply(.acp, config: all, to: spec)
        XCTAssertEqual(placed.extraEnvironment["OTEL_EXPORTER_OTLP_PROTOCOL"], "grpc")
        XCTAssertEqual(placed.extraEnvironment["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"], logs)
        XCTAssertEqual(AgentTelemetry.apply(.claude, config: config([:]), to: spec), spec)
    }

    func testTomlStringsAreEscaped() {
        XCTAssertEqual(AgentTelemetry.tomlString("a\"b\\c\nd\u{1}"), #""a\"b\\c\nd\u0001""#)
    }

    // MARK: Payloads

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEmptyExports() throws {
        XCTAssertEqual(String(decoding: OTLPPayload.empty(.traces), as: UTF8.self), #"{"resourceSpans":[]}"#)
        XCTAssertEqual(String(decoding: OTLPPayload.empty(.metrics), as: UTF8.self), #"{"resourceMetrics":[]}"#)
        XCTAssertEqual(String(decoding: OTLPPayload.empty(.logs), as: UTF8.self), #"{"resourceLogs":[]}"#)
    }

    func testTracePayloadShape() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000.5)
        let span = OTLPSpan(traceID: String(repeating: "a", count: 32), spanID: String(repeating: "b", count: 16),
                            name: "nook.agent.turn", start: start, end: start.addingTimeInterval(2),
                            attributes: ["n": .int(3), "p": .string("claude")], ok: false, statusMessage: "failed")
        let root = try json(OTLPPayload.traces([span], resource: ["service.name": .string("nook")], version: "1.2"))
        let resourceSpans = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let resource = try XCTUnwrap(resourceSpans.first?["resource"] as? [String: Any])
        let resourceAttributes = try XCTUnwrap(resource["attributes"] as? [[String: Any]])
        XCTAssertEqual(resourceAttributes.first?["key"] as? String, "service.name")
        let scopeSpans = try XCTUnwrap(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
        XCTAssertEqual((scopeSpans.first?["scope"] as? [String: Any])?["name"] as? String, "nook")
        let item = try XCTUnwrap((scopeSpans.first?["spans"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["traceId"] as? String, String(repeating: "a", count: 32))
        XCTAssertEqual(item["spanId"] as? String, String(repeating: "b", count: 16))
        XCTAssertEqual(item["kind"] as? Int, 1)
        XCTAssertEqual(item["startTimeUnixNano"] as? String, "1700000000500000000")
        XCTAssertEqual(item["endTimeUnixNano"] as? String, "1700000002500000000")
        XCTAssertEqual(item["status"] as? [String: AnyHashable], ["code": 2, "message": "failed"])
        let attributes = try XCTUnwrap(item["attributes"] as? [[String: Any]])
        XCTAssertEqual(attributes.map { $0["key"] as? String }, ["n", "p"])
        XCTAssertEqual(attributes[0]["value"] as? [String: String], ["intValue": "3"])
        XCTAssertEqual(attributes[1]["value"] as? [String: String], ["stringValue": "claude"])
    }

    func testMetricsPayloadGroupsSumsByName() throws {
        let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 110)
        let sums = [
            OTLPSum(name: "turns", unit: "{turn}", description: "d", attributes: ["p": .string("claude")], value: 2),
            OTLPSum(name: "seconds", unit: "s", description: "d", value: 1.5, isInteger: false),
            OTLPSum(name: "turns", unit: "{turn}", description: "d", attributes: ["p": .string("codex")], value: 1),
        ]
        let root = try json(OTLPPayload.metrics(sums, resource: [:], version: "1", start: start, end: end))
        let scope = try XCTUnwrap(((root["resourceMetrics"] as? [[String: Any]])?.first?["scopeMetrics"] as? [[String: Any]])?.first)
        let metrics = try XCTUnwrap(scope["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["name"] as? String }, ["turns", "seconds"])
        let turns = try XCTUnwrap(metrics[0]["sum"] as? [String: Any])
        XCTAssertEqual(turns["aggregationTemporality"] as? Int, 1)
        XCTAssertEqual(turns["isMonotonic"] as? Bool, true)
        let points = try XCTUnwrap(turns["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(points.map { $0["asInt"] as? String }, ["2", "1"])
        XCTAssertEqual(points.first?["startTimeUnixNano"] as? String, "100000000000")
        XCTAssertEqual(points.first?["timeUnixNano"] as? String, "110000000000")
        let seconds = try XCTUnwrap((metrics[1]["sum"] as? [String: Any])?["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(seconds.first?["asDouble"] as? Double, 1.5)
    }

    func testLogPayloadShape() throws {
        let record = OTLPLogRecord(time: Date(timeIntervalSince1970: 5), severity: .error, body: "agent turn failed",
                                   traceID: "t", spanID: "s")
        let root = try json(OTLPPayload.logs([record], resource: [:], version: "1"))
        let scope = try XCTUnwrap(((root["resourceLogs"] as? [[String: Any]])?.first?["scopeLogs"] as? [[String: Any]])?.first)
        let item = try XCTUnwrap((scope["logRecords"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["severityNumber"] as? Int, 17)
        XCTAssertEqual(item["severityText"] as? String, "ERROR")
        XCTAssertEqual(item["body"] as? [String: String], ["stringValue": "agent turn failed"])
        XCTAssertEqual(item["timeUnixNano"] as? String, "5000000000")
        XCTAssertEqual(item["traceId"] as? String, "t")
    }

    func testRandomIDsAreHexOfTheRightLength() {
        let trace = OTLPPayload.randomID(bytes: 16), span = OTLPPayload.randomID(bytes: 8)
        XCTAssertEqual(trace.count, 32)
        XCTAssertEqual(span.count, 16)
        XCTAssertTrue((trace + span).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: Records and buffer

    func testATurnBecomesASpanSumsAndALogWithoutContent() {
        let now = Date()
        var run = WorkspaceRun(id: UUID(), title: "secret title", task: "secret task", provider: .codex, profileID: "codex",
                               model: "gpt-5", mode: .agent, permission: .ask, isolation: .folder, projectPath: "/Users/x/p",
                               workingDirectory: "/Users/x/p", repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil,
                               instructions: "", status: .completed, statusDetail: nil, providerSessionID: nil, createdAt: now,
                               updatedAt: now, archived: false, usage: RunUsage(), turnStartedAt: now, reviewedAt: nil,
                               lastChangeAt: nil, changedFiles: nil)
        var before = RunUsage()
        before.inputTokens = 100
        run.usage.inputTokens = 350
        run.usage.outputTokens = 40
        let records = TelemetryRecords.turn(run, started: now.addingTimeInterval(-3), before: before, now: now)
        XCTAssertEqual(records.span.name, "nook.agent.turn")
        XCTAssertEqual(records.span.attributes["nook.agent.provider"], .string("codex"))
        XCTAssertEqual(records.span.attributes["nook.agent.tokens.input"], .int(250))
        XCTAssertEqual(records.span.attributes["nook.agent.tokens.output"], .int(40))
        XCTAssertNil(records.span.attributes["nook.agent.tokens.cache_read"])
        XCTAssertTrue(records.span.ok)
        XCTAssertEqual(records.sums.first(where: { $0.name == "nook.agent.turn.duration" })?.value ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(records.log.severity, .info)
        XCTAssertEqual(records.log.spanID, records.span.spanID)
        let everything = "\(records)"
        XCTAssertFalse(everything.contains("secret"))
        XCTAssertFalse(everything.contains("/Users/x"))
    }

    func testBufferAddsSumsCapsAndPausesAfterAFailure() {
        var buffer = TelemetryBuffer(limit: 2, pause: 60)
        let now = Date()
        let span = OTLPSpan(traceID: "t", spanID: "s", name: "x", start: now, end: now)
        for index in 0..<3 {
            var copy = span
            copy.name = "x\(index)"
            buffer.add(copy, now: now)
        }
        XCTAssertEqual(buffer.spans.map(\.name), ["x1", "x2"])
        let sum = OTLPSum(name: "turns", unit: "1", description: "", attributes: ["p": .string("claude")], value: 1)
        buffer.add(sum, now: now)
        buffer.add(sum, now: now)
        XCTAssertEqual(buffer.sums.count, 1)
        XCTAssertEqual(buffer.sums.first?.value, 2)
        _ = buffer.drain()
        XCTAssertTrue(buffer.isEmpty)

        buffer.failed(.traces, now: now)
        buffer.add(span, now: now.addingTimeInterval(30))
        XCTAssertTrue(buffer.spans.isEmpty, "a receiver that is down is not sent to again for a minute")
        buffer.add(sum, now: now.addingTimeInterval(30))
        XCTAssertEqual(buffer.sums.count, 1, "other signals go on")
        buffer.add(span, now: now.addingTimeInterval(61))
        XCTAssertEqual(buffer.spans.count, 1)
    }
}
