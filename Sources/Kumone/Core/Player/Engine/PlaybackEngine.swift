import AudioToolbox
import AVFoundation
import Foundation
import KumoneObjC

enum PlaybackEngineEvent: Sendable {
    case finished
    case streamStalled
    case streamResumed
    case streamFailed(Error)
    case streamDownloadCompleted
    case preparedStreamDownloadCompleted(remoteURL: URL, partURL: URL)
    case preparedStreamFailed(remoteURL: URL, partURL: URL, Error)
}

struct PlaybackEngineEventDelivery: Sendable {
    let event: PlaybackEngineEvent
    fileprivate let sourceGeneration: Int?
}

/// One source at a time. PCM goes straight from the player node to the mixer;
/// high-resolution and spatial formats use the native renderer. Mutable state
/// and loader callbacks share a serial queue. Completion generations distinguish
/// natural endings from stop/seek/reload callbacks.
final class PlaybackEngine: @unchecked Sendable {
    let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    let eventDeliveries: AsyncStream<PlaybackEngineEventDelivery>
    private let deliveryContinuation: AsyncStream<PlaybackEngineEventDelivery>.Continuation
    private let queue = DispatchQueue(label: "app.kumone.playback-engine")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let soundEqualizer = AVAudioUnitEQ(numberOfBands: 10)
    private let soundRenderer = LocalSoundEffectRenderer()
    private var soundEffect: AISoundEffect?
    private var soundEffectStrength = 1.0

    private enum Source {
        case none
        case file(AVAudioFile)
        case convertedFile(FileFeeder)
        case stream(ProgressiveLoader)
        case remote(RemoteAudioLoader)
    }
    private var source: Source = .none
    private struct StreamIdentity: Equatable {
        let remote: URL
        let formatHint: String?
        let preserveSampleRate: Bool
    }
    private final class PreparedStream {
        let identity: StreamIdentity
        let partURL: URL
        let loader: ProgressiveLoader
        var format: AVAudioFormat?
        var buffers: [AVAudioPCMBuffer] = []
        var ended = false

        init(identity: StreamIdentity, partURL: URL, loader: ProgressiveLoader) {
            self.identity = identity
            self.partURL = partURL
            self.loader = loader
        }
    }
    private var preparedStream: PreparedStream?
    private var activeStreamIdentity: StreamIdentity?
    private var activePartURL: URL?
    private var sourceGeneration = 0
    private let preparedStreamHighWater = 4
    private var nativePlayback: NativeAudioPlayback?
    private var nativeOutputDeviceUID: String?
    private var userVolume: Float = 1
    private var generation = 0
    private var wantsPlayback = false
    private var isPaused = false
    private var startOffset: TimeInterval = 0
    private var lastKnownPosition: TimeInterval = 0
    private var pendingBuffers = 0
    private var streamEnded = false
    private var streamStalled = false
    private let streamHighWater = 40
    private let streamLowWater = 10
    private var pauseDrain: DispatchWorkItem?
    private var clockTimer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?
    private var ownConfigurationChangeUntil: Date?
    private var outputSampleSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var mixerTapInstalled = false

    init() {
        var c: AsyncStream<PlaybackEngineEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        continuation = c
        var delivery: AsyncStream<PlaybackEngineEventDelivery>.Continuation!
        eventDeliveries = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { delivery = $0 }
        deliveryContinuation = delivery
        engine.attach(player)
        engine.attach(soundEqualizer)
        engine.attach(soundRenderer.node)
        soundEqualizer.bypass = true
        connectGraphLocked()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChangeLocked() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        pauseDrain?.cancel()
        clockTimer?.cancel()
        preparedStream?.loader.cancel()
        continuation.finish()
        deliveryContinuation.finish()
    }

    var outputVolume: Float {
        get { queue.sync { userVolume } }
        set {
            queue.async {
                self.userVolume = newValue
                self.engine.mainMixerNode.outputVolume = newValue
                self.nativePlayback?.setVolume(newValue)
            }
        }
    }

    var usesNativePlayback: Bool { queue.sync { nativePlayback != nil } }
    var position: TimeInterval { queue.sync { positionLocked() } }
    var duration: TimeInterval? { queue.sync { durationLocked() } }

    /// Check when consuming on the UI actor: an event can already be queued
    /// when a later source replaces the one which produced it.
    func isCurrent(_ delivery: PlaybackEngineEventDelivery) -> Bool {
        queue.sync { delivery.sourceGeneration.map { $0 == sourceGeneration } ?? true }
    }

    private func emitLocked(_ event: PlaybackEngineEvent, prepared: Bool = false) {
        continuation.yield(event)
        deliveryContinuation.yield(.init(event: event, sourceGeneration: prepared ? nil : sourceGeneration))
    }

    func loadNative(from url: URL, duration: Double) {
        queue.sync {
            resetLocked()
            engine.pause()
            let loadedGeneration = generation
            nativePlayback = NativeAudioPlayback(
                url: url, duration: duration, volume: userVolume,
                outputDeviceUID: nativeOutputDeviceUID, queue: queue
            ) { [weak self] event in
                guard let self, self.generation == loadedGeneration,
                      self.nativePlayback != nil else { return }
                self.emitLocked(event)
            }
        }
    }

    /// AI EQ processes high-resolution files at their source rate. Ordinary
    /// playback keeps its existing conversion path; only a stopped graph may
    /// change format, after the previous source has been fully retired.
    func loadFile(at url: URL, preserveSampleRate: Bool = false) throws -> TimeInterval {
        try queue.sync {
            let file = try AVAudioFile(forReading: url)
            resetLocked()
            let format = file.processingFormat
            let target = preserveSampleRate
                ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
                : AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            configureGraphFormatLocked(target)
            if format.sampleRate == graphFormat.sampleRate,
               format.channelCount == graphFormat.channelCount {
                source = .file(file)
            } else {
                let feeder = FileFeeder(file: file, output: graphFormat, queue: queue)
                source = .convertedFile(feeder)
                wireFeederLocked(feeder)
            }
            return Double(file.length) / format.sampleRate
        }
    }

    private func wireFeederLocked(_ feeder: FileFeeder) {
        feeder.onBuffer = { [weak self, weak feeder] buffer in
            guard let self, let feeder,
                  case .convertedFile(let current) = self.source, current === feeder else { return }
            self.scheduleBufferLocked(buffer) { feeder.bufferPlayed() }
            if self.streamStalled {
                self.streamStalled = false
                self.emitLocked(.streamResumed)
            }
            self.startNodeIfNeededLocked()
        }
        feeder.onEnded = { [weak self, weak feeder] in
            guard let self, let feeder,
                  case .convertedFile(let current) = self.source, current === feeder else { return }
            self.streamEnded = true
            if self.pendingBuffers == 0 { self.handleFinishedLocked(generation: self.generation) }
        }
    }

    func prepareStream(from remote: URL, formatHint: String?, writingTo partURL: URL,
                       preserveSampleRate: Bool = false) {
        queue.async {
            let identity = StreamIdentity(remote: remote, formatHint: formatHint?.lowercased(),
                                          preserveSampleRate: preserveSampleRate)
            if self.preparedStream?.identity == identity { return }
            self.cancelPreparedStreamLocked()
            // Preparing must never open a second writer over the current
            // source's mirror, or decode that same source on a second loader.
            guard self.activeStreamIdentity != identity, self.activePartURL != partURL else { return }
            let loader = self.makeStreamLoaderLocked(identity: identity, partURL: partURL)
            self.preparedStream = PreparedStream(identity: identity, partURL: partURL, loader: loader)
            loader.start()
        }
    }

    func cancelPreparedStream() { queue.async { self.cancelPreparedStreamLocked() } }

    private func cancelPreparedStreamLocked() {
        preparedStream?.loader.cancel()
        preparedStream = nil
    }

    func startStreaming(from remote: URL, formatHint: String?, writingTo partURL: URL,
                        preserveSampleRate: Bool = false) {
        queue.async {
            let identity = StreamIdentity(remote: remote, formatHint: formatHint?.lowercased(),
                                          preserveSampleRate: preserveSampleRate)
            let prepared = self.preparedStream.flatMap { $0.identity == identity ? $0 : nil }
            self.resetLocked()
            self.cancelPreparedStreamLocked(except: prepared?.loader)
            self.activeStreamIdentity = identity
            self.activePartURL = prepared?.partURL ?? partURL
            self.streamStalled = true
            if let prepared {
                self.source = .stream(prepared.loader)
                self.configureGraphFormatLocked(prepared.format ?? self.defaultStreamFormat)
                for buffer in prepared.buffers { self.acceptStreamBufferLocked(buffer, loader: prepared.loader) }
                self.streamEnded = prepared.ended
                prepared.loader.setDownloadSuspended(false)
            } else {
                self.configureGraphFormatLocked(self.defaultStreamFormat)
                let loader = self.makeStreamLoaderLocked(identity: identity, partURL: partURL)
                self.source = .stream(loader)
                loader.start()
            }
        }
    }

    /// A range-backed source can start at an uncached position without waiting
    /// for the bytes before it. Opening and decoding stay on the loader queue.
    func startRemote(from remote: URL, formatHint: String?, at seconds: TimeInterval,
                     preserveSampleRate: Bool = false) {
        queue.async {
            self.resetLocked()
            self.cancelPreparedStreamLocked()
            self.configureGraphFormatLocked(self.defaultStreamFormat)
            let position = max(0, seconds)
            self.startOffset = position
            self.lastKnownPosition = position
            self.streamStalled = true
            let loader = RemoteAudioLoader(remoteURL: remote, formatHint: formatHint,
                                           output: self.defaultStreamFormat, queue: self.queue,
                                           preserveSampleRate: preserveSampleRate, initialPosition: position)
            self.source = .remote(loader)
            self.wireRemoteLoaderLocked(loader)
            loader.start()
        }
    }

    private func wireRemoteLoaderLocked(_ loader: RemoteAudioLoader) {
        loader.onFormat = { [weak self, weak loader] format in
            guard let self, let loader,
                  case .remote(let current) = self.source, current === loader else { return }
            self.configureGraphFormatLocked(format)
            // play() may precede format discovery. A source-rate rebuild stops
            // the graph, so restart it before receiving the first PCM buffer.
            if self.wantsPlayback && !self.isPaused { self.ensureEngineRunningLocked() }
        }
        loader.onBuffer = { [weak self, weak loader] buffer in
            guard let self, let loader,
                  case .remote(let current) = self.source, current === loader else { return }
            self.scheduleBufferLocked(buffer)
            if self.streamStalled {
                self.streamStalled = false
                self.emitLocked(.streamResumed)
            }
            self.startNodeIfNeededLocked()
            if self.pendingBuffers >= self.streamHighWater { loader.setDownloadSuspended(true) }
        }
        loader.onCompleted = { [weak self, weak loader] in
            guard let self, let loader,
                  case .remote(let current) = self.source, current === loader else { return }
            self.streamEnded = true
            if self.pendingBuffers == 0 { self.handleFinishedLocked(generation: self.generation) }
        }
        loader.onError = { [weak self, weak loader] error in
            guard let self, let loader,
                  case .remote(let current) = self.source, current === loader else { return }
            self.emitLocked(.streamFailed(error))
        }
    }

    private var defaultStreamFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    private func cancelPreparedStreamLocked(except promoted: ProgressiveLoader?) {
        if let preparedStream, preparedStream.loader !== promoted { preparedStream.loader.cancel() }
        preparedStream = nil
    }

    private func makeStreamLoaderLocked(identity: StreamIdentity, partURL: URL) -> ProgressiveLoader {
        let loader = ProgressiveLoader(remoteURL: identity.remote, formatHint: identity.formatHint,
                                       partURL: partURL, output: defaultStreamFormat, queue: queue,
                                       preserveSampleRate: identity.preserveSampleRate)
        loader.onFormat = { [weak self, weak loader] format in
            guard let self, let loader else { return }
            if let prepared = self.preparedStream, prepared.loader === loader {
                prepared.format = format
            } else if case .stream(let current) = self.source, current === loader {
                self.configureGraphFormatLocked(format)
                // Format detection may stop the graph after play() already
                // ran. Restart it before the first buffer is scheduled.
                if self.wantsPlayback && !self.isPaused { self.ensureEngineRunningLocked() }
            }
        }
        loader.onBuffer = { [weak self, weak loader] buffer in
            guard let self, let loader else { return }
            if let prepared = self.preparedStream, prepared.loader === loader {
                prepared.buffers.append(buffer)
                if prepared.buffers.count >= self.preparedStreamHighWater { loader.setDownloadSuspended(true) }
            } else if case .stream(let current) = self.source, current === loader {
                self.acceptStreamBufferLocked(buffer, loader: loader)
            }
        }
        loader.onMirrorCompleted = { [weak self, weak loader] _ in
            guard let self, let loader else { return }
            if let prepared = self.preparedStream, prepared.loader === loader {
                self.emitLocked(.preparedStreamDownloadCompleted(remoteURL: identity.remote,
                                                                 partURL: prepared.partURL), prepared: true)
            } else if case .stream(let current) = self.source, current === loader {
                self.emitLocked(.streamDownloadCompleted)
            }
        }
        loader.onCompleted = { [weak self, weak loader] in
            guard let self, let loader else { return }
            if let prepared = self.preparedStream, prepared.loader === loader {
                prepared.ended = true
            } else if case .stream(let current) = self.source, current === loader {
                self.streamEnded = true
                if self.pendingBuffers == 0 { self.handleFinishedLocked(generation: self.generation) }
            }
        }
        loader.onError = { [weak self, weak loader] error in
            guard let self, let loader else { return }
            if let prepared = self.preparedStream, prepared.loader === loader {
                self.preparedStream = nil
                self.emitLocked(.preparedStreamFailed(remoteURL: identity.remote, partURL: prepared.partURL, error),
                                prepared: true)
            } else if case .stream(let current) = self.source, current === loader {
                self.emitLocked(.streamFailed(error))
            }
        }
        return loader
    }

    private func acceptStreamBufferLocked(_ buffer: AVAudioPCMBuffer, loader: ProgressiveLoader) {
        scheduleBufferLocked(buffer)
        if streamStalled {
            streamStalled = false
            emitLocked(.streamResumed)
        }
        startNodeIfNeededLocked()
        if pendingBuffers >= streamHighWater { loader.setDownloadSuspended(true) }
    }

    func play(from seconds: TimeInterval) {
        queue.async {
            self.cancelPauseDrainLocked()
            self.isPaused = false
            self.wantsPlayback = true
            if let native = self.nativePlayback { native.play(from: seconds); return }
            self.scheduleSourceLocked(from: seconds, seeking: false)
            self.ensureEngineRunningLocked()
            self.startNodeIfNeededLocked()
        }
    }

    func pause() {
        queue.async {
            guard !self.isPaused else { return }
            self.nativePlayback?.pause()
            self.lastKnownPosition = self.positionLocked()
            // Pause the node first: pausing only the engine lets its media
            // clock run ahead during the time playback is stopped.
            self.player.pause()
            self.isPaused = true
            let drain = DispatchWorkItem { [weak self] in
                guard let self, self.isPaused else { return }
                self.pauseDrain = nil
                self.engine.pause()
            }
            self.pauseDrain = drain
            let delay = self.engine.outputNode.presentationLatency + 2 * self.ioBufferDurationLocked() + 0.02
            self.queue.asyncAfter(deadline: .now() + delay, execute: drain)
        }
    }

    func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.cancelPauseDrainLocked()
            if let native = self.nativePlayback {
                self.isPaused = false
                native.resume()
                return
            }
            self.ensureEngineRunningLocked()
            guard self.engine.isRunning else { return }
            self.isPaused = false
            self.startNodeIfNeededLocked()
        }
    }

    func seek(to seconds: TimeInterval) {
        queue.async {
            if let native = self.nativePlayback { native.seek(to: seconds); return }
            self.scheduleSourceLocked(from: seconds, seeking: true)
            if !self.isPaused { self.ensureEngineRunningLocked() }
            self.startNodeIfNeededLocked()
        }
    }

    func stop() { queue.async { self.resetLocked() } }

    private func resetLocked() {
        cancelPauseDrainLocked()
        generation += 1
        sourceGeneration += 1
        nativePlayback?.stop()
        nativePlayback = nil
        switch source {
        case .stream(let loader): loader.cancel()
        case .remote(let loader): loader.cancel()
        case .convertedFile(let feeder): feeder.cancel()
        case .none, .file: break
        }
        player.stop()
        soundEqualizer.reset()
        soundRenderer.node.reset()
        source = .none
        activeStreamIdentity = nil
        activePartURL = nil
        wantsPlayback = false
        isPaused = false
        startOffset = 0
        lastKnownPosition = 0
        pendingBuffers = 0
        streamEnded = false
        streamStalled = false
    }

    private func cancelPauseDrainLocked() {
        pauseDrain?.cancel()
        pauseDrain = nil
    }

    // MARK: - Source scheduling

    private func scheduleSourceLocked(from seconds: TimeInterval, seeking: Bool) {
        let seconds = max(0, seconds)
        switch source {
        case .none: return
        case .file(let file): scheduleFileLocked(file, from: seconds)
        case .convertedFile(let feeder):
            resetScheduleLocked(from: seconds)
            feeder.start(from: seconds)
        case .stream(let loader):
            guard loader.canSeek, seeking || (seconds > 0.25 && abs(seconds - positionLocked()) > 0.5) else { return }
            resetScheduleLocked(from: seconds)
            streamStalled = true
            emitLocked(.streamStalled)
            loader.seek(to: seconds)
        case .remote(let loader):
            // Loading already positioned this source. Initial play must retain
            // its queued PCM; explicit seeks invalidate callbacks immediately.
            guard seeking || abs(seconds - startOffset) > 0.001 else { return }
            sourceGeneration += 1
            resetScheduleLocked(from: seconds)
            streamStalled = true
            emitLocked(.streamStalled)
            loader.seek(to: seconds)
        }
    }

    private func resetScheduleLocked(from seconds: TimeInterval) {
        generation += 1
        player.stop()
        // A seek is a discontinuity: neither filters nor convolution/reverb
        // may carry the previous position's history into the new audio.
        soundEqualizer.reset()
        soundRenderer.node.reset()
        pendingBuffers = 0
        streamEnded = false
        streamStalled = false
        startOffset = seconds
        lastKnownPosition = seconds
    }

    private func scheduleFileLocked(_ file: AVAudioFile, from seconds: TimeInterval) {
        let rate = file.processingFormat.sampleRate
        let start = min(file.length, AVAudioFramePosition((seconds * rate).rounded()))
        resetScheduleLocked(from: Double(start) / rate)
        let scheduledGeneration = generation
        let remaining = file.length - start
        guard remaining > 0 else {
            queue.async { [weak self] in self?.handleFinishedLocked(generation: scheduledGeneration) }
            return
        }
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleFinishedLocked(generation: scheduledGeneration) }
        }
    }

    private func scheduleBufferLocked(_ buffer: AVAudioPCMBuffer, played: (() -> Void)? = nil) {
        pendingBuffers += 1
        let scheduledGeneration = generation
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                // A stopped node also fires completions. An old callback must
                // never decrement the new schedule's buffer/feeder counters.
                guard self.generation == scheduledGeneration else { return }
                played?()
                self.pendingBuffers -= 1
                _ = self.positionLocked()
                if self.pendingBuffers <= self.streamLowWater {
                    switch self.source {
                    case .stream(let loader): loader.setDownloadSuspended(false)
                    case .remote(let loader): loader.setDownloadSuspended(false)
                    case .none, .file, .convertedFile: break
                    }
                }
                guard self.pendingBuffers == 0, self.wantsPlayback else { return }
                if self.streamEnded { self.handleFinishedLocked(generation: scheduledGeneration) }
                else if !self.streamStalled {
                    if case .remote = self.source { self.player.pause() }
                    self.streamStalled = true
                    self.emitLocked(.streamStalled)
                }
            }
        }
    }

    private func handleFinishedLocked(generation: Int) {
        guard self.generation == generation, wantsPlayback else { return }
        wantsPlayback = false
        if let duration = durationLocked() { lastKnownPosition = duration }
        emitLocked(.finished)
    }

    private func ensureEngineRunningLocked() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            startClockTimerLocked()
        } catch { emitLocked(.streamFailed(error)) }
    }

    private func startNodeIfNeededLocked(attempt: Int = 0) {
        guard wantsPlayback, !isPaused, engine.isRunning, !player.isPlaying else { return }
        // An empty playing node advances its clock while HTTP is still
        // buffering. Start the range source only after its first PCM arrives.
        if case .remote = source, pendingBuffers == 0 { return }
        // CoreAudio can report the engine running before the player's first
        // IO cycle. Re-check intent before retrying its Objective-C exception.
        guard let exception = KumoneCatchException({ self.player.play() }) else { return }
        guard attempt < 40 else {
            PlaybackJournal.note("player start failed: " + (exception.reason ?? exception.name.rawValue))
            emitLocked(.streamFailed(URLError(.cannotOpenFile)))
            return
        }
        let scheduledGeneration = generation
        queue.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.startNodeIfNeededLocked(attempt: attempt + 1)
        }
    }

    private func positionLocked() -> TimeInterval {
        if let nativePlayback { return nativePlayback.position }
        if case .remote = source, streamStalled { return lastKnownPosition }
        guard wantsPlayback, !isPaused,
              let time = player.lastRenderTime, time.isSampleTimeValid || time.isHostTimeValid,
              let rendered = player.playerTime(forNodeTime: time), rendered.sampleRate > 0 else {
            return lastKnownPosition
        }
        lastKnownPosition = max(startOffset, startOffset + Double(rendered.sampleTime) / rendered.sampleRate)
        return lastKnownPosition
    }

    private func durationLocked() -> TimeInterval? {
        if let nativePlayback { return nativePlayback.duration }
        switch source {
        case .none: return nil
        case .file(let file): return Double(file.length) / file.processingFormat.sampleRate
        case .convertedFile(let feeder): return feeder.duration
        case .stream(let loader): return loader.estimatedDuration
        case .remote(let loader): return loader.estimatedDuration
        }
    }

    private func startClockTimerLocked() {
        guard clockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in _ = self?.positionLocked() }
        timer.resume()
        clockTimer = timer
    }

    private func ioBufferDurationLocked() -> TimeInterval {
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize,
                                          kAudioUnitScope_Global, 0, &frames, &size)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return status == noErr && rate > 0 ? Double(frames) / rate : 0
    }

    // MARK: - Output

    private func connectGraphLocked() {
        engine.connect(player, to: soundEqualizer, format: graphFormat)
        engine.connect(soundEqualizer, to: soundRenderer.node, format: graphFormat)
        engine.connect(soundRenderer.node, to: engine.mainMixerNode, format: graphFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.mainMixerNode.outputVolume = userVolume
        applySoundEffectLocked()
    }

    private func configureGraphFormatLocked(_ format: AVAudioFormat) {
        guard format.sampleRate != graphFormat.sampleRate || format.channelCount != graphFormat.channelCount else { return }
        engine.stop()
        if mixerTapInstalled { engine.mainMixerNode.removeTap(onBus: 0); mixerTapInstalled = false }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(soundEqualizer)
        engine.disconnectNodeOutput(soundRenderer.node)
        graphFormat = format
        connectGraphLocked()
        installOutputSampleSinkLocked()
    }

    func setSoundEffect(_ effect: AISoundEffect?, strength: Double = 1) {
        queue.async {
            self.soundEffect = effect
            self.soundEffectStrength = strength
            self.applySoundEffectLocked()
        }
    }

    private func applySoundEffectLocked() {
        AISoundEffect.configure(soundEqualizer, effect: soundEffect, strength: soundEffectStrength,
                                sampleRate: graphFormat.sampleRate)
        soundRenderer.configure(effect: soundEffect, strength: soundEffectStrength, sampleRate: graphFormat.sampleRate)
    }

    func setOutputSampleSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        queue.sync {
            outputSampleSink = sink
            installOutputSampleSinkLocked()
        }
    }

    private func installOutputSampleSinkLocked() {
        let mixer = engine.mainMixerNode
        if mixerTapInstalled { mixer.removeTap(onBus: 0); mixerTapInstalled = false }
        guard let sink = outputSampleSink else { return }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in sink(buffer) }
        mixerTapInstalled = true
    }

    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        queue.async {
            self.nativeOutputDeviceUID = deviceID.flatMap { id in AudioOutputDevices.current().first { $0.id == id }?.uid }
            self.nativePlayback?.setOutputDevice(uid: self.nativeOutputDeviceUID)
            guard let target = deviceID ?? AudioOutputDevices.defaultDeviceID() else { return }
            let unit = self.engine.outputNode.auAudioUnit
            guard unit.deviceID != target else { return }
            self.lastKnownPosition = self.positionLocked()
            self.engine.stop()
            do { try unit.setDeviceID(target) }
            catch { PlaybackJournal.note("output device change failed: \(error)") }
            // Our rebuild covers the notification generated by this switch;
            // rebuilding a second time would discard the new schedule.
            self.ownConfigurationChangeUntil = Date().addingTimeInterval(1)
            self.rebuildGraphLocked()
        }
    }

    private func handleConfigurationChangeLocked() {
        if let until = ownConfigurationChangeUntil {
            ownConfigurationChangeUntil = nil
            if Date() < until { return }
        }
        rebuildGraphLocked()
    }

    private func rebuildGraphLocked() {
        cancelPauseDrainLocked()
        generation += 1
        engine.stop()
        connectGraphLocked()
        installOutputSampleSinkLocked()
        guard nativePlayback == nil else { return }
        if case .none = source { return }
        scheduleSourceLocked(from: lastKnownPosition, seeking: true)
        if !isPaused { ensureEngineRunningLocked(); startNodeIfNeededLocked() }
    }

    #if DEBUG
    var preparedStreamBufferCount: Int { queue.sync { preparedStream?.buffers.count ?? 0 } }
    var preparedStreamLoaderID: ObjectIdentifier? { queue.sync { preparedStream.map { ObjectIdentifier($0.loader) } } }
    var activeStreamLoaderID: ObjectIdentifier? {
        queue.sync {
            if case .stream(let loader) = source { return ObjectIdentifier(loader) }
            return nil
        }
    }
    var activeRemoteLoaderID: ObjectIdentifier? {
        queue.sync {
            if case .remote(let loader) = source { return ObjectIdentifier(loader) }
            return nil
        }
    }
    var scheduledBufferCount: Int { queue.sync { pendingBuffers } }
    var processingSampleRate: Double { queue.sync { graphFormat.sampleRate } }
    // Inspect actual source audio without changing user volume in regressions.
    var sourceVolume: Float { queue.sync { player.volume } }
    private var monitorInstalled = false
    func setOutputMonitor(_ block: (@Sendable (Float) -> Void)?) {
        queue.sync {
            if monitorInstalled { player.removeTap(onBus: 0); monitorInstalled = false }
            guard let block else { return }
            player.installTap(onBus: 0, bufferSize: 512, format: graphFormat) { buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                var peak: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
                }
                block(peak)
            }
            monitorInstalled = true
        }
    }
    func setTimedOutputMonitor(_ block: (@Sendable (Float, TimeInterval) -> Void)?) {
        queue.sync {
            if monitorInstalled { player.removeTap(onBus: 0); monitorInstalled = false }
            guard let block else { return }
            player.installTap(onBus: 0, bufferSize: 512, format: graphFormat) { buffer, when in
                guard let channels = buffer.floatChannelData, when.isHostTimeValid else { return }
                // Tap buffers may be much larger than requested and arrive
                // late. Timestamp small windows by their actual first sample.
                let start = AVAudioTime.seconds(forHostTime: when.hostTime)
                for offset in stride(from: 0, to: Int(buffer.frameLength), by: 512) {
                    var peak: Float = 0
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in offset..<min(offset + 512, Int(buffer.frameLength)) {
                            peak = max(peak, abs(channels[channel][frame]))
                        }
                    }
                    block(peak, start + Double(offset) / buffer.format.sampleRate)
                }
            }
            monitorInstalled = true
        }
    }
    func simulateConfigurationChange() { queue.async { self.handleConfigurationChangeLocked() } }
    #endif
}
