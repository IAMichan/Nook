import Foundation

/// Adding a track to the queue goes to the player that plays at that moment: Spotify's own queue through its Web API
/// (when the user connected Spotify in Settings), Music's own queue through its Song › Add to Queue menu item. When the
/// player cannot take it (Spotify not connected, no Premium, no Accessibility permission for Music…), Nook keeps the
/// track in a queue of its own and starts it itself: a moment before the playing track ends, when the user presses
/// next, or (when the timer came too late) right after the player moved on by itself at the end of a track. After the
/// last of those the player carries on from wherever that track lives.
extension NowPlayingService {
    /// Puts a track in the playing player's own queue, or in Nook's when the player cannot take it.
    func enqueue(_ track: MusicTrack) {
        let app = current?.app ?? NowPlayingService.runningPlayerName()
        switch app {
        case "Spotify" where Self.isSpotifyURI(track.id):
            guard SpotifySignIn.shared.isSignedIn else {
                keepInNook(track, because: tr("music.queue.connectSpotify", tr("settings.section.connections")))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await SpotifyWebAPI.addToQueue(track.id)
                    ToastCenter.shared.success(tr("music.queue.added", "Spotify"), detail: track.title)
                    self.refreshUpNext()
                } catch let failure as SpotifyWebAPI.Failure {
                    self.keepInNook(track, because: Self.reason(failure))
                } catch {
                    self.keepInNook(track, because: error.localizedDescription)
                }
            }
        case "Music" where Self.isPersistentID(track.id):
            queue.async { [weak self] in
                let added = MusicAppQueue.add(persistentID: track.id)
                Task { @MainActor in
                    guard let self else { return }
                    if added {
                        ToastCenter.shared.success(tr("music.queue.added", tr("tab.music")), detail: track.title)
                    } else {
                        self.keepInNook(track, because: tr("music.queue.musicRefused"))
                    }
                }
            }
        default:
            keepInNook(track, because: nil)
        }
    }

    /// The fallback: Nook's own queue, and a word on why the player's own one was not used.
    private func keepInNook(_ track: MusicTrack, because reason: String?) {
        guard playQueue.append(track) else { return }
        scheduleQueueAdvance()
        ToastCenter.shared.info(tr("music.queue.addedNook"), detail: [track.title, reason].compactMap { $0 }.joined(separator: " · "))
    }

    private static func reason(_ failure: SpotifyWebAPI.Failure) -> String {
        switch failure {
        case .notSignedIn: return tr("music.queue.connectSpotify", tr("settings.section.connections"))
        case .premiumRequired: return tr("music.queue.spotifyPremium")
        case .noActiveDevice: return tr("music.queue.spotifyNoDevice")
        case .missingScope: return tr("music.playlists.reconnectDetail", tr("settings.section.connections"))
        case .failed(let message): return message
        }
    }

    func removeFromQueue(_ id: MusicPlayQueue.Entry.ID) {
        playQueue.remove(id)
        scheduleQueueAdvance()
    }

    func clearQueue() {
        playQueue.clear()
        scheduleQueueAdvance()
    }

    /// Plays a queued track right away and takes it out of the queue.
    func playFromQueue(_ id: MusicPlayQueue.Entry.ID) {
        guard let track = playQueue.take(id) else { return }
        startQueued(track)
    }

    /// Plays the first queued track the current player can play. `false` when there is none (the queue is empty, or
    /// only holds tracks of the other player, which are dropped).
    @discardableResult
    func playNextQueued() -> Bool {
        let app = current?.app ?? NowPlayingService.runningPlayerName()
        while let track = playQueue.take() {
            if Self.canPlay(track, in: app) {
                startQueued(track)
                return true
            }
        }
        scheduleQueueAdvance()
        return false
    }

    /// Called whenever `current` changes: (re)arms the timer that starts the next queued track as the playing one ends.
    func scheduleQueueAdvance() {
        queueAdvanceTask?.cancel()
        queueAdvanceTask = nil
        guard !playQueue.isEmpty, let info = current, info.isPlaying, info.duration > 0 else { return }
        let key = info.trackKey
        // Just before the end, so the player does not get to start its own next track first.
        let remaining = Double(info.duration) - info.estimatedPosition(at: Date()) - 0.6
        queueAdvanceTask = Task { @MainActor [weak self] in
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            guard !Task.isCancelled, let self, let now = self.current, now.trackKey == key, now.isPlaying else { return }
            self.playNextQueued()
        }
    }

    /// The playing track changed. When the player moved on by itself at the end of a track (the timer was late, for
    /// example while the Mac slept), the queue still goes first; a track the user picked in the player is left alone.
    func queueTrackChanged(from old: NowPlayingInfo, to new: NowPlayingInfo?) {
        guard !playQueue.isEmpty, let new, new.app == old.app, Date().timeIntervalSince(queueStartedAt) > 5 else { return }
        if MusicPlayQueue.ended(position: old.estimatedPosition(at: new.capturedAt), duration: old.duration) {
            playNextQueued()
        }
    }

    private func startQueued(_ track: MusicTrack) {
        guard let app = current?.app ?? NowPlayingService.runningPlayerName(), Self.canPlay(track, in: app) else { return }
        queueStartedAt = Date()
        queueAdvanceTask?.cancel()
        queueAdvanceTask = nil
        let verb: String
        if app == "Spotify" {
            verb = "play track \(MusicScriptOutput.quoted(track.id))"
        } else {
            // From the playlist that plays when the track is in it, so Music carries on there afterwards; from the
            // library otherwise.
            let id = MusicScriptOutput.quoted(track.id)
            verb = """
            try
                play (first track of current playlist whose persistent ID is \(id))
            on error
                play (first track of library playlist 1 whose persistent ID is \(id))
            end try
            """
        }
        queue.async { [weak self] in
            _ = NowPlayingService.runPlayerScript("with timeout of 4 seconds\ntell application \"\(app)\"\n\(verb)\nend tell\nend timeout")
            Thread.sleep(forTimeInterval: 0.4)
            Task { @MainActor in
                guard let self else { return }
                self.poll()
                self.refreshUpNext()
            }
        }
    }

    nonisolated static func canPlay(_ track: MusicTrack, in app: String?) -> Bool {
        switch app {
        case "Spotify": return isSpotifyURI(track.id)
        case "Music": return isPersistentID(track.id)
        default: return false
        }
    }
}
