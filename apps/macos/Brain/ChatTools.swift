import Foundation

/// Tools that display interactive content directly in chat: a chart, an email draft or a step-by-step plan. They execute
/// immediately (like read tools) because nothing happens outside Nook yet: an email is only sent when the user clicks "Send".
@MainActor
enum ChatTools {
    /// The plan Nook keeps while it works through a request of several steps, shown as a checklist with its answer.
    static let planTool = "update_plan"

    static func specs(onChart: @escaping (ChatChart) -> Void, onMail: @escaping (MailDraft) -> Void, mailAddress: @escaping (String) async -> String? = { _ in nil },
                      ownAddress: @escaping () -> String = { "" }, onPlan: @escaping ([RunTaskStep]) -> Void) -> [ToolSpec] {
        let point: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "Category or point on the x-axis, e.g. \"Mon\", \"Jan\", or \"Amsterdam\"."],
                "value": ["type": "number", "description": "The numeric value."]
            ],
            "required": ["label", "value"]
        ]
        let series: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Name of the series (for the legend)."],
                "points": ["type": "array", "items": point, "description": "The data points in display order."]
            ],
            "required": ["name", "points"]
        ]

        return [
            ToolSpec(
                name: "show_chart",
                description: "Renders a chart in chat. ALWAYS use this when the user asks for a chart, diagram, plot, or visualization, and also proactively when numerical trends or category comparisons are clearer as a visual. Fetch data first using other tools or web search if necessary; use only genuine figures or user-provided data, never fabricate. Choose bar for comparisons, line or area for trends over time, pie for breakdown of a whole (max 6 slices), point for scatter plots. After rendering, state the main takeaway in one or two sentences; do not repeat all raw numbers.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short title above the chart."],
                        "type": ["type": "string", "enum": ChatChart.Kind.allCases.map(\.rawValue), "description": "Type of chart."],
                        "unit": ["type": "string", "description": "Unit of measurement, e.g. \"€\", \"hours\", or \"%\". Optional."],
                        "series": ["type": "array", "items": series, "description": "One or more data series (max 4 for lines and bars). For pie charts, exactly one series."]
                    ],
                    "required": ["title", "type", "series"]
                ],
                kind: .read,
                summarize: { input in "Chart: \((input["title"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    guard let chart = ChatChart.parse(input) else {
                        throw NookError("No usable data: provide series with points (label and value).")
                    }
                    onChart(chart)
                    return "The chart \"\(chart.title)\" is now displayed in chat with your answer. Do not describe it again point by point."
                }
            ),
            ToolSpec(
                name: "compose_mail",
                description: "Composes a complete email and displays it as a draft in chat. The user can review/edit it there and send with one click or open in Mail. ALWAYS use this when the user asks to write, draft, reply to, or forward an email. Write the entire email in body, including greeting and sign-off, in appropriate tone and language for the recipient. To answer a received mail, set reply_to to its id (from inbox_mail, search_mail or read_mail): Mail then sends it as a reply in the same thread, from the account it came to. Match the user's own way of writing: if their sent mail to this person is in context (search_mail with mailbox sent), follow its greeting, tone, length and sign-off, and write in the language the other person wrote in. Look up the address in context, on screen, or using search_mail; if unknown, leave to empty and mention it in your answer. You may call compose_mail several times in one answer, once per mail, when several mails need an answer. When the user asks to change a draft, call compose_mail again with the whole new version: it replaces the open draft right away, without asking. Never use take_over for an email, and never propose another step to send it: the user sends it from the draft. Do not repeat the email body in your answer: summarize what you wrote in one sentence.",
                schema: [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Recipient email address(es), comma-separated, or the person's name: Nook fills in the address from Contacts on this Mac. Empty if unknown."],
                        "cc": ["type": "string", "description": "CC email address(es), optional."],
                        "bcc": ["type": "string", "description": "BCC email address(es), optional: only when the user asks for a blind copy."],
                        "from": ["type": "string", "description": "The user's own address to send from, only when they name one (\"vanuit mijn gmail\", \"from work@x.nl\"). Empty: the default account."],
                        "subject": ["type": "string", "description": "Subject line. For replies: \"Re: \" followed by original subject."],
                        "body": ["type": "string", "description": "Full text of the email, excluding subject line."],
                        "reply_to": ["type": "string", "description": "For a reply: the id of the mail it answers (the part after \"id:\" in inbox_mail, search_mail or read_mail). Empty for a new mail."],
                        "invite": [
                            "type": "object",
                            "description": "Makes this mail a real calendar invitation for everyone in to and cc (an invite.ics they accept or decline in their own calendar). Use it whenever the user plans a meeting, call or appointment with other people and wants them invited. Also put the appointment in the user's own calendar with create_event (same title and times).",
                            "properties": [
                                "title": ["type": "string", "description": "Title of the appointment."],
                                "start": ["type": "string", "description": "Start, ISO 8601 with timezone (from find_time or check_availability)."],
                                "end": ["type": "string", "description": "End, ISO 8601 with timezone. Default one hour after start."],
                                "location": ["type": "string", "description": "Place or video link, optional."],
                                "notes": ["type": "string", "description": "Agenda or details, optional."]
                            ],
                            "required": ["title", "start"]
                        ]
                    ],
                    "required": ["subject", "body"]
                ],
                kind: .read,
                summarize: { input in "Email: \((input["subject"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let subject = ((input["subject"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = ((input["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { throw NookError("The email body is missing.") }
                    // A name becomes its address here on the Mac; the brain never hears it, so Contacts can stay on this Mac.
                    var draft = MailDraft(
                        to: await ActionGate.addressed((input["to"] as? String) ?? "", lookup: mailAddress),
                        cc: await ActionGate.addressed((input["cc"] as? String) ?? "", lookup: mailAddress),
                        subject: subject,
                        body: body,
                        bcc: await ActionGate.addressed((input["bcc"] as? String) ?? "", lookup: mailAddress),
                        from: ((input["from"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    draft.replyTo = MailActions.ids([(input["reply_to"] as? String) ?? ""]).first ?? ""
                    var invited = ""
                    if let fields = input["invite"] as? [String: Any] {
                        let attendees = MailSender.addresses(draft.to) + MailSender.addresses(draft.cc)
                        let organizer = draft.from.isEmpty ? ownAddress() : (MailSender.addresses(draft.from).first ?? "")
                        guard let event = CalendarInvite.event(from: fields, attendees: attendees, organizer: organizer, parse: NookDates.parse) else {
                            throw NookError("The invitation needs a title and a start time (ISO 8601).")
                        }
                        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-invites", isDirectory: true)
                        draft.attachments.append(try CalendarInvite.write(event, in: folder))
                        draft.invite = event
                        invited = " It carries a calendar invitation (\(event.title), \(NookDates.iso(event.start))) for "
                            + (attendees.isEmpty ? "nobody yet: the address is missing, say so" : attendees.joined(separator: ", ")) + "."
                    }
                    onMail(draft)
                    return "The email draft is displayed in chat. The user will review it and send it using the Send button." + invited
                }
            ),
            ToolSpec(
                name: planTool,
                description: "Shows your step-by-step plan in chat as a live checklist above your answer. Use it for a request that takes several steps (three or more tool calls, research across several sources, or a task with distinct parts): call it first with every step as pending and the first as in_progress, call it again with the whole list each time a step finishes, and once more with every step completed before you answer. Exactly one step is in_progress while you work. Skip it for a simple question or a single action. Write each step as a short line in the user's language. Do not repeat the plan in your answer.",
                schema: [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "description": "The whole plan, in order.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "step": ["type": "string", "description": "What this step does, in a few words."],
                                    "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]]
                                ],
                                "required": ["step", "status"]
                            ]
                        ]
                    ],
                    "required": ["steps"]
                ],
                kind: .read,
                summarize: { input in "Plan: \(((input["steps"] as? [Any]) ?? []).count) steps" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    guard let steps = plan(input) else { throw NookError("No steps: provide steps with step and status.") }
                    onPlan(steps)
                    return "The plan is displayed in chat. Keep it current with \(planTool) as you work; do not repeat it in your answer."
                }
            )
        ]
    }

    /// The steps of an `update_plan` call, nil when it holds none. Unknown statuses read as pending.
    static func plan(_ input: [String: Any]) -> [RunTaskStep]? {
        guard let raw = input["steps"] as? [[String: Any]] else { return nil }
        let steps = raw.compactMap { entry -> RunTaskStep? in
            let text = ((entry["step"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : RunTaskStep(text: text, status: RunTasks.status(entry["status"] as? String))
        }
        return steps.isEmpty ? nil : steps
    }
}
