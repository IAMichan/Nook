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
    @StateObject private var copiedRedirect = CopiedMoment()

    @Environment(\.dismiss) private var dismiss

    /// The same sheet as every connection: numbered steps until Spotify is linked, ending in Nook's check, then its
    /// account with signing out on the left of the buttons; Apple Music needs nothing, said last.
    var body: some View {
        SetupSheet(title: "Spotify", subtitle: tr("music.connect.rowDetail"), status: spotify.isSignedIn ? .working : nil) {
            ServiceTile(domain: "spotify.com", fallback: "music.note", tint: NookTheme.iris, size: 48)
        } content: {
            if spotify.isSignedIn {
                SheetPart(tr("chats.manage.accounts")) {
                    Label(tr("music.connect.spotifyConnected"), icon: "checkmark.seal.fill")
                        .foregroundStyle(NookTheme.mint)
                    SettingNote(tr("music.connect.spotifyConnectedDetail"))
                }
            } else {
                SetupStep(number: 1, title: tr("music.connect.stepApp")) {
                    StepAction(detail: tr("music.connect.spotifySteps"), button: tr("music.connect.dashboard"), prominent: false) {
                        NSWorkspace.shared.open(SpotifyWebAPI.dashboardURL)
                    }
                    // The redirect the user pastes into the Spotify dashboard: selectable, and one click to copy.
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(SpotifyWebAPI.redirectURI)
                            .font(NookTheme.mono(12))
                            .textSelection(.enabled)
                        Button {
                            copiedRedirect.copy(SpotifyWebAPI.redirectURI)
                        } label: {
                            Label(copiedRedirect.copied ? tr("button.copied") : tr("button.copy"),
                                  icon: copiedRedirect.copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    .help(tr("music.connect.redirectURI"))
                }
                SetupStep(number: 2, title: tr("music.connect.stepClientID"),
                          done: !clientID.trimmingCharacters(in: .whitespaces).isEmpty) {
                    TextField(tr("music.connect.clientID"), text: $clientID, prompt: Text(tr("music.connect.clientID")).foregroundStyle(NookTheme.textTertiary))
                        .settingsField()
                        .font(NookTheme.mono(12))
                }
                SetupStep(number: 3, title: tr("hub.signIn.step", "Spotify")) {
                    switch spotify.phase {
                    case .waiting:
                        BusyLine(tr("connect.waiting", "Spotify"), tone: .inherited, font: NookTheme.TextStyle.detail)
                        Button(tr("button.cancel")) { spotify.cancel() }
                    default:
                        Button {
                            spotify.signIn(clientID: clientID)
                        } label: {
                            Label(tr("music.connect.spotifyButton"), icon: "person.badge.key.fill")
                        }
                        .buttonStyle(.nookProminent)
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if case .failed(let message) = spotify.phase {
                        SettingNote(message, tone: .error)
                    }
                }
                SetupCheckStep(number: 4, detail: tr("settings2.step.checkAfterSignIn"),
                               state: spotify.isSignedIn ? .passed(tr("music.connect.spotifyConnected")) : .idle)
            }
            SheetPart(tr("music.connect.appleMusicTitle")) {
                SettingNote(tr("music.connect.appleMusic"))
            }
        } footer: {
            if spotify.isSignedIn {
                ConfirmedButton(tr("music.connect.signOut"), question: tr("confirm.logout", "Spotify"),
                                detail: tr("connection.signOutDetail", "Spotify")) { spotify.signOut() }
            }
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .sheetPrimaryButton()
        }
    }
}
