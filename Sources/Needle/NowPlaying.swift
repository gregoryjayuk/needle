import AppKit
import MediaPlayer

/// Puts the server's song into macOS's Now Playing (Control Center's media tile, with its cover and
/// scrubber) and answers the keyboard's play/pause, next and previous keys while it's playing.
/// On macOS an app claims Now Playing through `playbackState` — no audio of its own needed.
/// Offline or switched off, it lets go entirely, so the keys go back to whatever else is playing.
@MainActor
final class NowPlayingBridge {
    private weak var player: Player?
    private var enabled = false
    private var artworkKey: String?
    private var artwork: MPMediaItemArtwork?

    init(player: Player) {
        self.player = player
        let cc = MPRemoteCommandCenter.shared()
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.dispatch { $0.togglePlay() } ?? .commandFailed }
        cc.playCommand.addTarget { [weak self] _ in self?.dispatch { $0.play() } ?? .commandFailed }
        cc.pauseCommand.addTarget { [weak self] _ in self?.dispatch { $0.pause() } ?? .commandFailed }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.dispatch { $0.next() } ?? .commandFailed }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.dispatch { $0.previous() } ?? .commandFailed }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            return self?.dispatch { $0.seek(to: t) } ?? .commandFailed
        }
        setCommands(enabled: false)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        setCommands(enabled: on)
        if on, let p = player { update(song: p.song, status: p.status, elapsed: p.elapsed(), art: p.art.current) } else { clear() }
    }

    func update(song: MPDSong?, status: MPDStatus, elapsed: Double, art: CoverArt?) {
        guard enabled, let song, status.state != .stop else {
            clear()
            return
        }
        setCommands(enabled: true)
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: status.state == .play ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        let duration = status.duration > 0 ? status.duration : (song.duration ?? 0)
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art {
            if artworkKey != art.key {
                let image = art.image
                artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkKey = art.key
            }
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        }
        center.nowPlayingInfo = info
        center.playbackState = status.state == .play ? .playing : .paused
    }

    func clear() {
        let center = MPNowPlayingInfoCenter.default()
        guard center.nowPlayingInfo != nil || center.playbackState != .stopped else { return }
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        setCommands(enabled: false)
    }

    private func setCommands(enabled on: Bool) {
        let cc = MPRemoteCommandCenter.shared()
        for c in [cc.togglePlayPauseCommand, cc.playCommand, cc.pauseCommand, cc.nextTrackCommand,
                  cc.previousTrackCommand, cc.changePlaybackPositionCommand] {
            c.isEnabled = on
        }
    }

    /// Remote commands can arrive off the main thread; hop over and act.
    private nonisolated func dispatch(_ action: @escaping @MainActor (Player) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let p = self?.player else { return }
            action(p)
        }
        return .success
    }
}
