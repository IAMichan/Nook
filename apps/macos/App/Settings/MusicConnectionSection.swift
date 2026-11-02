import SwiftUI
import AppKit

/// Settings › Connections › Music: what "Add to queue" in the Music tab goes through. Spotify needs a sign-in with the
/// user's own Spotify app (its client ID); Music needs nothing but the Accessibility permission Nook already asks for.
struct MusicConnectionSection: View {
    @ObservedObject private var spotify = SpotifySignIn.shared
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var copiedRedirect = false

    var body: some View {
        Section {
            if spotify.isSignedIn {
                HStack {
                    Label(tr("music.connect.spotifyConnected"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(NookTheme.mint)
                    Spacer()
                    Button(tr("music.connect.signOut"), role: .destructive) { spotify.signOut() }
                }
                SettingNote(tr("music.connect.spotifyConnectedDetail"))
            } else {
                SettingNote(tr("music.connect.spotifySteps"))
                // The redirect the user pastes into the Spotify dashboard: selectable, and one click to copy.
                LabeledContent(tr("music.connect.redirectURI")) {
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
                }
                HStack {
                    TextField(tr("music.connect.clientID"), text: $clientID)
                        .textFieldStyle(.roundedBorder)
                        .font(NookTheme.mono(12))
                    Button {
                        NSWorkspace.shared.open(SpotifyWebAPI.dashboardURL)
                    } label: {
                        Label(tr("music.connect.dashboard"), systemImage: "arrow.up.forward.app")
                    }
                }
                HStack {
                    switch spotify.phase {
                    case .waiting:
                        ProgressView().controlSize(.small)
                        Text(tr("connect.waiting", "Spotify")).font(NookTheme.TextStyle.detail)
                        Button(tr("button.cancel")) { spotify.cancel() }
                    default:
                        Button {
                            spotify.signIn(clientID: clientID)
                        } label: {
                            Label(tr("music.connect.spotifyButton"), systemImage: "person.badge.key.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Spacer()
                }
                if case .failed(let message) = spotify.phase {
                    SettingNote(message, tone: .error)
                }
            }
            SettingNote(tr("music.connect.appleMusic"))
        } header: {
            Text(tr("music.connect.title"))
        }
    }
}
