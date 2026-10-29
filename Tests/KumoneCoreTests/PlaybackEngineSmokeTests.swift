import Testing
@testable import KumoneCore
import AVFoundation
import AudioToolbox
import Foundation
import Darwin

// Local, network-free smoke tests for PlaybackEngine.
//
// Fixtures are generated programmatically into a temp directory (nothing
// binary is committed):
// - File-deck fixtures: LPCM sine .caf written with AVAudioFile.
// - Streaming fixture: AAC in an ADTS container (.aac) written with
//   ExtAudioFile. Rationale: ProgressiveLoader rejects LPCM streams
//   (setUpConverter requires a compressed format), and AVAudioFile-written
//   .m4a puts the moov atom at the end of the file, which AudioFileStream
//   cannot parse progressively. ADTS is a self-framing stream format —
//   exactly what AudioFileStream is built for — so we go straight to it.
//
// The streaming fixture is served by a minimal POSIX-socket HTTP server on
// 127.0.0.1 (GET 200 with Content-Length; "bytes=N-" Range requests get 206).
//
// Every test runs its body under a watchdog: if it exceeds the timeout, the
// process samples itself with /usr/bin/sample so a deadlock leaves a thread
// stack in the log, then records a failure and abandons the (possibly stuck)
// worker thread instead of hanging the whole run.
//
// ENGINE BUGS THESE TESTS CAUGHT (both fixed; kept as regression coverage):
// 1. deliver() stale-accum spin (tests c/c2): binding `guard let accum` to a
//    LOCAL that went stale when flushAccum() swapped self.accum caused an
//    infinite busy-loop mid-chunk — only the first 0.5s buffer was ever
//    delivered, and on the original design (URLSession delegate queue == the
//    engine queue) the spin pinned the engine queue, so position(of:) blocked
//    forever: the reported "app not responding". Fixed by re-reading
//    self.accum every loop iteration.
// 2. AVAudioConverter poisoning AudioFileStream (test c2, flakily c/d):
//    whenever AVAudioConverter decoded AAC anywhere in the process, the next
//    AudioFileStreamParseBytes call failed with 'wht?', so a stream whose
//    bytes arrived in more than one didReceive callback died mid-parse. The
//    loader's fail() path then cancelled its own task, and the resulting
//    NSURLErrorCancelled completion was swallowed silently — no
//    .streamDownloadCompleted, no .streamFailed, position counting past the
//    track length. Reproduced standalone (per-packet, batched, deferred, and
//    cross-thread convert calls all poison the parser; macOS 26). Fixed by
//    decoding with the C AudioConverter API, between parse calls.

// MARK: - Fixtures

enum Fixtures {

    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackEngineSmoke-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 6 s 44.1 kHz mono sine .caf — file-deck fixture.
    static let sixSecondCAF: URL = try! writeSineCAF(seconds: 6, name: "six")

    /// 8 s variant for the gapless "A" deck.
    static let eightSecondCAF: URL = try! writeSineCAF(seconds: 8, name: "eight")

    /// 21 s AAC/ADTS — long enough for many 0.5 s stream buffers and to cross
    /// the engine's 40-buffer (≈20 s) high-water backpressure mark.
    static let streamADTS: URL = try! writeSineADTS(seconds: 21, name: "stream")

    /// 18 s AAC/ADTS — 36 buffers, stays below the 40-buffer high-water mark
    /// so the download is never suspended. Used by the happy-path streaming
    /// test; the 21 s fixture above deterministically reproduces a suspend /
    /// completion race (see streamBackpressureSwallowsCompletion).
    static let streamShortADTS: URL = try! writeSineADTS(seconds: 18, name: "stream18")

    /// 8 s 44.1 kHz *stereo* sine .caf — matches the graph format exactly, so
    /// the deck takes the sample-accurate `.file` / scheduleSegment path
    /// rather than the chunk-converted `.convertedFile` one the mono fixtures
    /// above go through.
    static let eightSecondStereoCAF: URL = try! writeSineCAF(seconds: 8, channels: 2, name: "eight-stereo")

    /// 6 s stereo twin of `sixSecondCAF` — the incoming deck of the
    /// seek-fallback test has to take the `.file` path too, or a `.gapless`
    /// hand-over cannot be armed on the host clock (armGaplessLocked).
    static let sixSecondStereoCAF: URL = try! writeSineCAF(seconds: 6, channels: 2, name: "six-stereo")

    /// 8 s 44.1 kHz *mono* sine that goes digitally silent after 4 s. Mono →
    /// the chunk-converted (buffer-fed) deck path. Used by the seek-residue
    /// test: seek from the loud half into the silent half and anything the
    /// monitor still hears is audio from the pre-seek position.
    static let loudThenSilentCAF: URL =
        try! writeSineCAF(seconds: 8, silentAfter: 4, name: "loud-silent")

    /// Stereo twin of the above → the sample-accurate `.file` deck path.
    static let loudThenSilentStereoCAF: URL =
        try! writeSineCAF(seconds: 8, channels: 2, silentAfter: 4, name: "loud-silent-stereo")

    /// 12 s 44.1 kHz stereo **ramp**: frame i carries (i + 1)·1e-7 on both
    /// channels, so a sample read off the engine's output says which frame of
    /// the file it is. `.file` deck path (stereo at the graph rate).
    static let rampRate: Double = 44_100
    static let rampStereoCAF: URL = try! writeRampCAF(seconds: 12, name: "ramp-stereo")

    static func writeRampCAF(seconds: Double, name: String) throws -> URL {
        try writeCAF(seconds: seconds, sampleRate: rampRate, channels: 2, name: name) {
            Float($0 + 1) * 1e-7
        }
    }

    static func writeSineCAF(seconds: Double, sampleRate: Double = 44_100,
                             channels: AVAudioChannelCount = 1,
                             silentAfter: Double? = nil, name: String) throws -> URL {
        let lastLoudFrame = silentAfter.map { Int($0 * sampleRate) } ?? Int.max
        return try writeCAF(seconds: seconds, sampleRate: sampleRate, channels: channels,
                            name: name) { frame in
            frame < lastLoudFrame
                ? 0.25 * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
                : 0
        }
    }

    /// Every channel carries `sample(frame)`. Cached by name.
    static func writeCAF(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
                         name: String, sample: (Int) -> Float) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunkFrames: AVAudioFrameCount = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
        var frame = 0
        let total = Int(seconds * sampleRate)
        while frame < total {
            let n = min(Int(chunkFrames), total - frame)
            for channel in 0..<Int(channels) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<n { data[i] = sample(frame + i) }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            frame += n
        }
        return url
    }

    /// AAC in ADTS framing via ExtAudioFile (hardware-independent encoder).
    static func writeSineADTS(seconds: Double, sampleRate: Double = 44_100, name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).aac")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        var outDesc = AudioStreamBasicDescription()
        outDesc.mSampleRate = sampleRate
        outDesc.mFormatID = kAudioFormatMPEG4AAC
        outDesc.mChannelsPerFrame = 1
        // Leave the rest zero: the encoder fills them in.

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType,
                                               &outDesc, nil,
                                               AudioFileFlags.eraseFile.rawValue, &extFile)
        guard status == noErr, let ext = extFile else {
            throw NSError(domain: "Fixtures", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "ExtAudioFileCreateWithURL(ADTS) failed (\(status))"])
        }
        defer { ExtAudioFileDispose(ext) }

        // Client format: interleaved (packed) float32 mono LPCM.
        var clientDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                         &clientDesc)
        guard status == noErr else {
            throw NSError(domain: "Fixtures", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "SetProperty(ClientDataFormat) failed (\(status))"])
        }

        let chunk = 4096
        var samples = [Float](repeating: 0, count: chunk)
        var frame = 0
        let total = Int(seconds * sampleRate)
        while frame < total {
            let n = min(chunk, total - frame)
            for i in 0..<n {
                samples[i] = 0.25 * sinf(2 * .pi * 440 * Float(frame + i) / Float(sampleRate))
            }
            status = samples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1,
                                          mDataByteSize: UInt32(n * 4),
                                          mData: UnsafeMutableRawPointer(ptr.baseAddress)))
                return ExtAudioFileWrite(ext, UInt32(n), &abl)
            }
            guard status == noErr else {
                throw NSError(domain: "Fixtures", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "ExtAudioFileWrite failed (\(status))"])
            }
            frame += n
        }
        return url
    }
}

// MARK: - Minimal local HTTP server (POSIX sockets)

final class TestHTTPServer: @unchecked Sendable {

    let port: UInt16
    private let data: Data
    private let listenFD: Int32
    private let thread: Thread

    init(serving data: Data) throws {
        self.data = data
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // random port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)

        let serveData = data
        let serveFD = fd
        thread = Thread {
            while true {
                let client = accept(serveFD, nil, nil)
                if client < 0 { break } // listen socket closed → stop
                TestHTTPServer.handle(client: client, data: serveData)
            }
        }
        thread.name = "TestHTTPServer"
        thread.start()
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/fixture.aac")! }

    func stop() { close(listenFD) }

    private static func handle(client: Int32, data: Data) {
        defer { close(client) }
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Read until end of headers (tiny requests; one read is usually enough).
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while !request.contains(0x0D) || request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(client, &buf, buf.count)
            guard n > 0 else { return }
            request.append(contentsOf: buf[0..<n])
            if request.count > 65_536 { return }
        }
        let head = String(decoding: request, as: UTF8.self)

        // Range support: "Range: bytes=N-" and "bytes=N-M".
        var lo = 0
        var hi = data.count - 1
        var partial = false
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("range:") {
            let spec = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard spec.lowercased().hasPrefix("bytes=") else { continue }
            let parts = spec.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let start = Int(parts[0]), start < data.count {
                lo = start
                if let end = Int(parts[1]), end < data.count { hi = end }
                partial = true
            }
        }

        let body = data.subdata(in: lo..<(hi + 1))
        var header = partial
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(lo)-\(hi)/\(data.count)\r\n"
            : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: audio/aac\r\nAccept-Ranges: bytes\r\n"
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"

        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

// MARK: - Watchdog

/// Runs `body` on its own thread. If it does not finish within `timeout`,
/// samples this process (thread stacks land in the test log), records a
/// failure, and returns nil — leaking the stuck thread rather than hanging
/// the test run.
private func withWatchdog<T>(_ label: String, timeout: TimeInterval,
                             _ body: @escaping () -> T) async -> T? {
    let result = await runWithWatchdog(label, timeout: timeout, body)
    if result == nil {
        // Diagnostics must not turn a bounded test timeout into another hang.
        _ = await runWithWatchdog("sample-\(label)", timeout: 20) {
            dumpProcessSample(label: label)
        }
        Issue.record("Watchdog: '\(label)' did not finish within \(timeout)s — likely deadlock/blocked queue; see sample above")
    }
    return result
}

private func dumpProcessSample(label: String) {
    print("=== WATCHDOG TIMEOUT (\(label)): sampling pid \(getpid()) ===")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    p.arguments = ["\(getpid())", "2"]
    // Inherit output rather than blocking on an unbounded pipe read.
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    // `sample` writes straight to fd 1, while `print` is block-buffered when
    // stdout is a pipe; flush so the dump lands between its two markers.
    fflush(stdout)
    do {
        try p.run()
        // A 2 s sample takes about 3 s on an idle Mac; symbolicating on a
        // loaded runner takes longer, and a killed sample prints nothing.
        if exited.wait(timeout: .now() + 15) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            print("sample exceeded its 15s deadline")
        }
    } catch {
        print("sample failed: \(error)")
    }
    print("=== END SAMPLE (\(label)) ===")
    fflush(stdout)
}

// MARK: - Event collection

/// Consumes the engine's single-consumer AsyncStream on a dedicated Task and
/// makes events poll-able from synchronous test code.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlaybackEngineEvent] = []
    private var task: Task<Void, Never>?

    init(_ engine: PlaybackEngine) {
        // Tests run at medium priority, and at the start of a run hundreds of
        // them queue for the cooperative pool (about 30 s of backlog on CI).
        // At .high the consumer goes to the front of that queue, so an event
        // is not late just because other suites are busy.
        task = Task(priority: .high) {
            for await event in engine.events {
                self.append(event)
            }
        }
    }

    private func append(_ event: PlaybackEngineEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    deinit { task?.cancel() }

    func snapshot() -> [PlaybackEngineEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func contains(_ predicate: (PlaybackEngineEvent) -> Bool) -> Bool {
        snapshot().contains(where: predicate)
    }

    /// Polls every 50 ms until an event matches or the timeout passes.
    @discardableResult
    func wait(timeout: TimeInterval, for predicate: (PlaybackEngineEvent) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if contains(predicate) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return contains(predicate)
    }
}

// MARK: - Shared helpers

/// Can AVAudioEngine drive a real-time output device? Starting is not enough:
/// GitHub's macOS runners expose an output that starts fine but whose clock
/// never advances, so every playback test would sit out its watchdog. Require
/// the output's sample time to cover at least half of a one-second wait;
/// environments that fail skip the playback assertions.
private let audioOutputAvailable = Task {
    // CoreAudio's first initialization can be slow on a loaded runner. Bound
    // the formerly unguarded probe without tightening the playback budgets.
    await withWatchdog("audioOutputProbe", timeout: 45) {
        probeAudioOutput()
    } ?? false
}

private func probeAudioOutput() -> Bool {
    let engine = AVAudioEngine()
    engine.mainMixerNode.outputVolume = 0
    engine.prepare()
    do {
        try engine.start()
    } catch {
        print("PlaybackEngineSmoke: no usable audio output (\(error)); playback tests will be skipped")
        return false
    }
    defer { engine.stop() }

    func renderedSampleTime() -> AVAudioTime? {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let time = engine.outputNode.lastRenderTime, time.isSampleTimeValid { return time }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
    guard let start = renderedSampleTime() else {
        print("PlaybackEngineSmoke: output never rendered; playback tests will be skipped")
        return false
    }
    Thread.sleep(forTimeInterval: 1)
    guard let end = renderedSampleTime() else { return false }
    let advanced = Double(end.sampleTime - start.sampleTime) / start.sampleRate
    // CI runners' virtual outputs can run well under real time; say so, since
    // it is the first thing to check when a real-time assertion flakes there.
    print("PlaybackEngineSmoke: output clock ran \(advanced)s in 1s of wall time")
    guard advanced >= 0.5 else {
        print("PlaybackEngineSmoke: output clock advanced \(advanced)s in 1s; playback tests will be skipped")
        return false
    }
    return true
}

/// Poll `engine.position(of:)` until it exceeds `target` or `timeout` passes.
private func pollPosition(_ engine: PlaybackEngine, past target: TimeInterval,
                          timeout: TimeInterval) -> TimeInterval {
    let deadline = Date().addingTimeInterval(timeout)
    var last: TimeInterval = 0
    while Date() < deadline {
        last = engine.position
        if last > target { return last }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return last
}

// MARK: - Tests

@Suite("PlaybackEngineSmoke", .serialized)
struct PlaybackEngineSmokeTests {

    @Test func aiProcessingPreservesHighResolutionThroughSeekAndDeviceRebuild() async throws {
        guard await audioOutputAvailable.value else { return }
        let source = try Fixtures.writeSineCAF(seconds: 6, sampleRate: 96_000, channels: 2, name: "ai-hires-96k")
        let engine = PlaybackEngine()
        defer { engine.stop() }
        engine.outputVolume = 0
        _ = try engine.loadFile(at: source, preserveSampleRate: true)
        #expect(engine.processingSampleRate == 96_000)
        engine.setSoundEffect(AISoundEffect(aev2: .init(eq: .init(on: true, eqs: Array(repeating: 1, count: 10))), effectStyle: nil))
        engine.play(from: 0)
        #expect(pollPosition(engine, past: 0.3, timeout: 3) > 0.3)
        engine.seek(to: 2)
        #expect(pollPosition(engine, past: 2.2, timeout: 3) > 2.2)
        engine.simulateConfigurationChange()
        #expect(pollPosition(engine, past: 2.7, timeout: 3) > 2.7)
        #expect(engine.processingSampleRate == 96_000)
        engine.stop()
        engine.setSoundEffect(nil)
        _ = try engine.loadFile(at: Fixtures.eightSecondStereoCAF)
        #expect(engine.processingSampleRate == 44_100)
    }

    // (a) Local file deck: position advances, deckFinished on natural end.
    @Test func filePlaybackAdvancesAndFinishes() async throws {
        guard await audioOutputAvailable.value else { return } // skipped: no audio device
        let result = await withWatchdog("filePlayback", timeout: 35) { () -> (TimeInterval, Bool) in
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stop() }
            do {
                _ = try engine.loadFile(at: Fixtures.sixSecondCAF)
            } catch {
                return (-1, false)
            }
            engine.outputVolume = 0
            engine.play(from: 0)
            let pos = pollPosition(engine, past: 1.0, timeout: 3)
            // 6 s of audio; the budget allows for an output clock running at
            // ~half speed (see `audioOutputAvailable`).
            let finished = log.wait(timeout: 20) {
                if case .finished = $0 { return true }
                return false
            }
            return (pos, finished)
        }
        guard let (position, finished) = result else { return } // watchdog already failed the test
        #expect(position > 1.0, "position should advance past 1s within 3s (got \(position))")
        #expect(finished, ".finished should arrive after the 6s file drains")
    }

    // (b) seek / pause / resume semantics on a file deck.
    @Test func seekPauseResume() async throws {
        guard await audioOutputAvailable.value else { return }
        struct Outcome { var seekPos = TimeInterval(-1); var pausedA = TimeInterval(-1)
                         var pausedB = TimeInterval(-1); var resumed = TimeInterval(-1) }
        let result = await withWatchdog("seekPauseResume", timeout: 25) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            defer { engine.stop() }
            guard (try? engine.loadFile(at: Fixtures.sixSecondCAF)) != nil else { return o }
            engine.outputVolume = 0
            engine.play(from: 0)
            Thread.sleep(forTimeInterval: 0.5)

            engine.seek(to: 3)
            // Seek is async on the engine queue; wait for it to land.
            o.seekPos = pollPosition(engine, past: 2.9, timeout: 1)

            engine.pause()
            Thread.sleep(forTimeInterval: 0.2) // let the async pause land
            o.pausedA = engine.position
            Thread.sleep(forTimeInterval: 0.5)
            o.pausedB = engine.position

            engine.resume()
            Thread.sleep(forTimeInterval: 1.0)
            o.resumed = engine.position
            return o
        }
        guard let o = result else { return }
        #expect(abs(o.seekPos - 3) <= 0.3, "position after seek(3) should be 3±0.3 (got \(o.seekPos))")
        #expect(abs(o.pausedB - o.pausedA) < 0.05,
                "position must freeze while paused (\(o.pausedA) → \(o.pausedB))")
        #expect(o.resumed > o.pausedB + 0.5,
                "position must advance after resume (\(o.pausedB) → \(o.resumed))")
    }

    // (b2) **A resume must not cut a hole into the sound, must pick the song
    // up where it stopped, and must leave the playhead on what is heard**
    // (#136).
    //
    // Measured on the engine's real output (`setOutputSampleSink`, behind the user volume) with a ramp-coded fixture: file frame i
    // carries (i + 1)·1e-7, so every output sample says which frame of the
    // file it is. One assertion per way this has been wrong — a hole after
    // the restart, the song skipping ahead, the playhead drifting off the
    // audio; the measurements are in `PlaybackEngine.pause()`. Silence at the
    // pause itself is the pause, so the hole check starts at the first
    // sounding frame after each resume.
    @Test func resumeIsContinuousAndThePlayheadTracksTheOutput() async throws {
        guard await audioOutputAvailable.value else { return }
        final class Capture: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Float] = []
            private(set) var rate: Double = 0
            func append(_ buffer: AVAudioPCMBuffer) {
                guard let data = buffer.floatChannelData else { return }
                lock.lock(); defer { lock.unlock() }
                rate = buffer.format.sampleRate
                values.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                              count: Int(buffer.frameLength)))
            }
            func snapshot() -> (values: [Float], rate: Double) {
                lock.lock(); defer { lock.unlock() }
                return (values, rate)
            }
            var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
        }
        struct Outcome {
            var pcm: [Float] = []; var rate: Double = 0
            var marks: [(pause: Int, resume: Int)] = []
            /// (position, output frame count) read together, three at a time,
            /// before the first pause and after every resume.
            var pairs: [[(position: TimeInterval, frames: Int)]] = []
        }
        let cycles = 3
        let fileRate = Fixtures.rampRate
        let result = await withWatchdog("resumeContinuity", timeout: 40) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            let capture = Capture()
            defer { engine.setOutputSampleSink(nil); engine.stop() }
            guard (try? engine.loadFile(at: Fixtures.rampStereoCAF)) != nil else { return o }
            // The ramp is a slow DC sweep; at 1 % it is −65 dBFS at its peak.
            engine.outputVolume = 0.01
            engine.setOutputSampleSink { capture.append($0) }
            // Pair a position with the output it belongs to: wait for a fresh
            // delivery, then read both. Tap buffers are ~0.1 s, so an unpaired
            // read would jitter by that much.
            func pairs() -> [(TimeInterval, Int)] { (0..<3).map { _ in pair() } }
            func pair() -> (TimeInterval, Int) {
                let seen = capture.count
                let deadline = Date().addingTimeInterval(1)
                while capture.count == seen, Date() < deadline { Thread.sleep(forTimeInterval: 0.0005) }
                let position = engine.position
                return (position, capture.count)
            }
            engine.play(from: 0)
            _ = pollPosition(engine, past: 1.0, timeout: 5)
            o.pairs.append(pairs())
            for _ in 0..<cycles {
                let pauseMark = capture.count
                engine.pause()
                // Well past the drain, so the engine really freezes.
                Thread.sleep(forTimeInterval: 0.7)
                o.marks.append((pauseMark, capture.count))
                engine.resume()
                Thread.sleep(forTimeInterval: 0.9)
                o.pairs.append(pairs())
            }
            (o.pcm, o.rate) = capture.snapshot()
            return o
        }
        guard let o = result else { return }
        guard o.rate > 0, o.marks.count == cycles, let firstPair = o.pairs.first?.first,
              firstPair.frames > 24_000 else {
            Issue.record("no output PCM was captured (rate \(o.rate), \(o.marks.count) cycles)")
            return
        }
        let pcm = o.pcm
        // The ramp's slope per output frame, from steady playback before the
        // first pause: a long window, so resampling ripple averages out.
        let hi = firstPair.frames - 1, lo = hi - 12_000
        let step = Double(pcm[hi] - pcm[lo]) / Double(hi - lo)
        guard step > 0 else { Issue.record("the ramp fixture did not reach the output"); return }
        /// Seconds of the file the output sample `i` is carrying.
        func content(_ i: Int) -> TimeInterval {
            (Double(pcm[i]) / (step * o.rate / fileRate) - 1) / fileRate
        }
        /// A frame on the ramp proper — not silence, not a filter's settling
        /// after a start or a stop.
        func steady(_ i: Int) -> Bool {
            guard i > 0, i + 1 < pcm.count else { return false }
            let a = Double(pcm[i] - pcm[i - 1]) / step, b = Double(pcm[i + 1] - pcm[i]) / step
            return pcm[i] > 0 && abs(a - 1) < 0.5 && abs(b - 1) < 0.5
        }
        func lead(_ p: (position: TimeInterval, frames: Int)) -> TimeInterval? {
            guard let i = stride(from: p.frames - 1, to: max(0, p.frames - 4_800), by: -1)
                .first(where: steady) else { return nil }
            return p.position - (content(i) + Double(p.frames - 1 - i) / o.rate)
        }
        let silence: Float = 1e-9
        let maxRun = Int(o.rate * 0.001)
        for (k, mark) in o.marks.enumerated() {
            let end = k + 1 < o.marks.count ? o.marks[k + 1].pause : pcm.count
            guard let first = (mark.resume..<end).first(where: { pcm[$0] > silence }),
                  (first..<end).contains(where: steady) else {
                Issue.record("resume \(k): the deck never sounded again, or the ramp is unreadable")
                continue
            }
            var run = 0, worst = 0
            for i in first..<end {
                run = pcm[i] > silence ? 0 : run + 1
                worst = max(worst, run)
            }
            #expect(worst <= maxRun, """
                resume \(k): \(String(format: "%.2f", 1000 * Double(worst) / o.rate)) ms of \
                digital silence inside resumed sound
                """)
            // Walk the ramp from just before the pause to the next one. Where
            // steady frames are adjacent the song must advance by exactly one
            // output frame; where something interrupts them (the pause, a
            // filter settling after the start) it may come back a little
            // early — the replay — but never skip ahead.
            var previous: Int?
            var skips: [String] = []
            for i in max(1, mark.pause - 4_800)..<end where steady(i) {
                defer { previous = i }
                guard let p = previous else { continue }
                if i == p + 1 {
                    let step = content(i) - content(p) - 1 / o.rate
                    if abs(step) > 0.002 { skips.append(String(format: "%+.1f ms", 1000 * step)) }
                } else {
                    let jump = content(i) - content(p)
                    if !(jump > -0.04 && jump < 0.01) {
                        skips.append(String(format: "%+.1f ms across %d frames", 1000 * jump, i - p))
                    }
                }
            }
            #expect(skips.isEmpty, "resume \(k): the song jumped: \(skips.prefix(4))")
        }
        // The median of three paired reads: one read can still land a few ms
        // either side of the delivery it was paired with.
        let leads: [TimeInterval?] = o.pairs.map { reads in
            let values = reads.compactMap(lead).sorted()
            return values.count == reads.count ? values[values.count / 2] : nil
        }
        let shown = leads.map { $0.map { String(format: "%+.4f", $0) } ?? "nil" }.joined(separator: " ")
        print("resumeContinuity: position − heard content, before and after each pause: \(shown)")
        guard let base = leads.first ?? nil, !leads.contains(where: { $0 == nil }) else {
            Issue.record("a position/output pair could not be read (\(shown))")
            return
        }
        let moved = leads.compactMap { $0 }.map { abs($0 - base) }.max() ?? 0
        #expect(moved < 0.02, "the playhead moved \(moved) s off the output over \(cycles) pauses (\(shown))")
    }

    // (c) Progressive streaming from a local HTTP server: position advances,
    // download completes, and the .part mirror matches the fixture bytes.
    @Test func streamingPlaybackAndPartFile() async throws {
        guard await audioOutputAvailable.value else { return }
        let fixtureData = try Data(contentsOf: Fixtures.streamShortADTS)
        let server = try TestHTTPServer(serving: fixtureData)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("stream-c.part")
        try? FileManager.default.removeItem(at: partURL)

        struct Outcome { var pos = TimeInterval(-1); var downloadDone = false
                         var failed: String?; var partSize = -1 }
        let serverURL = server.url
        // 18s fixture: below the high-water mark, the local download is never
        // suspended, so streamDownloadCompleted arrives within seconds.
        let result = await withWatchdog("streaming", timeout: 30) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stop() }
            engine.outputVolume = 0
            engine.startStreaming(from: serverURL, formatHint: "aac", writingTo: partURL)
            engine.play(from: 0)
            o.pos = pollPosition(engine, past: 1.0, timeout: 3)
            o.downloadDone = log.wait(timeout: 20) {
                if case .streamDownloadCompleted = $0 { return true }
                return false
            }
            for event in log.snapshot() {
                if case .streamFailed(let error) = event { o.failed = "\(error)" }
            }
            o.partSize = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int ?? -1) ?? -1
            return o
        }
        guard let o = result else { return }
        #expect(o.failed == nil, "stream failed: \(o.failed ?? "")")
        #expect(o.pos > 1.0, "stream position should advance past 1s within 3s (got \(o.pos))")
        #expect(o.downloadDone, ".streamDownloadCompleted should arrive")
        #expect(o.partSize == fixtureData.count,
                ".part size (\(o.partSize)) should equal fixture size (\(fixtureData.count))")
    }

    // (d) KEY: main-thread responsiveness. While a stream is spinning up and
    // decoding, position(of:) — a queue.sync hop, exactly what the UI thread
    // does — must never block for long. This is the "app not responding"
    // reproduction: if decode work floods the engine queue, single calls here
    // stall for hundreds of ms.
    @Test func positionCallLatencyDuringStreaming() async throws {
        guard await audioOutputAvailable.value else { return }
        let fixtureData = try Data(contentsOf: Fixtures.streamADTS)
        let server = try TestHTTPServer(serving: fixtureData)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("stream-d.part")
        try? FileManager.default.removeItem(at: partURL)

        struct Outcome { var maxMs = -1.0; var meanMs = -1.0; var calls = 0; var over100 = 0 }
        let serverURL = server.url
        let result = await withWatchdog("positionLatency", timeout: 30) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            defer { engine.stop() }
            engine.outputVolume = 0
            engine.startStreaming(from: serverURL, formatHint: "aac", writingTo: partURL)
            engine.play(from: 0)

            // First 3 seconds after stream start: poll from this (non-engine)
            // thread at 10 Hz, timing each queue.sync round trip.
            var durations: [Double] = []
            let end = Date().addingTimeInterval(3.0)
            while Date() < end {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = engine.position
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                durations.append(ms)
                Thread.sleep(forTimeInterval: 0.1)
            }
            o.calls = durations.count
            o.maxMs = durations.max() ?? -1
            o.meanMs = durations.reduce(0, +) / Double(max(durations.count, 1))
            o.over100 = durations.filter { $0 >= 100 }.count
            return o
        }
        guard let o = result else { return }
        print("positionCallLatency: calls=\(o.calls) max=\(String(format: "%.2f", o.maxMs))ms " +
              "mean=\(String(format: "%.3f", o.meanMs))ms callsOver100ms=\(o.over100)")
        #expect(o.maxMs < 100,
                "max single position(of:) latency must stay under 100ms; measured \(String(format: "%.2f", o.maxMs))ms over \(o.calls) calls (\(o.over100) calls ≥100ms) — a failure here reproduces the 'not responding' hang")
    }

    // (c2) Same as (c) but with a fixture LONGER than the 40-buffer (≈20s)
    // high-water mark, so a correct engine must exercise the backpressure
    // suspend/resume path before the download can complete. This test caught
    // engine bug #2 (see the suite header): with AVAudioConverter as the
    // decoder, any stream delivered in more than one didReceive chunk died on
    // the next parse call, and the failure was swallowed silently. It also
    // guards the backpressure design itself: suspension pauses parsing (bytes
    // keep arriving into a backlog and the .part mirror), never the
    // URLSession task, so the transfer's completion callback can't be lost
    // no matter how fast the download outruns playback.
    @Test func streamBackpressureSwallowsCompletion() async throws {
        guard await audioOutputAvailable.value else { return }
        let fixtureData = try Data(contentsOf: Fixtures.streamADTS) // 21s > high water
        let server = try TestHTTPServer(serving: fixtureData)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("stream-c2.part")
        try? FileManager.default.removeItem(at: partURL)
        let serverURL = server.url

        let result = await withWatchdog("backpressure", timeout: 40) { () -> Bool in
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stop() }
            engine.outputVolume = 0
            engine.startStreaming(from: serverURL, formatHint: "aac", writingTo: partURL)
            engine.play(from: 0)
            // With a correct engine the low-water resume (~15s in) releases
            // the transfer and completion arrives shortly after; 30s is ample.
            return log.wait(timeout: 30) {
                if case .streamDownloadCompleted = $0 { return true }
                return false
            }
        }
        guard let downloadDone = result else { return }
        #expect(downloadDone, ".streamDownloadCompleted should arrive even when the download outruns playback past the high-water mark")
    }

    // (e) Gapless transition A → B: midpoint + completed events, then B's
    @Test func seekDoesNotLeakTheOldPosition() async throws {
        guard await audioOutputAvailable.value else { return }

        struct Sample { var t: TimeInterval; var peak: Float }
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var samples: [Sample] = []
            let start = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            func record(_ peak: Float, at time: TimeInterval) {
                lock.lock(); defer { lock.unlock() }
                samples.append(Sample(t: time - start, peak: peak))
            }
            func snapshot() -> [Sample] {
                lock.lock(); defer { lock.unlock() }
                return samples
            }
        }

        // Mono → chunk-converted (buffer-fed) source, where the residue is
        // biggest; stereo → the sample-accurate scheduleSegment path.
        for (name, fixture) in [("converted", Fixtures.loudThenSilentCAF),
                                ("stereo-file", Fixtures.loudThenSilentStereoCAF)] {
            let result = await withWatchdog("seekResidue-\(name)", timeout: 40) {
                () -> ([Sample], TimeInterval, TimeInterval, Float) in
                let engine = PlaybackEngine()
                _ = EventLog(engine)
                defer { engine.setTimedOutputMonitor(nil); engine.stop() }
                guard (try? engine.loadFile(at: fixture)) != nil else { return ([], -1, -1, -1) }
                engine.outputVolume = 0
                let recorder = Recorder()
                engine.setTimedOutputMonitor { recorder.record($0, at: $1) }
                engine.play(from: 0)
                // Sounding at full level well inside the loud half.
                _ = pollPosition(engine, past: 1.0, timeout: 5)

                let seekAt = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - recorder.start
                engine.seek(to: 5.0)
                Thread.sleep(forTimeInterval: 1.2)
                // The fader has to come back on its own, or "no leak" would be
                // trivially satisfied by a deck that never sounds again.
                let volume = engine.sourceVolume
                let position = engine.position
                return (recorder.snapshot(), seekAt, position, volume)
            }
            guard let (samples, seekAt, position, volume) = result, !samples.isEmpty else {
                Issue.record("\(name): no audio was captured from deck A")
                continue
            }

            let nominal = samples.filter { $0.t < seekAt }.map(\.peak).max() ?? 0
            #expect(nominal > 0.05, "\(name): deck A should be sounding before the seek (peak \(nominal))")

            // One render buffer of grace: the seek is an async hop onto the
            // engine queue and the mixer smooths a gain change over a few ms.
            let after = samples.filter { $0.t > seekAt + 0.05 }
            let worst = after.max { $0.peak < $1.peak }
            let window = samples.filter { $0.t > seekAt - 0.3 && $0.t < seekAt + 0.8 }
            let timeline = stride(from: 0, to: window.count, by: max(window.count / 30, 1))
                .map { String(format: "%+.2f:%.3f", window[$0].t - seekAt, window[$0].peak) }
                .joined(separator: " ")
            print("seekResidue[\(name)]: nominal=\(nominal) worstAfter=\(worst?.peak ?? 0) " +
                  "at +\((worst?.t ?? 0) - seekAt)s | \(timeline)")
            let leakDetail = "\(name): after seeking from the loud half to the silent half the deck " +
                "still put out \(worst?.peak ?? 0) (nominal \(nominal)) at " +
                "+\((worst?.t ?? 0) - seekAt)s — that is the pre-seek position draining out of the chain"
            #expect((worst?.peak ?? 0) <= nominal * 0.1, "\(leakDetail)")
            #expect(abs(volume - 1) < 0.001,
                    "\(name): the fader must be handed back after the flush window (got \(volume))")
            #expect(position > 5.5, "\(name): playback must continue from the seek target (got \(position))")
        }
    }

    // (k2) **A hardware configuration change must not end playback — least of
    // all on a chunk-converted deck.**
    //
    // A device disappearing (a monitor sleeping, headphones unplugged, an
    // AirPlay endpoint walking out of range) stops the engine and wipes every
    // player node's schedule. The rebuild has to put the graph back and resume
    // each deck from its cached position, and a `.convertedFile` deck is the
    // hard one: its feeder is mid-chunk on its own queue, and the chunks it has
    // already handed to the engine queue belong to a node that no longer
    // exists. Delivering one of those into the rebuilt graph would schedule
    // audio from before the change on top of the resume.
    //
    // Both source paths are run, because the same rebuild covers both.
    @Test func aConfigurationChangeResumesEveryDeckInsteadOfEndingIt() async throws {
        guard await audioOutputAvailable.value else { return }
        for (name, fixture) in [("converted", Fixtures.eightSecondCAF),
                                ("stereo-file", Fixtures.eightSecondStereoCAF)] {
            let result = await withWatchdog("configChange-\(name)", timeout: 30) {
                () -> (TimeInterval, TimeInterval, Float, Bool) in
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stop() }
                guard (try? engine.loadFile(at: fixture)) != nil else {
                    return (-1, -1, -1, false)
                }
                engine.outputVolume = 0
                engine.play(from: 0)
                let before = pollPosition(engine, past: 1.0, timeout: 5)

                engine.simulateConfigurationChange()
                Thread.sleep(forTimeInterval: 0.3)
                // Playback has to *advance* from where it was, not restart and
                // not stall: the resume is from the cached position.
                let after = pollPosition(engine, past: before + 0.8, timeout: 5)
                let volume = engine.sourceVolume
                // And the track still ends by itself, which is the assertion
                // that the rebuilt schedule is a whole schedule.
                let finished = log.wait(timeout: 15) {
                    if case .finished = $0 { return true }
                    return false
                }
                return (before, after, volume, finished)
            }
            guard let (before, after, volume, finished) = result, before > 0 else { continue }
            #expect(after > before + 0.8,
                    "\(name): the deck must resume past \(before)s after the rebuild (got \(after))")
            #expect(after < before + 6,
                    "\(name): the deck restarted somewhere else entirely (\(before)s → \(after)s)")
            #expect(abs(volume - 1) < 0.001,
                    "\(name): the fader must be handed back after the rebuild (got \(volume))")
            #expect(finished,
                    "\(name): the rebuilt schedule must still reach the end of the file")
        }
    }

}
