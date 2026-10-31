// Playback, queue management and audio output selection.
import Combine
import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Codable, Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue, comments
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Which lyric line is current.
///
/// Every lyric view used to derive this itself, which meant observing the clock
/// and re-rendering on every tick just to discover the line hadn't changed —
/// and for the now-playing page, whose body is the whole immersive layout, that
/// was five full re-evaluations a second. Computing it once here and publishing
/// only on a change turns that into one re-render per lyric line.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int?
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    private var playbackAccountID: Int?
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    @Published private(set) var isTrial = false
    @Published private(set) var soundEffectState: SoundEffectState = .off
    @Published private(set) var soundEffectPresets: [SoundEffectPreset] = []
    var selectedSoundEffectName: String {
        let settings = SettingsManager.shared
        guard settings.soundEffectMode == .preset else { return settings.soundEffectMode.title }
        return soundEffectPresets.first(where: { $0.id == settings.soundEffectPresetID })?.name
            ?? String(localized: "选择音效")
    }
    @Published private(set) var soundEffectCatalogLoading = false
    @Published private(set) var soundEffectCatalogFailed = false
    @Published private(set) var closedTuningPreferences: [AITuningPreference: String] = [:]
    var soundEffectEmotionLabel: String? {
        guard SettingsManager.shared.soundEffectMode == .emotion,
              let labels = activeSoundEffect?.feature?["emotion_label"].stringValue else { return nil }
        return labels.split(separator: ",").map(String.init)
            .filter { !["正向情绪", "中性情绪", "负面情绪"].contains($0) }.prefix(3).joined(separator: "、")
    }
    private var catalogAccountID: Int?
    private var catalogTask: Task<Void, Never>?
    private var activeSoundEffect: AISoundEffect?
    private var soundEffectTask: Task<Void, Never>?
    private var soundEffectObservation: AnyCancellable?
    private struct SoundEffectContext: Equatable {
        let session: String
        let songID: Int
        let quality: AudioQuality
        let mode: SoundEffectMode
        let presetID: Int
        let preferences: Set<AITuningPreference>
    }
    private var soundEffectContext: SoundEffectContext?
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var queueOrder: QueueOrder = .listed
    var shuffleEnabled: Bool { queueOrder == .shuffled }
    @Published var volume: Float = 1 {
        didSet {
            if volume > 0 { volumeBeforeMute = volume }
            engine.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    private var volumeBeforeMute: Float = 1

    func toggleMute() {
        if volume > 0 {
            // Capture the startup value too; property observers do not run in init.
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through.
    var activeQueue: [Track] {
        switch queueOrder {
        case .listed: return queue
        case .shuffled: return shuffledQueue
        }
    }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    @discardableResult
    func dismissPlaybackPresentation() -> Bool {
        // Panels sit above both the library and Now Playing; close them first.
        if activePanel != nil {
            activePanel = nil
            return true
        }
        if showNowPlaying {
            showNowPlaying = false
            return true
        }
        return false
    }

    // MARK: - Engine

    private let engine = PlaybackEngine()
    /// A source is loaded (file or progressive stream).
    private var sourceLoaded = false
    /// The loaded source is a complete local file, so the engine can seek
    /// sample-accurately and repeat-one can restart in place.
    private var hasLocalFile = false
    /// Cache entry for the source now playing; nil for trial fragments,
    /// which are never cached.
    private var currentCacheKey: EngineAudioCache.Key?
    private var currentRemoteURL: URL?
    private var progressTimer: Timer?
    private var lastPlaybackCheckpoint = ContinuousClock.now

    /// Live playback position for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse —
    /// it only moves when the scrubber would visibly move).
    ///
    /// Uses `progress` whenever no source is loaded, so a
    /// paused or unloaded player still reports where the playhead sits.
    var livePlaybackTime: TimeInterval {
        guard sourceLoaded else { return progress }
        let t = engine.position
        return t.isFinite ? t : progress
    }
    private var resolveGeneration = 0
    /// A quality change resumes the listening session it interrupted. A
    /// restored checkpoint still needs the ordinary new-session start path.
    private var pendingQualityReload = false
    /// True while the engine is paused by us (togglePlayPause/pause/
    /// interruption). When false, "resume" must re-issue play() instead —
    /// engine.resume() is a no-op on a drained or never-paused source.
    private var enginePaused = false

    private var prefetchTask: Task<Void, Never>?
    private var prefetchedFile: URL? { didSet { publishCacheFilesInUse() } }
    /// Complete cache file retained while its source is playing.
    private var loadedFile: URL? { didSet { publishCacheFilesInUse() } }
    private var currentLocalURL: URL? { didSet { publishCacheFilesInUse() } }
    private var consecutiveFailures = 0
    private var scrobbled = false
    private var startScrobbled = false

    // MARK: - Offline playback (downloads)

    /// The song that could not play because it is not on this device.
    @Published var offlineIssue: OfflinePlaybackIssue?
    /// Held while a downloaded file plays, so the download
    /// cannot be deleted from under it.
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var offlineScan: Task<Void, Never>?
    private var offlineScanID = UUID()
    private var networkState = DownloadNetworkState.unknown
    private var networkObservation: AnyCancellable?
    private var offlineActivatedScope: String?
    /// Set by an automatic advance and consumed by `startPlaying`: a song that
    /// turns out to be missing offline is skipped rather than reported.
    private var pendingAutoAdvance = false
    private var currentWasAdvanced = false

    private init() {
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.outputVolume = volume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off


        // macOS output routing (incl. AirPlay endpoints the system publishes):
        // the controller owns the device list and the user's choice, and this
        // is the only place it can reach the engine. Restores the persisted
        // device as a side effect.
        let engine = engine
        AudioOutputController.shared.attach { deviceID in
            engine.setOutputDevice(deviceID)
        }

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.activeSoundEffect != nil, !self.soundEffectMembershipAllowed {
                    self.resetSoundEffect()
                    self.soundEffectState = .unauthorized
                }
                guard self.isPlaying, self.sourceLoaded, !self.isScrubbing else { return }
                let seconds = self.engine.position
                guard seconds.isFinite else { return }

                // Lyrics need this cadence to stay in sync; the cursor itself
                // only publishes when the line actually changes.
                self.updateLyricsCursor(at: seconds)

                // The scrubber does not. Publishing the position every tick
                // re-renders it — and SwiftUI rebuilds the display list for the
                // whole tree each time — to move the thumb a fraction of a
                // pixel. Half a second is still smoother than the eye needs.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                }
                // The system advances its own clock; the manager only publishes
                // a correction when needed, including when a stream stalls.
                NowPlayingManager.shared.updateElapsed(seconds, rate: 1, periodic: true)
                if self.lastPlaybackCheckpoint.duration(to: .now) >= .seconds(20) {
                    self.persistState()
                }
            }
        }
        // .common keeps the clock ticking through menu tracking and window
        // drags, where the default run-loop mode starves plain timers.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

        Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                guard let self else { return }
                self.handleEngineEvent(event)
            }
        }

        NowPlayingManager.shared.attach(to: self)
        offlineActivatedScope = AccountStore.shared.offlineScope
        networkObservation = DownloadManager.shared.$network.removeDuplicates().sink { [weak self] network in
            guard let self else { return }
            let cameOnline = self.usesOfflineQueue && network.connected
            self.networkState = network
            if cameOnline, self.soundEffectState == .offlineMissing { self.refreshSoundEffect(retry: true) }
        }
        restoreState()
        // A saved list-repeat selection becomes ordinary ordered playback.
        // Shuffle retains queue wrapping as part of its single mode.
        repeatMode = playbackMode.repeatMode
        let account = AccountStore.shared
        soundEffectObservation = account.$membership
            .combineLatest(account.$profile.map { $0?.userId }.removeDuplicates())
            // AccountStore's @Published values emit before their stored values change.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSoundEffect() }
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        switch queueOrder {
        case .listed:
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        case .shuffled:
            // Only an explicit song selection should pin the first track.
            if let track {
                reshuffle(keeping: track)
            } else {
                shuffledQueue = tracks.shuffled()
            }
            currentIndex = 0
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
            schedulePrefetch()
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            pause()
            return
        } else if !sourceLoaded {
            // Only a pending quality change continues the existing listening
            // session; a restored session keeps the normal playback-start behavior.
            startPlaying(track, resumeAt: progress, continuingCurrentTrack: pendingQualityReload)
            return
        } else if enginePaused {
            engine.resume()
            enginePaused = false
            isPlaying = true
        } else {
            // The source drained (queue end) or was loaded without playing —
            // resume() would be a no-op; re-issue play from where we are.
            engine.play(from: min(progress, max(0, duration - 0.1)))
            isPlaying = true
            scrobbleStartIfNeeded(track)
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func setAudioQuality(_ quality: AudioQuality) {
        let settings = SettingsManager.shared
        guard quality.requiredMembership <= AccountStore.shared.membershipTier else {
            ToastCenter.shared.show(String(localized: "此音质需要更高的会员权益"))
            return
        }
        guard settings.audioQuality != quality else { return }
        settings.audioQuality = quality
        guard let track = currentTrack else { return }
        let continuingCurrentTrack = isPlaying || sourceLoaded || pendingQualityReload
        // A paused player only discards the old source. Resolving on the next
        // play press avoids a background load unexpectedly resuming playback.
        startPlaying(track, resumeAt: livePlaybackTime,
                     continuingCurrentTrack: true, autoplay: isPlaying)
        pendingQualityReload = continuingCurrentTrack
    }

    func setSoundEffectMode(_ mode: SoundEffectMode) {
        guard mode.minimumMembership <= AccountStore.shared.membershipTier else { return }
        let settings = SettingsManager.shared
        guard settings.soundEffectMode != mode else { return }
        let quality = servedQuality.flatMap(AudioQuality.init) ?? AccountStore.shared.playbackQuality
        let wasProcessing = wantsSoundEffect(for: quality)
        settings.soundEffectMode = mode
        resetSoundEffect()
        if quality.usesNativePlayback, !quality.isSpatial, wasProcessing != wantsSoundEffect(for: quality),
           let track = currentTrack {
            // Native high-resolution playback and the local DSP require different
            // sources. Preserve both the checkpoint and the user's paused intent.
            startPlaying(track, resumeAt: livePlaybackTime, continuingCurrentTrack: true, autoplay: isPlaying)
        } else {
            refreshSoundEffect()
        }
    }

    func selectSoundEffectPreset(_ preset: SoundEffectPreset) {
        guard preset.canUse(tier: AccountStore.shared.membershipTier) else { return }
        let settings = SettingsManager.shared
        guard settings.soundEffectPresetID != preset.id || settings.soundEffectMode != .preset else { return }
        settings.soundEffectPresetID = preset.id
        if settings.soundEffectMode == .preset { refreshSoundEffect() }
        else { setSoundEffectMode(.preset) }
    }

    func setAITuningPreference(_ preference: AITuningPreference, enabled: Bool) {
        var selected = SettingsManager.shared.aiTuningPreferences
        if enabled { selected.insert(preference) } else { selected.remove(preference) }
        SettingsManager.shared.aiTuningPreferences = selected
        if SettingsManager.shared.soundEffectMode == .aiMaster { refreshSoundEffect() }
    }

    func resetAITuningPreferences() {
        SettingsManager.shared.aiTuningPreferences = []
        setAISoundEffectStrength(1)
        if SettingsManager.shared.soundEffectMode == .aiMaster { refreshSoundEffect() }
    }

    func setAISoundEffectStrength(_ strength: Double) {
        guard strength.isFinite else { return }
        let value = min(1, max(0, strength))
        SettingsManager.shared.aiSoundEffectStrength = value
        engine.setSoundEffect(activeSoundEffect, strength: SettingsManager.shared.soundEffectMode == .aiMaster ? value : 1)
    }

    private var soundEffectMembershipAllowed: Bool {
        let mode = SettingsManager.shared.soundEffectMode
        guard mode != .off, mode.minimumMembership <= AccountStore.shared.membershipTier else { return false }
        if mode == .preset {
            return soundEffectPresets.first(where: { $0.id == SettingsManager.shared.soundEffectPresetID })?
                .canUse(tier: AccountStore.shared.membershipTier) == true
        }
        return true
    }

    private func wantsSoundEffect(for quality: AudioQuality) -> Bool {
        let mode = SettingsManager.shared.soundEffectMode
        return mode != .off && mode.minimumMembership <= AccountStore.shared.membershipTier && !quality.isSpatial && !isTrial
    }

    func loadSoundEffectCatalog(refresh: Bool = false) {
        let account = AccountStore.shared
        let uid = account.authenticatedAccountID
        if catalogAccountID != uid {
            catalogTask?.cancel()
            catalogTask = nil
            soundEffectPresets = []
            soundEffectCatalogFailed = false
            soundEffectCatalogLoading = false
            catalogAccountID = uid
        }
        guard let uid, let session = account.socialSession else { return }
        guard refresh || (soundEffectPresets.isEmpty && !soundEffectCatalogLoading) else { return }
        catalogTask?.cancel()
        soundEffectCatalogLoading = true
        soundEffectCatalogFailed = false
        let offline = usesOfflineQueue
        catalogTask = Task { [weak self] in
            do {
                let values = try await SoundEffectStore.shared.catalog(accountID: uid, offline: offline, refresh: refresh)
                guard let self, !Task.isCancelled, account.socialSession == session else { return }
                self.soundEffectPresets = values
                self.soundEffectCatalogLoading = false
                self.soundEffectCatalogFailed = values.isEmpty
            } catch {
                guard let self, !Task.isCancelled, account.socialSession == session else { return }
                self.soundEffectCatalogLoading = false
                self.soundEffectCatalogFailed = true
            }
        }
    }

    private func resetSoundEffect() {
        soundEffectTask?.cancel()
        soundEffectTask = nil
        soundEffectContext = nil
        activeSoundEffect = nil
        closedTuningPreferences = [:]
        engine.setSoundEffect(nil)
        soundEffectState = SettingsManager.shared.soundEffectMode == .off ? .off : .waiting
    }

    func refreshSoundEffect(retry: Bool = false) {
        let account = AccountStore.shared
        let settings = SettingsManager.shared
        loadSoundEffectCatalog()
        let mode = settings.soundEffectMode
        guard mode != .off else { resetSoundEffect(); return }
        guard let uid = account.authenticatedAccountID, let session = account.socialSession else {
            resetSoundEffect(); soundEffectState = .requiresLogin; return
        }
        guard account.membershipTier >= mode.minimumMembership else {
            resetSoundEffect()
            soundEffectState = mode == .aiMaster ? .requiresSVIP : .unauthorized
            return
        }
        guard let track = currentTrack, uid == playbackAccountID, sourceLoaded else {
            resetSoundEffect(); return
        }
        let quality = servedQuality.flatMap(AudioQuality.init) ?? account.playbackQuality
        guard !quality.isSpatial else {
            resetSoundEffect(); soundEffectState = .unsupportedSource; return
        }
        guard !isTrial else { resetSoundEffect(); soundEffectState = .unavailable; return }
        let context = SoundEffectContext(session: session, songID: track.id, quality: quality, mode: mode,
                                         presetID: settings.soundEffectPresetID, preferences: settings.aiTuningPreferences)
        guard retry || soundEffectContext != context else { return }
        resetSoundEffect()
        soundEffectContext = context
        soundEffectState = .loading
        let offline = usesOfflineQueue
        soundEffectTask = Task { [weak self] in
            do {
                let effect: AISoundEffect?
                var closed: [AITuningPreference: String] = [:]
                if mode == .aiMaster {
                    let song = try await AISoundEffectStore.shared.effect(songID: track.id, accountID: uid,
                                                                         offline: offline, refresh: retry)
                    if let song, !context.preferences.isEmpty {
                        let materials = try await SoundEffectStore.shared.tuningMaterials(offline: offline)
                        let composed = try AITuningComposer.compose(song: song, preferences: context.preferences, materials: materials)
                        effect = composed.effect
                        closed = composed.closed
                    } else { effect = song }
                } else {
                    effect = try await SoundEffectStore.shared.effect(mode: mode, presetID: context.presetID,
                        songID: track.id, accountID: uid, tier: account.membershipTier, offline: offline, refresh: retry)
                }
                guard let self, !Task.isCancelled, self.soundEffectContext == context,
                      account.socialSession == session, account.membershipTier >= mode.minimumMembership,
                      settings.soundEffectMode == mode else { return }
                guard let effect else {
                    self.soundEffectState = offline ? .offlineMissing : .unavailable
                    return
                }
                // A preset's entitlement can expire while the request is in flight.
                if mode == .preset {
                    let list = try await SoundEffectStore.shared.catalog(accountID: uid, offline: offline)
                    guard !Task.isCancelled, self.soundEffectContext == context, account.socialSession == session else { return }
                    self.soundEffectPresets = list
                    guard self.soundEffectMembershipAllowed else { self.soundEffectState = .unauthorized; return }
                }
                self.activeSoundEffect = effect
                self.closedTuningPreferences = closed
                self.engine.setSoundEffect(effect, strength: mode == .aiMaster ? settings.aiSoundEffectStrength : 1)
                self.soundEffectState = .ready
            } catch {
                guard let self, !Task.isCancelled, self.soundEffectContext == context else { return }
                switch error {
                case SoundEffectError.unauthorized: self.soundEffectState = .unauthorized
                case SoundEffectError.offlineMissing: self.soundEffectState = .offlineMissing
                default: self.soundEffectState = .failed
                }
            }
        }
    }

    func pause() {
        engine.pause()
        enginePaused = true
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        persistState()
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// The lead makes a line light up just before it is sung.
    private func updateLyricsCursor(at seconds: TimeInterval) {
        let index = lyrics?.activeIndex(at: seconds + 0.2)
        if index != lyricsCursor.activeIndex {
            lyricsCursor.activeIndex = index
        }
    }

    /// `completion` runs once the playhead is at `seconds`. The engine seeks
    /// synchronously, so it runs before this returns — the parameter exists for
    /// the AVPlayer-shaped call sites in the UI.
    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        progress = seconds
        updateLyricsCursor(at: seconds)
        engine.seek(to: seconds)
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
        persistState()
        completion?()
    }

    func toggleShuffle() {
        setQueueOrder(shuffleEnabled ? .listed : .shuffled)
    }

    func setQueueOrder(_ order: QueueOrder) {
        guard !isFMMode, queueOrder != order else { return }
        let current = currentTrack
        queueOrder = order
        switch order {
        case .listed:
            shuffledQueue = []
            if let current {
                currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
            }
        case .shuffled:
            guard let current else { break }
            reshuffle(keeping: current)
            currentIndex = 0
        }
        persistState()
        schedulePrefetch()
    }

    var playbackMode: PlaybackMode {
        PlaybackMode(queueOrder: queueOrder, repeatMode: repeatMode)
    }

    func cyclePlaybackMode() {
        setPlaybackMode(playbackMode.next())
    }

    func setPlaybackMode(_ next: PlaybackMode) {
        guard !isFMMode else { return }
        repeatMode = next.repeatMode
        if queueOrder != next.queueOrder {
            // This also persists and refreshes prefetch using the new repeat
            // policy, after rebuilding the queue around the current track.
            setQueueOrder(next.queueOrder)
        } else {
            persistState()
            schedulePrefetch()
        }
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.id == track.id }),
           idx != currentIndex || queueOrder != .listed {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
        schedulePrefetch()
    }

    /// Queue rows carry their occurrence, so a repeated song selects the row
    /// the listener clicked rather than its first occurrence.
    func jumpToUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset):
            playNextList.removeSubrange(0...offset)
        case .queue(let offset):
            if !playNextList.isEmpty { playNextList.removeAll() }
            currentIndex = offset
        case .fm: return
        }
        startPlaying(selected.track)
    }

    /// Removes the row itself: a repeated song leaves the occurrence the
    /// listener chose, not its first one, so the current index stays put.
    func removeUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset): playNextList.remove(at: offset)
        case .queue(let offset): removeQueueRow(at: offset, trackID: selected.track.id)
        case .fm: return
        }
    }

    /// The row sits after the current index in the active order; the other
    /// orders drop one copy of the same song so all stay the same length.
    private func removeQueueRow(at offset: Int, trackID: Int) {
        switch queueOrder {
        case .listed: queue.remove(at: offset)
        case .shuffled: shuffledQueue.remove(at: offset)
        }
        if queueOrder != .listed, let idx = queue.firstIndex(where: { $0.id == trackID }) { queue.remove(at: idx) }
        if queueOrder != .shuffled, let idx = shuffledQueue.firstIndex(where: { $0.id == trackID }) { shuffledQueue.remove(at: idx) }
        schedulePrefetch()
    }

    /// The row at `index` of `upcomingTracks`, if it still shows `trackID`.
    private func upcomingCandidate(at index: Int, matching trackID: Int) -> PlaybackQueueCandidate? {
        let candidates = PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                                                fm: [], isFM: false, repeatAll: false, limit: max(0, index + 1))
        guard candidates.indices.contains(index), candidates[index].track.id == trackID else { return nil }
        return candidates[index]
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
        recordRecent(.fm)
        isFMMode = true
        queueOrder = .listed
        repeatMode = .off
        queue = []
        shuffledQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
        if usesOfflineQueue {
            advanceOffline()
            return
        }
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await NeteaseAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        pendingAutoAdvance = true
        startPlaying(track)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if usesOfflineQueue, !nextCandidates().isEmpty {
            pendingAutoAdvance = !userInitiated
            advanceOffline()
            return
        }
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            pendingAutoAdvance = !userInitiated
            startPlaying(track)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
                    isPlaying = false
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        pendingAutoAdvance = !userInitiated
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)

        if sleepTimer.consumeEndOfCurrentTrack() {
            // Natural end leaves the engine drained. The next Play press
            // takes the ordinary end-of-track advance path.
            progress = duration
            updateLyricsCursor(at: duration)
            isPlaying = false
            NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            return
        }

        guard isPlaying else { return }

        if repeatMode == .one, !isFMMode {
            scrobbled = false
            if hasLocalFile {
                progress = 0
                engine.play(from: 0)
                isPlaying = true
                NowPlayingManager.shared.updateElapsed(0, rate: 1)
            } else if let track = currentTrack {
                // A drained stream can't restart in place; re-resolve (the
                // second pass usually hits the cache the first one committed).
                startPlaying(track)
            }
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track,
                              localLease: OfflinePlaybackLease? = nil, resumeAt: TimeInterval = 0,
                              continuingCurrentTrack: Bool = false, autoplay: Bool = true) {
        pendingQualityReload = continuingCurrentTrack
        resetSoundEffect()
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        currentWasAdvanced = continuingCurrentTrack ? false : pendingAutoAdvance
        pendingAutoAdvance = false
        releaseOfflineLease()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedFile = nil
        currentLocalURL = nil
        currentCacheKey = nil
        currentRemoteURL = nil
        if continuingCurrentTrack {
            // Freeze the old source at the checkpoint while the replacement
            // downloads; its end events must not advance this same song.
            engine.stop()
            loadedFile = nil
        }
        sourceLoaded = false
        hasLocalFile = false
        isBuffering = false
        enginePaused = false

        if !continuingCurrentTrack {
            scrobbleIfNeeded(completed: false)
            currentTrack = track
            playbackAccountID = AccountStore.shared.profile?.userId
            lyrics = nil
            scrobbled = false
            startScrobbled = false
            lyricsCursor.activeIndex = nil
        }
        progress = resumeAt
        if !continuingCurrentTrack { duration = track.duration }
        servedQuality = nil
        if !continuingCurrentTrack { isTrial = false }
        isPlaying = autoplay
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        NowPlayingManager.shared.updateElapsed(resumeAt, rate: autoplay ? 1 : 0)
        persistState()

        if lyrics == nil {
            Task {
                await loadLyrics(for: track, generation: generation)
            }
        }
        guard autoplay else { return }
        Task {
            await resolveAndLoad(track, generation: generation, localLease: localLease,
                                 resumeAt: resumeAt, continuingCurrentTrack: continuingCurrentTrack)
        }
    }

    private struct ResolvedSource {
        let url: URL
        let key: EngineAudioCache.Key
        let level: String?
        let isTrial: Bool
        let durationMS: Int?
    }

    /// The full URL-resolution chain (quality fallback → https upgrade) plus
    /// cache-key derivation — shared by playback and prefetch so both always
    /// derive identical keys. Pure: no toasts, no state changes.
    private func resolveSource(for track: Track) async -> ResolvedSource? {
        let quality = AccountStore.shared.playbackQuality.rawValue
        var data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
        if data?.url == nil, quality != AudioQuality.standard.rawValue {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
        }
        guard let urlString = data?.url,
              let url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        else { return nil }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        return ResolvedSource(
            url: url,
            key: EngineAudioCache.Key(trackID: track.id, level: data?.level ?? quality,
                                source: "netease",
                                fileExtension: ext),
            level: data?.level,
            isTrial: data?.freeTrialInfo != nil,
            durationMS: data?.time)
    }

    private func resolveAndLoad(_ track: Track, generation: Int,
                                localLease: OfflinePlaybackLease? = nil, resumeAt: TimeInterval = 0,
                                continuingCurrentTrack: Bool = false) async {
        // A downloaded copy beats the network, and is all there is without one.
        if let lease = await acquireOfflineLease(for: track, generation: generation, reusing: localLease) {
            isTrial = false
            playLocalFile(lease.url, lease: lease, for: track, generation: generation, from: resumeAt)
            return
        }
        guard generation == resolveGeneration else { return }
        if usesOfflineQueue {
            // Without a network, the cache is the last place to look.
            if let cached = await EngineAudioCache.shared.cachedFileURL(trackID: track.id) {
                guard generation == resolveGeneration else { return }
                isTrial = false
                playLocalFile(cached, lease: nil, for: track, generation: generation, from: resumeAt)
                return
            }
            guard generation == resolveGeneration else { return }
            unavailableOffline(track, generation: generation)
            return
        }
        let resolved = await resolveSource(for: track)
        guard generation == resolveGeneration else { return }

        guard let resolved else {
            consecutiveFailures += 1
            let reason = track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            if continuingCurrentTrack {
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                return
            }
            guard isPlaying else { return }
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
            }
            return
        }

        consecutiveFailures = 0
        servedQuality = resolved.level
        // Record the actual source quality so a server-side downgrade is visible.
        PlaybackJournal.note(
            "now playing id=\(track.id) level=\(resolved.level ?? "?") "
            + "wanted=\(SettingsManager.shared.audioQuality.rawValue) "
            + (resolved.isTrial ? "trial " : ""))
        isTrial = resolved.isTrial
        if resolved.isTrial {
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }

        let key = resolved.key
        currentCacheKey = resolved.isTrial ? nil : key
        currentRemoteURL = resolved.url

        if let quality = AudioQuality(rawValue: resolved.level ?? key.level), quality.usesNativePlayback {
            let cached = resolved.isTrial ? nil : await EngineAudioCache.shared.cachedFileURL(for: key)
            guard generation == resolveGeneration else { return }
            if wantsSoundEffect(for: quality) {
                isBuffering = true
                do {
                    let local: URL
                    if let cached { local = cached }
                    else { local = try await EngineAudioCache.shared.download(from: resolved.url, key: key) }
                    guard generation == resolveGeneration else { return }
                    playLocalFile(local, lease: nil, for: track, generation: generation,
                                  from: resumeAt, quality: resolved.level)
                } catch {
                    guard generation == resolveGeneration else { return }
                    isBuffering = false
                    isPlaying = false
                    engine.stop()
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                    ToastCenter.shared.show(error.localizedDescription)
                }
                return
            }
            playNativeSource(cached ?? NeteaseCDNHost.preferred(for: resolved.url), for: track, quality: resolved.level,
                             duration: resolved.durationMS.map { Double($0) / 1000 } ?? track.duration,
                             from: resumeAt)
            return
        }

        // Progressive streams cannot seek before their bytes arrive. A received
        // checkpoint therefore loads a complete file through the existing cache.
        if resumeAt > 0 {
            isBuffering = true
            do {
                let local: URL
                if resolved.isTrial {
                    // A preview needs a complete file to seek too, but must
                    // stay in the same temporary slot used by trial streaming.
                    let (data, response) = try await URLSession.shared.data(from: resolved.url)
                    guard generation == resolveGeneration else { return }
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    local = FileManager.default.temporaryDirectory
                        .appendingPathComponent("kumone-trial-\(track.id).part")
                    try data.write(to: local, options: .atomic)
                } else {
                    local = try await EngineAudioCache.shared.download(from: resolved.url, key: key)
                }
                guard generation == resolveGeneration else { return }
                playLocalFile(local, lease: nil, for: track, generation: generation, from: resumeAt,
                              quality: resolved.level)
                servedQuality = resolved.level
                return
            } catch {
                guard generation == resolveGeneration else { return }
                isBuffering = false
                isPlaying = false
                engine.stop()
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                ToastCenter.shared.show(error.localizedDescription)
                return
            }
        }

        engine.stop()
        loadedFile = nil
        sourceLoaded = true
        hasLocalFile = false

        if !resolved.isTrial {
            var local = await EngineAudioCache.shared.cachedFileURL(for: key)
            if local == nil, let inflight = await EngineAudioCache.shared.activeDownload(for: key) {
                // A prefetch of this very track is mid-flight — wait for it
                // instead of opening a second transfer of the same file.
                isBuffering = true
                local = try? await inflight.value
                isBuffering = false
            }
            guard generation == resolveGeneration else { return }
            if let local,
               let fileDuration = try? engine.loadFile(
                   at: local) {
                hasLocalFile = true
                loadedFile = local
                currentLocalURL = local
                if isPlaying {
                    engine.play(from: 0)
                    scrobbleStartIfNeeded(track)
                } else {
                    enginePaused = false
                }
                pendingQualityReload = false
                duration = fileDuration
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                refreshSoundEffect()
                schedulePrefetch()
                return
            }
            // Unreadable cache entry — fall through to streaming.
        }
        guard generation == resolveGeneration else { return }

        let partURL: URL
        if resolved.isTrial {
            // Trial fragments never enter the cache; the mirror write goes to
            // a temp file the OS cleans up.
            partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kumone-trial-\(track.id).part")
        } else {
            partURL = EngineAudioCache.shared.partFileURL(for: key)
        }
        // Buffering until the first decoded chunk lands (streamResumed).
        isBuffering = true
        engine.startStreaming(from: resolved.url, formatHint: key.fileExtension,
                              writingTo: partURL)
        if isPlaying {
            engine.play(from: 0)
            scrobbleStartIfNeeded(track)
        } else {
            enginePaused = false
        }
        pendingQualityReload = false
        refreshSoundEffect()

        if let time = resolved.durationMS, time > 0 {
            duration = TimeInterval(time) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        schedulePrefetch()
    }

    // MARK: - Engine events

    private func playNativeSource(_ url: URL, for track: Track, quality: String?, duration sourceDuration: Double,
                                  from position: Double = 0) {
        engine.loadNative(from: url, duration: sourceDuration)
        sourceLoaded = true
        hasLocalFile = url.isFileURL
        loadedFile = url.isFileURL ? url : nil
        currentRemoteURL = url.isFileURL ? nil : url
        servedQuality = quality
        duration = sourceDuration
        progress = position
        isBuffering = isPlaying && !url.isFileURL
        pendingQualityReload = false
        if isPlaying {
            engine.play(from: position)
            scrobbleStartIfNeeded(track)
        } else {
            enginePaused = false
        }
        NowPlayingManager.shared.updateMetadata(for: track, duration: sourceDuration)
        refreshSoundEffect()
        schedulePrefetch()
    }

    private func handleEngineEvent(_ event: PlaybackEngineEvent) {
        switch event {
        case .finished:
            guard sourceLoaded else { return }
            handleItemEnded()
        case .streamStalled:
            if sourceLoaded { isBuffering = true }
        case .streamResumed:
            if sourceLoaded { isBuffering = false }
        case .streamDownloadCompleted:
            guard let key = currentCacheKey else { return }
            let generation = resolveGeneration
            Task { [weak self] in
                guard let final = try? await EngineAudioCache.shared.commitPartFile(for: key),
                      let self, generation == self.resolveGeneration else { return }
                self.currentLocalURL = final
                // The progressive mirror just became a complete file: the words
                // fetched at the start of the song now have something to sit by.
                // The prefetch pipeline may have deferred while this track
                // was still streaming (same-track repeat) — re-run it.
                self.schedulePrefetch()
            }
        case .streamFailed(let error):
            guard sourceLoaded else { return }
            if engine.usesNativePlayback {
                if let url = currentRemoteURL, let twin = NeteaseCDNHost.failover(from: url, after: error),
                   let track = currentTrack {
                    let position = engine.position
                    currentRemoteURL = twin
                    playNativeSource(twin, for: track, quality: servedQuality, duration: duration, from: position)
                } else {
                    let position = engine.position
                    pause()
                    progress = position
                    engine.stop()
                    sourceLoaded = false
                    pendingQualityReload = true
                    isBuffering = false
                    ToastCenter.shared.show(String(localized: "所选音源播放失败，请尝试其他音质或输出设备"))
                }
                return
            }
            handleStreamFailure()
        }
    }

    /// Progressive playback died (parse error, mid-file network loss, format
    /// the stream parser can't resync): download the whole file instead and
    /// resume near where it stopped.
    private func handleStreamFailure() {
        if isPlaying { isBuffering = true }
        let generation = resolveGeneration
        let resumeAt = progress
        guard let key = currentCacheKey, let remote = currentRemoteURL,
              let track = currentTrack else {
            streamFallbackFailed()
            return
        }
        Task {
            do {
                let local = try await EngineAudioCache.shared.download(from: remote, key: key)
                guard generation == resolveGeneration else { return }
                let fileDuration = try engine.loadFile(at: local)
                loadedFile = local
                hasLocalFile = true
                currentLocalURL = local
                isBuffering = false
                duration = fileDuration
                if isPlaying {
                    engine.play(from: min(resumeAt, max(0, fileDuration - 1)))
                } else {
                    // The user paused mid-stream: stay silent. The play
                    // button re-issues play() from `progress`.
                    enginePaused = false
                }
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                schedulePrefetch()
            } catch {
                guard generation == resolveGeneration else { return }
                // The network is gone mid-song; a download of it plays on.
                if let lease = await acquireOfflineLease(for: track, generation: generation, anyQuality: true) {
                    playLocalFile(lease.url, lease: lease, for: track, generation: generation, from: resumeAt)
                    return
                }
                guard generation == resolveGeneration else { return }
                streamFallbackFailed()
            }
        }
    }

    private func streamFallbackFailed() {
        isBuffering = false
        consecutiveFailures += 1
        ToastCenter.shared.show(String(localized: "播放失败，已跳过"))
        if consecutiveFailures < 5 {
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    // MARK: - Next-track prefetch

    /// The track the player would advance to on its own, or nil when the
    /// hand-over must stay manual (repeat-one, trial fragment, end of queue).
    private func autoAdvanceTarget() -> Track? {
        guard !isTrial, repeatMode != .one else { return nil }
        if isFMMode { return fmUpcoming.first }
        if let next = playNextList.first { return next }
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return nil }
        let idx = currentIndex + 1
        if idx < activeQueue.count { return activeQueue[idx] }
        return repeatMode == .all ? activeQueue.first : nil
    }

    /// Fill the ordinary audio cache without changing queue order or playback.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        prefetchedFile = nil
        guard !usesOfflineQueue, let target = autoAdvanceTarget(),
              target.id != currentTrack?.id || hasLocalFile else { return }
        let generation = resolveGeneration
        prefetchTask = Task { [weak self] in
            guard let self,
                  let resolved = await self.resolveSource(for: target), !resolved.isTrial,
                  !Task.isCancelled, generation == self.resolveGeneration,
                  let local = try? await EngineAudioCache.shared.download(from: resolved.url, key: resolved.key),
                  !Task.isCancelled, generation == self.resolveGeneration,
                  self.autoAdvanceTarget()?.id == target.id else { return }
            self.prefetchedFile = local
        }
    }

    private func publishCacheFilesInUse() {
        EngineAudioCache.shared.setFilesInUse(Set([loadedFile, currentLocalURL, prefetchedFile].compactMap { $0 }))
    }

    private func loadLyrics(for track: Track, generation: Int) async {
        let scope = offlineAccountScope
        if let scope, let saved = await OfflineMetadataStore.shared.lyrics(trackID: track.id, scope: scope) {
            guard generation == resolveGeneration else { return }
            applyLyrics(saved)
        }
        guard !usesOfflineQueue else { return }
        let response = try? await NeteaseAPI.cachedLyrics(id: track.id)
        guard generation == resolveGeneration, let response else { return }
        applyLyrics(response)
        // The engine caches every song it streams, so each one may play offline.
        if let scope { await OfflineMetadataStore.shared.keepPlaybackData(track: track, lyrics: response, scope: scope) }
    }

    private func applyLyrics(_ response: LyricResponse) {
        lyrics = LyricsParser.parse(response)
        updateLyricsCursor(at: livePlaybackTime)
    }

    // MARK: - Offline playback

    /// Downloads belong to one account; see `activateAccount`.
    private var offlineAccountScope: String? { AccountStore.shared.offlineScope }
    private var usesOfflineQueue: Bool { networkState.isKnown && !networkState.connected }

    private func nextCandidates() -> [PlaybackQueueCandidate] {
        PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                               fm: fmUpcoming, isFM: isFMMode, repeatAll: repeatMode == .all)
    }

    /// A downloaded copy of the track. Online it must match the chosen quality
    /// or better; offline, any quality will do.
    private func acquireOfflineLease(for track: Track, generation: Int, reusing lease: OfflinePlaybackLease? = nil,
                                     anyQuality: Bool = false) async -> OfflinePlaybackLease? {
        let scope = offlineAccountScope
        var lease = lease
        if lease == nil, let scope {
            lease = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id,
                preferredQuality: AccountStore.shared.playbackQuality.rawValue,
                allowLowerQuality: anyQuality || !networkState.connected)
        }
        guard let lease else { return nil }
        guard generation == resolveGeneration, scope == offlineAccountScope,
              lease.descriptor.identity.accountScope == scope else {
            try? await OfflineStore.shared.release(lease)
            return nil
        }
        return lease
    }

    /// Plays a downloaded file (with its lease) or an offline cache entry.
    private func playLocalFile(_ url: URL, lease: OfflinePlaybackLease?, for track: Track, generation: Int,
                               from position: TimeInterval = 0, quality: String? = nil) {
        consecutiveFailures = 0
        servedQuality = lease?.descriptor.identity.quality ?? quality
        currentCacheKey = nil
        currentRemoteURL = nil
        let sourceQuality = servedQuality.flatMap(AudioQuality.init) ?? AccountStore.shared.playbackQuality
        if sourceQuality.usesNativePlayback && !wantsSoundEffect(for: sourceQuality) {
            offlinePlaybackLease = lease
            playNativeSource(url, for: track, quality: servedQuality, duration: lease?.descriptor.duration ?? track.duration,
                             from: position)
            return
        }
        engine.stop()
        loadedFile = nil
        guard let fileDuration = try? engine.loadFile(at: url, preserveSampleRate: sourceQuality.usesNativePlayback) else {
            if let lease { Task { try? await OfflineStore.shared.release(lease) } }
            sourceLoaded = false
            unavailableOffline(track, generation: generation)
            return
        }
        offlinePlaybackLease = lease
        sourceLoaded = true
        pendingQualityReload = false
        hasLocalFile = true
        loadedFile = url
        currentLocalURL = lease == nil && !isTrial ? url : nil
        isBuffering = false
        duration = fileDuration
        if isPlaying {
            engine.play(from: min(position, max(0, fileDuration - 1)))
            scrobbleStartIfNeeded(track)
        } else {
            enginePaused = false
        }
        NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
        refreshSoundEffect()
        schedulePrefetch()
    }

    private func stopForOffline() {
        engine.stop()
        loadedFile = nil
        sourceLoaded = false
        hasLocalFile = false
        currentLocalURL = nil
    }

    private func releaseOfflineLease() {
        guard let lease = offlinePlaybackLease else { return }
        offlinePlaybackLease = nil
        Task { try? await OfflineStore.shared.release(lease) }
    }

    private func unavailableOffline(_ track: Track, generation: Int) {
        guard generation == resolveGeneration else { return }
        if currentWasAdvanced {
            advanceOffline(initialSkipped: 1, excludingFailedCurrent: true)
            return
        }
        stopForOffline()
        isPlaying = false
        isBuffering = false
        offlineIssue = .init(kind: .missingTrack, trackName: track.name)
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func playNextAvailableOffline() {
        offlineIssue = nil
        advanceOffline()
    }

    /// Walks the upcoming list for the first song that is on this device.
    private func advanceOffline(initialSkipped: Int = 0, excludingFailedCurrent: Bool = false) {
        offlineScan?.cancel()
        let requestID = UUID()
        offlineScanID = requestID
        resolveGeneration += 1
        let generation = resolveGeneration
        let scope = offlineAccountScope
        var candidates = nextCandidates()
        if excludingFailedCurrent { candidates.removeAll { $0.origin == .queue(currentIndex) } }
        stopForOffline()
        releaseOfflineLease()
        isPlaying = false
        offlineScan = Task { [weak self] in
            guard let self, !Task.isCancelled, self.offlineScanID == requestID else { return }
            let selected = try? await OfflineQueueSelector.firstAvailable(candidates, scope: scope,
                quality: AccountStore.shared.playbackQuality.rawValue, store: .shared,
                isCached: { await EngineAudioCache.shared.cachedFileURL(trackID: $0) != nil })
            guard !Task.isCancelled, self.offlineScanID == requestID, self.resolveGeneration == generation,
                  self.offlineAccountScope == scope else {
                if let lease = selected?.lease { try? await OfflineStore.shared.release(lease) }
                return
            }
            self.offlineScan = nil
            guard let selected else {
                self.pendingAutoAdvance = false
                self.offlineIssue = .init(kind: .emptyQueue, trackName: nil)
                self.isBuffering = false
                NowPlayingManager.shared.updateElapsed(self.progress, rate: 0)
                return
            }
            // The queue may have been edited while the scan ran.
            guard self.stillHolds(selected.candidate) else {
                if let lease = selected.lease { try? await OfflineStore.shared.release(lease) }
                self.advanceOffline(initialSkipped: initialSkipped, excludingFailedCurrent: excludingFailedCurrent)
                return
            }
            switch selected.candidate.origin {
            case .inserted(let index): self.playNextList.removeSubrange(0...index)
            case .queue(let index):
                if !self.playNextList.isEmpty { self.playNextList.removeAll() }
                self.currentIndex = index
            case .fm(let index): self.fmUpcoming.removeSubrange(0...index)
            }
            let skipped = initialSkipped + selected.skipped
            self.pendingAutoAdvance = true
            self.startPlaying(selected.candidate.track, localLease: selected.lease)
            if skipped > 0 { ToastCenter.shared.show(String(localized: "已跳过 \(skipped) 首未下载歌曲")) }
        }
    }

    private func stillHolds(_ candidate: PlaybackQueueCandidate) -> Bool {
        switch candidate.origin {
        case .inserted(let index): return playNextList.indices.contains(index) && playNextList[index].id == candidate.track.id
        case .queue(let index): return activeQueue.indices.contains(index) && activeQueue[index].id == candidate.track.id
        case .fm(let index): return fmUpcoming.indices.contains(index) && fmUpcoming[index].id == candidate.track.id
        }
    }

    /// Downloads belong to one account. Audio leased under the previous
    /// account stops, and the offline queue scan starts over.
    func activateAccount(scope: String?) {
        guard offlineActivatedScope != scope else { return }
        offlineActivatedScope = scope
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        guard offlinePlaybackLease != nil else { return }
        resolveGeneration += 1
        stopForOffline()
        releaseOfflineLease()
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    // MARK: - Scrobble

    /// Tell the server the track started, once per track. Called from the
    /// point playback actually begins — the cache-hit path and the streaming
    /// path both reach it, and `startPlaying` clears the flag.
    private func scrobbleStartIfNeeded(_ track: Track) {
        guard !startScrobbled else { return }
        startScrobbled = true
        let tid = track.id
        let sid = source.sourceID
        Task.detached { await NeteaseAPI.scrobbleStart(trackID: tid, sourceID: sid) }
    }

    private func scrobbleIfNeeded(completed: Bool) {
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        let seconds = completed ? Int(duration) : Int(progress)
        let sourceID = source.sourceID
        Task.detached {
            await NeteaseAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
        }
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue
        if let index = rest.firstIndex(where: { $0.id == first.id }) { rest.remove(at: index) }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        let scope = AccountStore.shared.offlineScope
        let session = NeteaseClient.shared.authenticationFingerprint
        let result = try await OfflineContextResolver.resolve(context, offline: usesOfflineQueue) { try await resolveOnline(context) }
        guard scope == AccountStore.shared.offlineScope, session == NeteaseClient.shared.authenticationFingerprint else {
            throw CancellationError()
        }
        return result
    }

    private func resolveOnline(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.cachedAlbum(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.cachedArtist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await NeteaseAPI.cachedDailyRecommendSongs(), .daily)
        case .cloud:
            await CloudContent.shared.load()
            guard CloudContent.shared.loadedScope == AccountStore.shared.offlineScope,
                  let snapshot = CloudContent.shared.snapshot else {
                throw NeteaseAPIError.business(code: 0, message: CloudContent.shared.errorMessage)
            }
            return (snapshot.items.compactMap(\.simpleSong), .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.cachedPlayRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await NeteaseAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    var playbackSession: PlaybackSession? {
        guard let currentTrack else { return nil }
        return PlaybackSession(accountID: playbackAccountID, queue: queue, orderedQueue: activeQueue,
                               currentIndex: currentIndex, currentTrack: currentTrack, playNext: playNextList,
                               source: source, repeatMode: repeatMode.rawValue, shuffled: shuffleEnabled,
                               isFM: isFMMode, progress: progress)
    }

    func resume(_ session: PlaybackSession) throws {
        let accountID = AccountStore.shared.authenticatedAccountID
        try session.validateAccess(accountID: accountID)
        scrobbleIfNeeded(completed: false)
        pause()
        applyPlaybackSession(session)
        startPlaying(session.currentTrack, resumeAt: session.progress)
    }

    private func applyPlaybackSession(_ session: PlaybackSession) {
        queue = session.queue
        shuffledQueue = session.shuffled ? session.orderedQueue : []
        if session.shuffled {
            queueOrder = .shuffled
        } else {
            queueOrder = .listed
            queue = session.orderedQueue
        }
        currentIndex = session.currentIndex
        currentTrack = session.currentTrack
        playbackAccountID = session.accountID
        playNextList = session.playNext
        source = session.source
        if let mode = RepeatMode(rawValue: session.repeatMode) {
            repeatMode = PlaybackMode(queueOrder: queueOrder, repeatMode: mode).repeatMode
        }
        isFMMode = session.isFM
        fmUpcoming = []
        progress = session.progress
        duration = session.currentTrack.duration
        // A received checkpoint is not listening earned on this device.
        scrobbled = true
    }

    func checkpointPlayback() { persistState() }

    func suspendForAccountChange() {
        resetSoundEffect()
        resolveGeneration += 1
        scrobbled = true
        pause()
        stopForOffline()
        releaseOfflineLease()
        prefetchTask?.cancel()
    }

    private func persistState() {
        lastPlaybackCheckpoint = .now
        let state = PlaybackState(session: playbackSession, recentContexts: recentContexts)
        PlaybackStateStorage.save(state, to: Self.stateFileURL)
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PlaybackState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        if let session = state.session {
            do {
                try session.validate()
                applyPlaybackSession(session)
                NowPlayingManager.shared.updateMetadata(for: session.currentTrack, duration: duration)
                // Restoring a paused session must load its lyrics without waiting for Play.
                Task { [generation = resolveGeneration] in
                    await loadLyrics(for: session.currentTrack, generation: generation)
                }
            } catch { ToastCenter.shared.show(error.localizedDescription) }
            return
        }
        guard let legacy = state.legacy, !legacy.queue.isEmpty else { return }
        queue = legacy.queue
        queueOrder = PlayerService.restoredQueueOrder(legacy)
        switch queueOrder {
        case .listed: break
        case .shuffled: shuffledQueue = queue.shuffled()
        }
        if let id = legacy.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
            Task {
                await loadLyrics(for: activeQueue[idx], generation: resolveGeneration)
            }
        }
    }

    /// The queue order a persisted session restores to, migrating a state file
    /// written before the mode existed. Static and pure so the migration is
    /// testable without a player.
    nonisolated static func restoredQueueOrder(_ state: PlaybackState.Legacy) -> QueueOrder {
        state.queueOrder.flatMap(QueueOrder.init(rawValue:))
            ?? QueueOrder(migratingShuffle: state.shuffle)
    }

    private static var stateFileURL: URL {
        KumoneDirectories.applicationSupport().appendingPathComponent("player-state.json")
    }
}
