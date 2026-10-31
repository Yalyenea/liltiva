import Combine
import Foundation
import MediaPlayer

/// The system advances its own clock between publications. Keep a slow
/// correction cadence, but publish transport changes and clock drift at once.
struct NowPlayingProgressPublication {
    private var previous: (elapsed: TimeInterval, rate: Double, time: TimeInterval)?

    mutating func shouldPublish(elapsed: TimeInterval, rate: Double,
                               at time: TimeInterval, periodic: Bool = false) -> Bool {
        if periodic, let previous, previous.rate == rate {
            let interval = time - previous.time
            let expected = previous.elapsed + interval * previous.rate
            if interval < 10, abs(elapsed - expected) < 0.5 { return false }
        }
        previous = (elapsed, rate, time)
        return true
    }
}

/// System Now Playing integration: media keys, Control Center, lock-screen metadata.
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private weak var player: PlayerService?
    private var artworkTask: Task<Void, Never>?
    private var playbackStateCancellables: Set<AnyCancellable> = []
    private var info: [String: Any] = [:]
    private var progressPublication = NowPlayingProgressPublication()

    private init() {}

    func attach(to player: PlayerService) {
        self.player = player
        playbackStateCancellables.removeAll()
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if !player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            player.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            player?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            player?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player?.seek(to: event.positionTime)
            return .success
        }

        // Like feedback (Control Center; isActive = hearted)
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = String(localized: "喜欢")
        center.likeCommand.localizedShortTitle = String(localized: "喜欢")
        center.likeCommand.addTarget { [weak player] _ in
            guard let track = player?.currentTrack else { return .noActionableNowPlayingItem }
            Task { @MainActor in
                await AccountStore.shared.toggleLike(trackID: track.id)
                NowPlayingManager.shared.refreshLikeState()
            }
            return .success
        }

        // Keep previous/next as the system media controls for this music player.
        // Shuffle and repeat mirror the active queue settings.
        center.changeShuffleModeCommand.addTarget { [weak player] event in
            guard let player,
                  let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantOn = event.shuffleType != .off
            if player.shuffleEnabled != wantOn { player.toggleShuffle() }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak player] event in
            guard let player,
                  let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            // MPRepeatType: .off / .one / .all → RepeatMode: .off / .one / .all
            let target: RepeatMode? = switch event.repeatType {
                case .off:  .off
                case .one:  .one
                case .all:  .all
                default:    nil
            }
            if let target, player.repeatMode != target { player.repeatMode = target }
            return .success
        }

        // Shuffle is one of the queue orders (`shuffleEnabled` is
        // derived), so observe the order and map it back to on/off.
        player.$queueOrder
            .map { $0 == .shuffled }
            .removeDuplicates()
            .sink { enabled in
                center.changeShuffleModeCommand.currentShuffleType = enabled ? .items : .off
            }
            .store(in: &playbackStateCancellables)

        player.$repeatMode
            .removeDuplicates()
            .sink { mode in
                center.changeRepeatModeCommand.currentRepeatType = switch mode {
                case .off: .off
                case .one: .one
                case .all: .all
                }
            }
            .store(in: &playbackStateCancellables)
    }

    /// Reflects the current track's hearted state on the like command.
    func refreshLikeState() {
        guard let track = player?.currentTrack else {
            MPRemoteCommandCenter.shared().likeCommand.isActive = false
            return
        }
        MPRemoteCommandCenter.shared().likeCommand.isActive =
            AccountStore.shared.isLiked(track.id)
    }

    func updateMetadata(for track: Track, duration: TimeInterval) {
        info = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistNames,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            // Declare the session as audio so system surfaces treat it as a
            // complete now-playing app (best-effort hardening for #36/#40).
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        publishCurrentPlayback()
        refreshLikeState()

        artworkTask?.cancel()
        // 1024px: the lock screen's tap-to-fullscreen artwork presentation
        // needs high-resolution art to engage.
        guard let url = track.album.picUrl?.resizedImageURL(1024) else { return }
        artworkTask = Task { [weak self] in
            let apply: ImageCache.CachedImageHandler = { [weak self] image in
                guard let self, !Task.isCancelled else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.info[MPMediaItemPropertyArtwork] = artwork
                // Artwork can arrive between clock corrections. Publish the
                // live position with it so old metadata never rewinds the clock.
                self.publishCurrentPlayback()
            }
            if let image = await ImageCache.shared.image(for: url, onCachedImage: apply) {
                apply(image)
            }
        }
    }

    private func publishCurrentPlayback() {
        updateElapsed(player?.livePlaybackTime ?? 0, rate: player?.isPlaying == true ? 1 : 0)
    }

    func updateElapsed(_ elapsed: TimeInterval, rate: Double, periodic: Bool = false) {
        guard progressPublication.shouldPublish(elapsed: elapsed, rate: rate,
                                                at: ProcessInfo.processInfo.systemUptime,
                                                periodic: periodic) else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        progressPublication = NowPlayingProgressPublication()
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
    }
}
