import Foundation

// The arguments of the newer bridge tools, checked before anything happens: scheduled tasks, pull request watches,
// clicking and typing in Nook's browser, and asking for a secret. Also the ledger that makes a retried call return the
// first answer. Foundation only, so the tests cover every rule here; WorkspaceBridge does the work.

/// An argument an agent got wrong, in words it can act on.
struct BridgeArgumentError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Reading JSON values the way agents send them: a number may arrive as 5, 5.0 or "5".
enum BridgeArgs {
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let number = value as? Int { return number }
        if let number = value as? Double, number.rounded() == number, abs(number) < 1e9 { return Int(number) }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let text = value as? String {
            switch text.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Retries

/// Remembers the answer to a call that carried a `client_request_id`, per caller and tool, so a retry (the agent's MCP
/// client timed out, the agent asked again) gets the same answer instead of a second task or a second run. A call that
/// is still waiting for the user's decision is in flight: a retry then gets no second approval card. Bounded.
struct BridgeRequestLedger: Sendable {
    enum Claim: Equatable, Sendable {
        /// First time: go ahead, and `finish` or `abandon` it afterwards.
        case new
        /// The same call is still waiting (for the user, say).
        case inFlight
        /// The same call already finished with this answer.
        case done(String)
    }

    private var answers: [String: String] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    let capacity: Int

    init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    /// The key of one call; nil without a client_request_id, which means "no deduplication".
    static func key(caller: String, tool: BridgeTool, requestID: Any?) -> String? {
        guard let id = BridgeArgs.string(requestID) else { return nil }
        return caller + "|" + tool.rawValue + "|" + String(id.prefix(200))
    }

    mutating func claim(_ key: String) -> Claim {
        if let answer = answers[key] { return .done(answer) }
        guard pending.insert(key).inserted else { return .inFlight }
        return .new
    }

    /// The call finished: a retry from now on gets `answer`.
    mutating func finish(_ key: String, answer: String) {
        pending.remove(key)
        if answers.updateValue(answer, forKey: key) == nil { order.append(key) }
        while order.count > capacity { answers.removeValue(forKey: order.removeFirst()) }
    }

    /// The call ended without an answer worth repeating (refused, failed): a retry may try again.
    mutating func abandon(_ key: String) { pending.remove(key) }
}

// MARK: - Scheduled tasks

/// A scheduled task as an agent proposes it, checked.
struct BridgeScheduleDraft: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// Each run starts a new session there; nil fields take the caller's folder and agent.
        case newSession(path: String?, agent: String?)
        /// Each run sends the prompt to the calling session.
        case thisSession
    }

    var title: String
    var prompt: String
    var rule: ScheduleRule
    var target: Target
    var permission: PermissionPolicy
    var enabled: Bool
}

/// A change to a scheduled task; nil fields stay as they are.
struct BridgeScheduleChange: Equatable, Sendable {
    var id: UUID
    var title: String?
    var prompt: String?
    var rule: ScheduleRule?
    var permission: PermissionPolicy?
    var enabled: Bool?

    var isEmpty: Bool { title == nil && prompt == nil && rule == nil && permission == nil && enabled == nil }

    func applied(to task: ScheduledTask) -> ScheduledTask {
        var copy = task
        if let title { copy.title = title }
        if let prompt { copy.prompt = prompt }
        if let rule { copy.rule = rule }
        if let enabled { copy.enabled = enabled }
        return copy
    }
}

enum BridgeScheduleArguments {
    static let maxTitle = 80
    static let maxPrompt = 20_000
    /// A week: anything rarer is a fixed time.
    static let maxIntervalMinutes = 7 * 24 * 60
    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The schedule and rights fields that schedule_task and update_scheduled_task share.
    static var scheduleProperties: [String: Any] {
        [
            "every_minutes": ["type": "integer", "description": "Run every this many minutes, counted from when the previous run finished (at least 1, at most \(maxIntervalMinutes))."],
            "at": ["type": "string", "description": "Or run at this local time, \"HH:MM\" (24-hour)."],
            "weekdays": ["type": "array", "items": ["type": "string", "enum": weekdayNames],
                         "description": "With at: only on these days. Default every day."],
            "rights": ["type": "string", "enum": [PermissionPolicy.ask.rawValue, PermissionPolicy.acceptEdits.rawValue],
                       "description": "What each run may do without asking: ask (default) or acceptEdits. Never more than you have."],
            "enabled": ["type": "boolean", "description": "Whether the task is on. Default true for a new task."]
        ]
    }

    /// The schedule in the arguments; nil when none is given.
    static func rule(_ arguments: [String: Any]) -> Result<ScheduleRule?, BridgeArgumentError> {
        // JSON null counts as not given.
        let every = arguments["every_minutes"].flatMap { $0 is NSNull ? nil : $0 }
        let at = BridgeArgs.string(arguments["at"])
        let days = arguments["weekdays"].flatMap { $0 is NSNull ? nil : $0 }
        if every != nil, at != nil {
            return .failure(BridgeArgumentError("Give either every_minutes or at, not both."))
        }
        if let every {
            guard let minutes = BridgeArgs.int(every), (1...maxIntervalMinutes).contains(minutes) else {
                return .failure(BridgeArgumentError("every_minutes must be a whole number from 1 to \(maxIntervalMinutes)."))
            }
            if days != nil { return .failure(BridgeArgumentError("weekdays only go with at.")) }
            return .success(.interval(seconds: minutes * 60))
        }
        guard let at else {
            if days != nil { return .failure(BridgeArgumentError("weekdays only go with at.")) }
            return .success(nil)
        }
        let parts = at.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else {
            return .failure(BridgeArgumentError("at must be a time as \"HH:MM\", for example \"09:30\"."))
        }
        var weekdays = Set<Int>()
        if let days {
            guard let list = days as? [Any] else { return .failure(BridgeArgumentError("weekdays must be a list such as [\"mon\", \"fri\"].")) }
            for day in list {
                guard let name = (day as? String)?.lowercased().prefix(3), let index = weekdayNames.firstIndex(of: String(name)) else {
                    return .failure(BridgeArgumentError("Unknown weekday \"\(day)\"; use sun, mon, tue, wed, thu, fri or sat."))
                }
                weekdays.insert(index + 1)
            }
        }
        return .success(.fixedTime(hour: hour, minute: minute, weekdays: weekdays))
    }

    /// The rights a task asks for: never full rights, and never more than the caller has (when Nook knows that).
    static func permission(_ value: Any?, caller: PermissionPolicy?) -> Result<PermissionPolicy?, BridgeArgumentError> {
        guard let value, !(value is NSNull) else { return .success(nil) }
        guard let raw = BridgeArgs.string(value), let policy = PermissionPolicy(rawValue: raw) else {
            return .failure(BridgeArgumentError("rights must be ask or acceptEdits."))
        }
        if policy == .bypass {
            return .failure(BridgeArgumentError("A scheduled task never runs with full rights; use ask or acceptEdits."))
        }
        if let caller, rank(policy) > rank(caller) {
            return .failure(BridgeArgumentError("A scheduled task cannot have more rights than you (\(caller.rawValue))."))
        }
        return .success(policy)
    }

    private static func rank(_ policy: PermissionPolicy) -> Int {
        switch policy {
        case .ask: return 0
        case .acceptEdits: return 1
        case .bypass: return 2
        }
    }

    private static func text(_ value: Any?, field: String, limit: Int) -> Result<String?, BridgeArgumentError> {
        guard let value, !(value is NSNull) else { return .success(nil) }
        guard let text = BridgeArgs.string(value) else { return .failure(BridgeArgumentError("\(field) must not be empty.")) }
        guard text.count <= limit else { return .failure(BridgeArgumentError("\(field) is too long (at most \(limit) characters).")) }
        return .success(text)
    }

    static func create(_ arguments: [String: Any], caller: PermissionPolicy?) -> Result<BridgeScheduleDraft, BridgeArgumentError> {
        do {
            guard let title = try text(arguments["title"], field: "title", limit: maxTitle).get() else {
                return .failure(BridgeArgumentError("Give the task a title."))
            }
            guard let prompt = try text(arguments["prompt"], field: "prompt", limit: maxPrompt).get() else {
                return .failure(BridgeArgumentError("Give the prompt the task runs."))
            }
            guard let rule = try rule(arguments).get() else {
                return .failure(BridgeArgumentError("Give a schedule: every_minutes, or at with optional weekdays."))
            }
            let target: BridgeScheduleDraft.Target
            switch BridgeArgs.string(arguments["target"]) ?? "new_session" {
            case "new_session":
                target = .newSession(path: BridgeArgs.string(arguments["project_path"]), agent: BridgeArgs.string(arguments["agent"])?.lowercased())
            case "this_session":
                guard BridgeArgs.string(arguments["project_path"]) == nil, BridgeArgs.string(arguments["agent"]) == nil else {
                    return .failure(BridgeArgumentError("project_path and agent only go with target new_session."))
                }
                target = .thisSession
            default:
                return .failure(BridgeArgumentError("target must be new_session or this_session."))
            }
            let permission = try permission(arguments["rights"], caller: caller).get() ?? .ask
            let enabled = arguments["enabled"].flatMap(BridgeArgs.bool) ?? true
            return .success(BridgeScheduleDraft(title: title, prompt: prompt, rule: rule, target: target,
                                                permission: permission, enabled: enabled))
        } catch {
            // `Result.get()` throws its own error type, so this is always a BridgeArgumentError.
            return .failure(error)
        }
    }

    static func update(_ arguments: [String: Any], caller: PermissionPolicy?) -> Result<BridgeScheduleChange, BridgeArgumentError> {
        guard let raw = BridgeArgs.string(arguments["task_id"]), let id = UUID(uuidString: raw) else {
            return .failure(BridgeArgumentError("Give the task_id from list_scheduled_tasks."))
        }
        do {
            var change = BridgeScheduleChange(id: id)
            change.title = try text(arguments["title"], field: "title", limit: maxTitle).get()
            change.prompt = try text(arguments["prompt"], field: "prompt", limit: maxPrompt).get()
            change.rule = try rule(arguments).get()
            change.permission = try permission(arguments["rights"], caller: caller).get()
            if let value = arguments["enabled"], !(value is NSNull) {
                guard let flag = BridgeArgs.bool(value) else { return .failure(BridgeArgumentError("enabled must be true or false.")) }
                change.enabled = flag
            }
            guard !change.isEmpty else {
                return .failure(BridgeArgumentError("Nothing to change: give a title, prompt, schedule, rights or enabled."))
            }
            return .success(change)
        } catch {
            // `Result.get()` throws its own error type, so this is always a BridgeArgumentError.
            return .failure(error)
        }
    }

    /// "every 30 min", "at 09:00 every day", "at 09:00 on mon, fri", "when its webhook is called".
    static func describe(_ rule: ScheduleRule) -> String {
        switch rule {
        case .interval(let seconds):
            let minutes = max(1, seconds / 60)
            return minutes % 60 == 0 ? "every \(minutes / 60) h" : "every \(minutes) min"
        case .fixedTime(let hour, let minute, let weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            let days = weekdays.sorted().compactMap { (1...7).contains($0) ? weekdayNames[$0 - 1] : nil }
            return days.isEmpty || days.count == 7 ? "at \(time) every day" : "at \(time) on " + days.joined(separator: ", ")
        case .webhook:
            return "when its webhook is called"
        }
    }

    /// One task for list_scheduled_tasks. The prompt is cut short: the list is for finding a task, not reading it.
    static func render(_ task: ScheduledTask, permission: PermissionPolicy, running: Bool) -> String {
        let iso = ISO8601DateFormatter()
        var line = "- \(task.id.uuidString) · \(task.title) · \(describe(task.rule)) · " + (task.enabled ? "on" : "off")
        switch task.target {
        case .newSession(let path, let provider, _): line += " · new \(provider) session in \(path)"
        case .existingSession(let id): line += " · message to session \(id.uuidString)"
        }
        line += " · rights \(permission.rawValue)"
        if running { line += " · running now" }
        if let next = task.nextRun { line += " · next \(iso.string(from: next))" }
        if let last = task.lastRun {
            line += " · last \(iso.string(from: last))" + (task.lastStatus.map { " (\($0.rawValue))" } ?? "")
        }
        let prompt = task.prompt.replacingOccurrences(of: "\n", with: " ")
        line += "\n  prompt: " + (prompt.count > 160 ? String(prompt.prefix(160)) + "…" : prompt)
        return line
    }
}

// MARK: - Pull requests

enum BridgePullRequestTarget {
    enum Parsed: Equatable, Sendable {
        /// The pull request of the caller's branch.
        case current
        case ref(PullRequestRef)
    }

    static var properties: [String: Any] {
        [
            "url": ["type": "string", "description": "The pull request's address. Optional."],
            "number": ["type": "integer", "description": "The pull request's number, in repository (default: your folder's remote). Optional."],
            "repository": ["type": "string", "description": "With number: owner/repo. Optional."]
        ]
    }

    static func parse(_ arguments: [String: Any]) -> Result<Parsed, BridgeArgumentError> {
        if let url = BridgeArgs.string(arguments["url"]) {
            guard let ref = PullRequestRef.parse(url), ref.repository != nil else {
                return .failure(BridgeArgumentError("Nook does not recognise \"\(url)\" as a pull request address."))
            }
            return .success(.ref(ref))
        }
        let repository = BridgeArgs.string(arguments["repository"])
        if let value = arguments["number"], !(value is NSNull) {
            guard let number = BridgeArgs.int(value), number > 0 else {
                return .failure(BridgeArgumentError("number must be a positive whole number."))
            }
            if let repository {
                guard let ref = PullRequestRef.parse(repository + "#\(number)") else {
                    return .failure(BridgeArgumentError("repository must look like owner/repo."))
                }
                return .success(.ref(ref))
            }
            return .success(.ref(PullRequestRef(host: nil, hostName: nil, repository: nil, number: number, url: nil)))
        }
        if repository != nil { return .failure(BridgeArgumentError("repository goes with number.")) }
        return .success(.current)
    }
}

/// A pull request's status for get_pull_request_status, from the snapshot Nook's own watches use. Reviews and comments
/// come from other people: only who gave which verdict, and how many comments, never their text.
enum BridgePullRequestStatus {
    static func render(_ snapshot: PullRequestSnapshot, url: String) -> String {
        var lines = ["# Pull request \(url)", "State: \(snapshot.state)"]
        switch snapshot.checks {
        case "": lines.append("Checks: none")
        case "failure":
            lines.append("Checks: failure" + (snapshot.failedChecks.isEmpty ? "" : " (" + snapshot.failedChecks.prefix(12).joined(separator: ", ") + ")"))
        default: lines.append("Checks: \(snapshot.checks)")
        }
        // Each author's latest verdict; a plain comment does not undo an approval or a change request.
        var verdicts: [String: String] = [:]
        var order: [String] = []
        for review in snapshot.reviews where !review.verdict.isEmpty {
            if verdicts[review.author] == nil { order.append(review.author) }
            if review.verdict == "COMMENTED", let previous = verdicts[review.author], previous != "COMMENTED" { continue }
            verdicts[review.author] = review.verdict
        }
        lines.append("Reviews: " + (order.isEmpty ? "none"
            : order.map { "@\($0) " + (verdicts[$0] ?? "").lowercased().replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")))
        lines.append("Comments: \(snapshot.comments.count)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Browser interaction

/// The JavaScript behind browser_snapshot, browser_click, browser_type and browser_wait_for. Everything the agent sends
/// goes in as one JSON value, never pasted into the code, so a selector or text cannot break out of its string.
enum BridgeBrowserScript {
    /// How an element is found; one of these is needed.
    struct Target: Equatable, Sendable {
        var ref: String?
        var selector: String?
        var text: String?

        var json: [String: String] {
            var object: [String: String] = [:]
            if let ref { object["ref"] = ref }
            if let selector { object["selector"] = selector }
            if let text { object["text"] = text }
            return object
        }

        var summary: String { ref.map { "ref " + $0 } ?? selector.map { "selector " + $0 } ?? text.map { "text \"\($0)\"" } ?? "" }
    }

    static var targetProperties: [String: Any] {
        [
            "ref": ["type": "string", "description": "The element's ref from browser_snapshot, such as \"e7\". Preferred."],
            "selector": ["type": "string", "description": "Or a CSS selector."],
            "text": ["type": "string", "description": "Or the visible text of a link, button or label."]
        ]
    }

    static func target(_ arguments: [String: Any]) -> Result<Target, BridgeArgumentError> {
        let target = Target(ref: BridgeArgs.string(arguments["ref"]), selector: BridgeArgs.string(arguments["selector"]),
                            text: BridgeArgs.string(arguments["text"]))
        let given = [target.ref, target.selector, target.text].compactMap { $0 }.count
        guard given == 1 else {
            return .failure(BridgeArgumentError(given == 0 ? "Say which element: ref (from browser_snapshot), selector or text."
                                                           : "Give only one of ref, selector and text."))
        }
        if let ref = target.ref, !ref.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return .failure(BridgeArgumentError("A ref looks like \"e7\"; take it from browser_snapshot."))
        }
        return .success(target)
    }

    /// A value as a JavaScript literal (JSON is valid JavaScript).
    static func literal(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]) else { return "null" }
        let array = String(decoding: data, as: UTF8.self)
        // "[x]" → "x"; U+2028/2029 are valid JSON but end a line in older JavaScript.
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Finds the element for a target, shared by click and type. Visible text matches exactly first, then as a part.
    private static let finder = """
    function __nookFind(t) {
      if (t.ref) return document.querySelector('[data-nook-ref="' + t.ref + '"]');
      if (t.selector) { try { return document.querySelector(t.selector); } catch (e) { throw new Error('Invalid CSS selector.'); } }
      var want = (t.text || '').trim().toLowerCase();
      var all = Array.prototype.slice.call(document.querySelectorAll('a,button,input[type=button],input[type=submit],[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],label,summary,option'));
      var shown = function (e) { return e.getClientRects().length > 0; };
      var name = function (e) { return ((e.innerText || e.value || e.getAttribute('aria-label') || '') + '').trim().toLowerCase(); };
      return all.find(function (e) { return shown(e) && name(e) === want; }) || all.find(function (e) { return shown(e) && name(e).indexOf(want) >= 0; }) || null;
    }
    function __nookDescribe(e) {
      var label = ((e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '') + '').trim().replace(/\\s+/g, ' ');
      return e.tagName.toLowerCase() + (label ? ' "' + label.slice(0, 80) + '"' : '');
    }
    """

    /// Gives every visible element you can use a ref and lists them with the headings, as JSON text.
    static func snapshot(limit: Int) -> String {
        """
        (function () {
          var limit = \(max(1, min(limit, 400)));
          var nodes = document.querySelectorAll('a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=textbox],[contenteditable=true],h1,h2,h3');
          var lines = [], n = 0, more = false;
          document.querySelectorAll('[data-nook-ref]').forEach(function (e) { e.removeAttribute('data-nook-ref'); });
          for (var i = 0; i < nodes.length; i++) {
            var e = nodes[i];
            if (lines.length >= limit) { more = true; break; }
            if (e.getClientRects().length === 0 || e.type === 'hidden') continue;
            var tag = e.tagName.toLowerCase();
            var text = ((e.innerText || e.getAttribute('aria-label') || e.getAttribute('title') || '') + '').trim().replace(/\\s+/g, ' ').slice(0, 100);
            if (/^h[1-3]$/.test(tag)) { if (text) lines.push(tag + ' ' + JSON.stringify(text)); continue; }
            n += 1;
            var ref = 'e' + n;
            e.setAttribute('data-nook-ref', ref);
            var role = e.getAttribute('role') || (tag === 'input' ? 'input[' + (e.type || 'text') + ']' : tag);
            var line = '[' + ref + '] ' + role;
            if (text) line += ' ' + JSON.stringify(text);
            if (tag === 'input' || tag === 'textarea' || tag === 'select') {
              var label = e.labels && e.labels[0] ? e.labels[0].innerText.trim() : '';
              if (label) line += ' label=' + JSON.stringify(label.slice(0, 60));
              if (e.name) line += ' name=' + JSON.stringify(e.name);
              if (e.placeholder) line += ' placeholder=' + JSON.stringify(e.placeholder.slice(0, 60));
              if (e.type === 'password') line += e.value ? ' value=(hidden)' : '';
              else if (e.type === 'checkbox' || e.type === 'radio') line += e.checked ? ' checked' : ' unchecked';
              else if (e.value) line += ' value=' + JSON.stringify(String(e.value).slice(0, 80));
              if (e.disabled) line += ' disabled';
            }
            if (tag === 'a' && e.getAttribute('href')) line += ' href=' + JSON.stringify(e.getAttribute('href').slice(0, 120));
            lines.push(line);
          }
          return JSON.stringify({ title: document.title, url: location.href, lines: lines, more: more });
        })()
        """
    }

    static func click(_ target: Target) -> String {
        """
        (function () {
        \(finder)
          var e = __nookFind(\(literal(target.json)));
          if (!e) return JSON.stringify({ ok: false, error: 'No such element on the page. Take a new browser_snapshot.' });
          if (e.disabled) return JSON.stringify({ ok: false, error: 'That element is disabled.' });
          e.scrollIntoView({ block: 'center' });
          if (e.focus) e.focus();
          e.click();
          return JSON.stringify({ ok: true, element: __nookDescribe(e) });
        })()
        """
    }

    /// Types through the field's own value setter and fires input and change, so frameworks such as React see it.
    static func type(_ target: Target, value: String, append: Bool, submit: Bool) -> String {
        """
        (function () {
        \(finder)
          var e = __nookFind(\(literal(target.json)));
          if (!e) return JSON.stringify({ ok: false, error: 'No such element on the page. Take a new browser_snapshot.' });
          if (e.tagName === 'LABEL' && e.control) e = e.control;
          if (e.disabled || e.readOnly) return JSON.stringify({ ok: false, error: 'That field cannot be edited.' });
          var value = \(literal(value)), append = \(append ? "true" : "false");
          e.scrollIntoView({ block: 'center' });
          if (e.focus) e.focus();
          if (e.isContentEditable) {
            if (!append) { document.execCommand('selectAll', false, null); }
            document.execCommand('insertText', false, value);
          } else if ('value' in e) {
            var next = append ? String(e.value || '') + value : value;
            var proto = Object.getPrototypeOf(e);
            var setter = Object.getOwnPropertyDescriptor(proto, 'value');
            if (setter && setter.set) setter.set.call(e, next); else e.value = next;
            e.dispatchEvent(new Event('input', { bubbles: true }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            return JSON.stringify({ ok: false, error: 'That element is not a field you can type in.' });
          }
          var submitted = false;
          if (\(submit ? "true" : "false")) {
            var form = e.form || (e.closest ? e.closest('form') : null);
            if (form && form.requestSubmit) { form.requestSubmit(); submitted = true; }
            else {
              ['keydown', 'keypress', 'keyup'].forEach(function (kind) {
                e.dispatchEvent(new KeyboardEvent(kind, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
              });
              submitted = true;
            }
          }
          return JSON.stringify({ ok: true, element: __nookDescribe(e), submitted: submitted });
        })()
        """
    }

    /// True (as JSON text) when the condition holds now; called repeatedly until it does.
    static func condition(text: String?, selector: String?, gone: Bool) -> String {
        """
        (function () {
          var text = \(literal(text ?? "")), selector = \(literal(selector ?? ""));
          var found = true;
          if (text) found = !!(document.body && document.body.innerText.indexOf(text) >= 0);
          if (found && selector) { try { found = !!document.querySelector(selector); } catch (e) { return JSON.stringify({ error: 'Invalid CSS selector.' }); } }
          return JSON.stringify({ met: \(gone ? "!found" : "found") });
        })()
        """
    }

    /// The `{ok, error, …}` object a script returned.
    static func result(_ value: Any?) -> [String: Any] {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }
}

// MARK: - Secrets

/// A secret an agent asks for by name. The value lives in Nook's keychain (SecretStore) under its own prefix, so an
/// agent can only ever reach secrets kept for agents, never Nook's own keys and tokens. It is handed to the agent between
/// markers, which Nook's timeline replaces before it stores or shows a tool's output.
enum BridgeSecret {
    static let accountPrefix = "agent-secret."
    static let open = "<nook-secret>"
    static let close = "</nook-secret>"
    static let hidden = "<nook-secret>(hidden by Nook)</nook-secret>"

    /// The name as given, or nil when it is not one: 1–64 letters, digits, dot, dash or underscore.
    static func name(_ value: Any?) -> String? {
        guard let name = BridgeArgs.string(value), (1...64).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              name.first != ".", !name.contains("..") else { return nil }
        return name
    }

    /// The keychain account: names are not case-sensitive.
    static func account(_ name: String) -> String { accountPrefix + name.lowercased() }

    static func envelope(name: String, value: String) -> String {
        "The value of \(name) is between the markers (the markers are not part of it): \(open)\(value)\(close)"
    }

    /// The text with every secret value replaced; unchanged when it holds none.
    static func redact(_ text: String) -> String {
        guard text.contains(open) else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: open) {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: close) else {
                // An unfinished marker (clipped output): hide everything after it.
                return result + hidden
            }
            result += hidden
            rest = rest[end.upperBound...]
        }
        return result + rest
    }
}
