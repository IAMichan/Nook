import Foundation

/// Finding and starting music by name, for Nook Chat and (through the bridge's `nook_use`) for coding agents: the same
/// search as the Music tab (`NowPlayingService.results`) and the same way of playing a track. `media_control` keeps
/// pausing and skipping.
extension AppModel {
    var musicTools: [ToolSpec] {
        let player: [String: Any] = ["type": "string", "enum": ["Spotify", "Music"],
                                     "description": "Which player. Defaults to the one playing, else Spotify when it is connected, else Music."]
        return [
            ToolSpec(
                name: "search_music",
                description: "Searches music by song, artist or album: on Spotify (when connected in Nook) or in the Apple Music library. Returns tracks with their id for play_music.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "What to look for, such as \"Bohemian Rhapsody\" or \"Norah Jones\"."],
                    "player": player
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Search music: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Give what to search for.") }
                    let app = self.musicPlayer(input["player"] as? String)
                    let tracks = try Self.found(await NowPlayingService.results(for: query, app: app))
                    guard !tracks.isEmpty else { return "Nothing found in \(app) for \"\(query)\"." }
                    return (["In \(app):"] + tracks.prefix(15).map { track in
                        "- \(track.title) — \(track.artist) | id \(track.id)"
                    }).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "play_music",
                description: "Starts playing a song: by track id from search_music, or by a search, playing the best match. Use media_control to pause, resume or skip.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Song, artist or album to play, such as \"Clocks Coldplay\"."],
                    "track_id": ["type": "string", "description": "A track id from search_music. Takes precedence over query."],
                    "player": player
                ], "required": []],
                kind: .action,
                summarize: { input in
                    let what = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return what.isEmpty ? "Play music" : "Play \(what)"
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let app = self.musicPlayer(input["player"] as? String)
                    let id = ((input["track_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let track: MusicTrack
                    if !id.isEmpty {
                        guard NowPlayingService.isSpotifyURI(id) || NowPlayingService.isPersistentID(id) else {
                            throw NookError("That is not a track id from search_music.")
                        }
                        track = MusicTrack(id: id, title: query.isEmpty ? id : query, artist: "", duration: 0)
                    } else {
                        guard !query.isEmpty else { throw NookError("Give a song to play or a track id.") }
                        guard let first = try Self.found(await NowPlayingService.results(for: query, app: app)).first else {
                            throw NookError("Nothing found in \(app) for \"\(query)\".")
                        }
                        track = first
                    }
                    self.nowPlaying.play(track, fromQueue: false, app: app)
                    return "Playing \(track.title)" + (track.artist.isEmpty ? "" : " — \(track.artist)") + " in \(app)"
                }
            )
        ]
    }

    /// The player a music tool works in: the one asked for, the one playing, Spotify when connected, else Music.
    private func musicPlayer(_ asked: String?) -> String {
        if let asked, asked == "Spotify" || asked == "Music" { return asked }
        if let playing = nowPlaying.current?.app ?? NowPlayingService.runningPlayerName() { return playing }
        return SpotifySignIn.shared.isSignedIn ? "Spotify" : "Music"
    }

    /// The tracks of a search, or why there are none.
    private static func found(_ result: MusicSearchResult) throws -> [MusicTrack] {
        switch result.state {
        case .connectSpotify: throw NookError("Searching Spotify needs Spotify connected in Nook (Settings › \(tr("settings.section.connections"))).")
        case .failed(let message): throw NookError(message)
        default: return result.tracks
        }
    }
}
