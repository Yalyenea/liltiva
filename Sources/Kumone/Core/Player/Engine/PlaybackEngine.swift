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
}

/// One source at a time. PCM goes straight from the player node to the mixer;
/// high-resolution and spatial formats use the native renderer. Mutable state
/// and loader callbacks share a serial queue. Completion generations distinguish
/// natural endings from stop/seek/reload callbacks.
final class PlaybackEngine: @unchecked Sendable {
    let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
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
    }
    private var source: Source = .none
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
        events = AsyncStream { c = $0 }
        continuation = c
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
        continuation.finish()
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
                self.continuation.yield(event)
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
                self.continuation.yield(.streamResumed)
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

    func startStreaming(from remote: URL, formatHint: String?, writingTo partURL: URL) {
        queue.async {
            self.resetLocked()
            self.configureGraphFormatLocked(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
            let loader = ProgressiveLoader(remoteURL: remote, formatHint: formatHint,
                                           partURL: partURL, output: self.graphFormat, queue: self.queue)
            self.source = .stream(loader)
            self.streamStalled = true
            loader.onBuffer = { [weak self, weak loader] buffer in
                guard let self, let loader,
                      case .stream(let current) = self.source, current === loader else { return }
                self.scheduleBufferLocked(buffer)
                if self.streamStalled {
                    self.streamStalled = false
                    self.continuation.yield(.streamResumed)
                }
                self.startNodeIfNeededLocked()
                if self.pendingBuffers >= self.streamHighWater { loader.setDownloadSuspended(true) }
            }
            loader.onMirrorCompleted = { [weak self, weak loader] _ in
                guard let self, let loader,
                      case .stream(let current) = self.source, current === loader else { return }
                self.continuation.yield(.streamDownloadCompleted)
            }
            loader.onCompleted = { [weak self, weak loader] in
                guard let self, let loader,
                      case .stream(let current) = self.source, current === loader else { return }
                self.streamEnded = true
                if self.pendingBuffers == 0 { self.handleFinishedLocked(generation: self.generation) }
            }
            loader.onError = { [weak self, weak loader] error in
                guard let self, let loader,
                      case .stream(let current) = self.source, current === loader else { return }
                self.continuation.yield(.streamFailed(error))
            }
            loader.start()
        }
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
        nativePlayback?.stop()
        nativePlayback = nil
        switch source {
        case .stream(let loader): loader.cancel()
        case .convertedFile(let feeder): feeder.cancel()
        case .none, .file: break
        }
        player.stop()
        soundEqualizer.reset()
        soundRenderer.node.reset()
        source = .none
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
            continuation.yield(.streamStalled)
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
                if case .stream(let loader) = self.source, self.pendingBuffers <= self.streamLowWater {
                    loader.setDownloadSuspended(false)
                }
                guard self.pendingBuffers == 0, self.wantsPlayback else { return }
                if self.streamEnded { self.handleFinishedLocked(generation: scheduledGeneration) }
                else if !self.streamStalled {
                    self.streamStalled = true
                    self.continuation.yield(.streamStalled)
                }
            }
        }
    }

    private func handleFinishedLocked(generation: Int) {
        guard self.generation == generation, wantsPlayback else { return }
        wantsPlayback = false
        if let duration = durationLocked() { lastKnownPosition = duration }
        continuation.yield(.finished)
    }

    private func ensureEngineRunningLocked() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            startClockTimerLocked()
        } catch { continuation.yield(.streamFailed(error)) }
    }

    private func startNodeIfNeededLocked(attempt: Int = 0) {
        guard wantsPlayback, !isPaused, engine.isRunning, !player.isPlaying else { return }
        // CoreAudio can report the engine running before the player's first
        // IO cycle. Re-check intent before retrying its Objective-C exception.
        guard let exception = KumoneCatchException({ self.player.play() }) else { return }
        guard attempt < 40 else {
            PlaybackJournal.note("player start failed: " + (exception.reason ?? exception.name.rawValue))
            continuation.yield(.streamFailed(URLError(.cannotOpenFile)))
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
