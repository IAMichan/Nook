import Foundation
import AppKit

/// A coding agent on the user's screen: `take_over_screen` asks for it, and with the user's yes that session uses Nook's
/// own screen tools (`read_ui`, `look_ui`, `control_ui`) through `nook_use` for a few minutes. It works like Nook taking
/// over a task itself (`AppModel+Takeover`): Nook's violet cursor shows where it acts, the notch shows the step with
/// Stop, and a step that pays, orders, sends, deletes, books or signs waits for the user's yes (`TakeoverPolicy`).
extension WorkspaceBridge {
    /// Nook's tools that read or use the screen: only for the session that holds the screen.
    static let screenTools: Set<String> = [UIDriver.readTool, UIDriver.lookTool, UIDriver.controlTool]

    /// The agent that holds the screen now, if any.
    var screenHolder: BridgeScreenGrant? {
        guard let grant = screenGrant, grant.isActive() else { return nil }
        return grant
    }

    func takeOverScreen(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        if (arguments["stop"] as? Bool) == true {
            guard screenGrant?.holder == caller.key else { return BridgeRPC.ToolResult(text: "You do not have the screen.") }
            releaseScreen()
            audit(.takeOverScreen, caller, "stop", "teruggegeven")
            return BridgeRPC.ToolResult(text: "The screen is the user's again.")
        }
        if case .refuse(let reason) = verdict(.takeOverScreen, caller) { return .error(Self.refusal(reason)) }
        guard !keptOnMac(app).contains(SourceCatalog.screen) else {
            return .error("The user keeps the screen on this Mac (Settings › Privacy), so agents cannot see or use it. nook_use with take_over hands the task to Nook instead, which works on this Mac.")
        }
        guard !TakeoverState.shared.isRunning else { return .error("Nook is carrying out a task on the screen right now. Try again when it is done.") }
        if let holder = screenHolder {
            guard holder.holds(caller.key) else { return .error("\(holder.agent) is using the screen now. Try again later.") }
            return BridgeRPC.ToolResult(text: "You have the screen until \(Self.clock(holder.until)).")
        }
        let reason = ((arguments["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return .error("Give the reason: what you will do on the screen and why.") }
        let minutes = BridgeScreenGrant.minutes(arguments["minutes"] as? Int)

        let allowed = await ask(caller, tool: .takeOverScreen, title: tr("bridge.approval.screen", caller.agent), detail: reason,
                                note: tr("bridge.approval.screenNote", minutes), danger: false, connection: context.connection)
        guard allowed else {
            audit(.takeOverScreen, caller, reason, "niet toegestaan")
            return .error(Self.refusal(.screen))
        }
        // Someone else may have taken it while the card waited.
        if let holder = screenHolder, !holder.holds(caller.key) {
            return .error("\(holder.agent) is using the screen now. Try again later.")
        }
        let grant = BridgeScreenGrant(holder: caller.key, agent: caller.agent, minutes: minutes)
        screenGrant = grant
        UIDriver.onAct = { point, label in TakeoverCursor.shared.move(to: point, label: label) }
        showScreenWork(tr("bridge.screen.working", caller.agent))
        screenExpiry?.cancel()
        screenExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, self.screenGrant?.id == grant.id else { return }
            self.releaseScreen()
        }
        audit(.takeOverScreen, caller, reason, "\(minutes) min")
        return BridgeRPC.ToolResult(text: """
        You have the screen until \(Self.clock(grant.until)) (\(minutes) minutes), or until the user presses Stop.
        Use nook_use with read_ui (what is in a window), look_ui (a picture of it) and control_ui (click, type, keys, scroll, drag); read the window again after each step. Steps that pay, order, send, delete, book or sign wait for the user's yes. Call take_over_screen with stop: true when you are done.
        """)
    }

    /// One call of a screen tool by the agent that holds the screen.
    func screenStep(_ spec: ToolSpec, _ input: [String: Any], _ caller: BridgeCaller, _ context: Context,
                    _ app: AppModel) async -> BridgeRPC.ToolResult {
        guard let holder = screenHolder, holder.holds(caller.key) else {
            return .error("You do not have the screen. Ask for it first with take_over_screen; the user approves it in Nook.")
        }
        if let refusal = TakeoverPolicy.refusal(tool: spec.name, input: input) { return .error(refusal) }
        let summary = spec.summarize(input)
        if spec.kind == .action {
            // A click on a point is judged by what is there: the button under it, read from the app in front.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let line = TakeoverPolicy.checkpoint(tool: spec.name, input: input, summary: summary,
                                                     labelAt: { x, y in front.flatMap { UIDriver.label(at: CGPoint(x: x, y: y), pid: $0) } }) {
                let allowed = await ask(caller, tool: .takeOverScreen, title: tr("bridge.approval.screenStep", caller.agent),
                                        detail: line, note: "", danger: true, connection: context.connection)
                guard allowed else {
                    audit(.nookUse, caller, spec.name, "stap geweigerd")
                    return .error("The user said no to this step; it did not run. Do not try it another way.")
                }
                // The screen may have been taken back while the card waited.
                guard screenHolder?.holds(caller.key) == true else { return .error("The user took the screen back.") }
            }
        }
        showScreenWork(caller.agent + " · " + summary)
        do {
            let output = try await spec.run(input)
            audit(.nookUse, caller, spec.name, spec.kind == .action ? "uitgevoerd" : "gelezen")
            var result = BridgeRPC.ToolResult(text: shielded(output, app))
            if spec.name == UIDriver.lookTool, let picture = UIDriver.takePicture() {
                result.imageBase64 = picture.base64
                result.imageMimeType = picture.mediaType
            }
            return result
        } catch {
            audit(.nookUse, caller, spec.name, "mislukt: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    /// The screen is the user's again: the cursor and the strip in the notch go.
    func releaseScreen() {
        screenGrant = nil
        screenExpiry?.cancel()
        screenExpiry = nil
        // Nook's own task keeps its cursor.
        guard !TakeoverState.shared.isRunning else { return }
        UIDriver.onAct = nil
        TakeoverCursor.shared.hide()
        app?.viewModel.endWork()
    }

    /// What the agent does on the screen, in the strip under the notch, with Stop.
    private func showScreenWork(_ line: String) {
        app?.viewModel.showWork(line) { [weak self] in self?.releaseScreen() }
    }

    private static func clock(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }
}
