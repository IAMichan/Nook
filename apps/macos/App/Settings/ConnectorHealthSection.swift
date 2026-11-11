import SwiftUI

/// Settings › Connections: the connectors that are broken right now, each with why in plain words and one "Fix it" button
/// (`ConnectorHealth`): sign in again where the sign-in is the problem, read again where the service was only away. It
/// shows nothing while every connector works, so a calm page stays calm.
struct ConnectorHealthSection: View {
    @EnvironmentObject private var app: AppModel
    /// Redraws when a source was read again.
    @ObservedObject private var hub: ConnectorHub

    init(hub: ConnectorHub) { self.hub = hub }

    private var entries: [ConnectorHealthEntry] {
        ConnectorHealth.entries(hub.active.map { source -> (id: String, title: String, kind: ConnectorErrorKind?, detail: String) in
            if case .error(let message) = source.status.state {
                return (id: source.id, title: source.title, kind: source.status.errorKind ?? .other, detail: message)
            }
            return (id: source.id, title: source.title, kind: nil, detail: "")
        })
    }

    var body: some View {
        let broken = entries
        if !broken.isEmpty {
            Section {
                ForEach(broken) { entry in
                    HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(entry.title)
                                .font(NookTheme.TextStyle.body)
                                .foregroundStyle(NookTheme.textStrong)
                            Text(tr(entry.reasonKey))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.coral)
                                .fixedSize(horizontal: false, vertical: true)
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(NookTheme.TextStyle.caption)
                                    .foregroundStyle(NookTheme.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: NookTheme.Spacing.sm)
                        NookGhostButton(title: tr(entry.fix.titleKey), compact: true) { fix(entry) }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(tr("connectors.health.title"))
            }
        }
    }

    private func fix(_ entry: ConnectorHealthEntry) {
        switch entry.fix {
        case .reconnect, .inspect:
            app.openSettings(section: .connections)
        case .retry:
            guard let source = hub.sources.first(where: { $0.id == entry.id }) else { return }
            Task { await source.refresh() }
        }
    }
}
