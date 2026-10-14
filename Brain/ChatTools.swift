import Foundation

/// Tools that display interactive content directly in chat: a chart or an email draft. They execute immediately (like read tools)
/// because nothing happens outside Nook yet: an email is only sent when the user clicks "Send".
@MainActor
enum ChatTools {
    static func specs(onChart: @escaping (ChatChart) -> Void, onMail: @escaping (MailDraft) -> Void) -> [ToolSpec] {
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
                description: "Composes a complete email and displays it as a draft in chat. The user can review/edit it there and send with one click or open in Mail. ALWAYS use this when the user asks to write, draft, reply to, or forward an email. Write the entire email in body, including greeting and sign-off, in appropriate tone and language for the recipient. Look up the address in context, on screen, or using search_mail; if unknown, leave to empty and mention it in your answer. Do not repeat the email body in your answer: summarize what you wrote in one sentence.",
                schema: [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Recipient email address(es), comma-separated. Empty if unknown."],
                        "cc": ["type": "string", "description": "CC email address(es), optional."],
                        "subject": ["type": "string", "description": "Subject line. For replies: \"Re: \" followed by original subject."],
                        "body": ["type": "string", "description": "Full text of the email, excluding subject line."]
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
                    let draft = MailDraft(
                        to: ((input["to"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        cc: ((input["cc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        subject: subject,
                        body: body
                    )
                    onMail(draft)
                    return "The email draft is displayed in chat. The user will review it and send it using the Send button."
                }
            )
        ]
    }
}
