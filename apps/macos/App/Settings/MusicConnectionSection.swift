import SwiftUI
import AppKit

/// Settings › Connections › Music: one Spotify row in the shape of every linked service, with its steps in a sheet.
struct MusicConnectionSection: View {
    @ObservedObject private var spotify = SpotifySignIn.shared
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var app: AppModel

    /// Spotify first, in the one connection row (opening it shows its steps, or its account once linked; signing out is
    /// last in its "…" menu), then what Nook keeps of what you listen to.
    var body: some View {
        Section {
            ConnectionRow(title: "Spotify", status: spotify.isSignedIn ? .connected : .notLinked,
                          detail: tr("music.connect.rowDetail"),
                          removal: spotify.isSignedIn
                              ? ConnectionRemoval(title: tr("music.connect.signOut"), question: tr("confirm.logout", "Spotify"),
                                                  detail: tr("connection.signOutDetail", "Spotify")) { spotify.signOut() }
                              : nil) {
                ServiceTile(domain: "spotify.com", fallback: "music.note", tint: NookTheme.iris, size: 28)
            } expanded: {
                MusicConnectionForm()
            }
            Toggle(isOn: $settings.musicHistory) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(tr("music.history.keep"))
                    Text(tr("music.history.keepDetail"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            HStack {
                Text(tr("music.history.clearTitle"))
                Spacer()
                ConfirmedButton(tr("music.history.clear"), question: tr("music.history.clearQuestion")) { app.nowPlaying.clearHistory() }
            }
        } header: {
            Text(tr("music.connect.title"))
        }
    }
}

/// What "Add to queue" in the Music tab goes through. Spotify needs a sign-in with the user's own Spotify app (its client
/// ID); Music needs nothing but the Accessibility permission Nook already asks for.
private struct MusicConnectionForm: View {
    @ObservedObject private var spotify = SpotifySignIn.shared
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var copiedRedirect = false

    @Environment(\.dismiss) private var dismiss

    /// The same sheet as every connection: numbered steps until Spotify is linked, then its account; Apple Music needs
    /// nothing, said last.
    var body: some View {
        SetupSheet(title: "Spotify", subtitle: tr("music.connect.rowDetail"), status: spotify.isSignedIn ? .working : nil) {
            ServiceTile(domain: "spotify.com", fallback: "music.note", tint: NookTheme.iris, size: 48)
        } content: {
            if spotify.isSignedIn {
                SheetPart(tr("chats.manage.accounts")) {
                    HStack {
                        Label(tr("music.connect.spotifyConnected"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(NookTheme.mint)
                        Spacer()
                        ConfirmedButton(tr("music.connect.signOut"), question: tr("confirm.logout", "Spotify")) { spotify.signOut() }
                    }
                    SettingNote(tr("music.connect.spotifyConnectedDetail"))
                }
            } else {
                SetupStep(number: 1, title: tr("music.connect.stepApp")) {
                    SettingNote(tr("music.connect.spotifySteps"))
                    Button {
                        NSWorkspace.shared.open(SpotifyWebAPI.dashboardURL)
                    } label: {
                        Label(tr("music.connect.dashboard"), systemImage: "arrow.up.forward.app")
                    }
                    // The redirect the user pastes into the Spotify dashboard: selectable, and one click to copy.
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(SpotifyWebAPI.redirectURI)
                            .font(NookTheme.mono(12))
                            .textSelection(.enabled)
                        Button {
                            Pasteboard.copy(SpotifyWebAPI.redirectURI)
                            copiedRedirect = true
                        } label: {
                            Label(copiedRedirect ? tr("button.copied") : tr("button.copy"),
                                  systemImage: copiedRedirect ? "checkmark" : "doc.on.doc")
                        }
                    }
                    .help(tr("music.connect.redirectURI"))
                }
                SetupStep(number: 2, title: tr("music.connect.stepClientID"),
                          done: !clientID.trimmingCharacters(in: .whitespaces).isEmpty) {
                    TextField(tr("music.connect.clientID"), text: $clientID)
                        .textFieldStyle(.roundedBorder)
                        .font(NookTheme.mono(12))
                }
                SetupStep(number: 3, title: tr("hub.signIn.step", "Spotify")) {
                    switch spotify.phase {
                    case .waiting:
                        HStack(spacing: NookTheme.Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text(tr("connect.waiting", "Spotify")).font(NookTheme.TextStyle.detail)
                            Button(tr("button.cancel")) { spotify.cancel() }
                        }
                    default:
                        Button {
                            spotify.signIn(clientID: clientID)
                        } label: {
                            Label(tr("music.connect.spotifyButton"), systemImage: "person.badge.key.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if case .failed(let message) = spotify.phase {
                        SettingNote(message, tone: .error)
                    }
                }
            }
            SheetPart(tr("music.connect.appleMusicTitle")) {
                SettingNote(tr("music.connect.appleMusic"))
            }
        } footer: {
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
