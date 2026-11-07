import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

@Suite("Prepared audio streams", .serialized)
struct PreparedStreamTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/prepared-stream-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAudio(in root: URL, rate: Double, seconds: Double = 4, silent: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("source-\(Int(rate)).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var offset = 0
        while offset < Int(seconds * rate) {
            let count = min(4096, Int(seconds * rate) - offset)
            for channel in 0..<2 {
                for frame in 0..<count {
                    buffer.floatChannelData![channel][frame] = silent ? 0
                        : 0.2 * sinf(2 * .pi * 440 * Float(offset + frame) / Float(rate))
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
        return url
    }

    private func makeFLAC(in root: URL, rate: Double, seconds: Double = 4, silent: Bool = false) throws -> URL {
        let caf = try makeAudio(in: root, rate: rate, seconds: seconds, silent: silent)
        let output = root.appendingPathComponent("stream.flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", caf.path, output.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return output
    }

    @MainActor private func wait(seconds: Double = 10, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    @Test @MainActor func preparedHiResStreamPromotesTheSameLoaderWithoutTouchingThePlayingGraph() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let flac = try makeFLAC(in: root, rate: 96_000)
        let server = try TestHTTPServer(serving: Data(contentsOf: flac))
        defer { server.stop() }
        let engine = PlaybackEngine()
        engine.outputVolume = 0
        var deliveries: [PlaybackEngineEventDelivery] = []
        let consumer = Task { @MainActor in
            for await delivery in engine.eventDeliveries { deliveries.append(delivery) }
        }
        defer { consumer.cancel(); engine.stop(); engine.cancelPreparedStream() }
        _ = try engine.loadFile(at: makeAudio(in: root, rate: 44_100, seconds: 8))
        engine.play(from: 0)
        #expect(try await wait { engine.position > 0.15 })
        let before = engine.position
        let part = root.appendingPathComponent("prepared.part")
        engine.prepareStream(from: server.url, formatHint: "flac", writingTo: part, preserveSampleRate: true)
        #expect(try await wait { engine.preparedStreamBufferCount > 0 })
        let preparedID = try #require(engine.preparedStreamLoaderID)
        print("prepared Hi-Res PCM buffers: \(engine.preparedStreamBufferCount)")
        #expect(engine.preparedStreamBufferCount <= 4)
        #expect(engine.processingSampleRate == 44_100)
        #expect(try await wait { engine.position > before + 0.15 })
        #expect(try await wait {
            deliveries.contains {
                if case .preparedStreamDownloadCompleted(let remote, let path) = $0.event {
                    return remote == server.url && path == part
                }
                return false
            }
        })
        let completed = root.appendingPathComponent("committed.flac")
        try FileManager.default.moveItem(at: part, to: completed)
        try FileManager.default.removeItem(at: completed)
        // A normal source stop precedes queue transitions in PlayerService.
        // It must preserve the prepared loader and its open mirror reader.
        engine.stop()
        #expect(engine.preparedStreamLoaderID == preparedID)
        engine.startStreaming(from: server.url, formatHint: "flac", writingTo: part, preserveSampleRate: true)
        #expect(engine.activeStreamLoaderID == preparedID)
        #expect(engine.preparedStreamLoaderID == nil)
        #expect(engine.processingSampleRate == 96_000)
        deliveries.removeAll()
        final class Energy: @unchecked Sendable {
            private let lock = NSLock()
            private var sum = 0.0
            private var count = 0
            func append(_ buffer: AVAudioPCMBuffer) {
                guard let samples = buffer.floatChannelData else { return }
                lock.lock(); defer { lock.unlock() }
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(samples[0][frame])
                    sum += value * value
                }
                count += Int(buffer.frameLength)
            }
            func reset() { lock.lock(); defer { lock.unlock() }; sum = 0; count = 0 }
            var rms: Double { lock.lock(); defer { lock.unlock() }; return sqrt(sum / Double(max(1, count))) }
        }
        let capture = Energy()
        engine.outputVolume = 0.01
        engine.setOutputSampleSink { capture.append($0) }
        defer { engine.setOutputSampleSink(nil) }
        engine.play(from: 0)
        #expect(try await wait { engine.position > 0.3 })
        capture.reset()
        #expect(try await wait { engine.position > 0.9 })
        let dry = capture.rms
        engine.setSoundEffect(AISoundEffect(aev2: .init(eq: .init(on: true,
            eqs: Array(repeating: -12, count: 10))), effectStyle: nil))
        #expect(try await wait { engine.position > 1.5 })
        capture.reset()
        #expect(try await wait { engine.position > 2.1 })
        #expect(dry > 0.0001)
        #expect(capture.rms < dry * 0.5, "the promoted high-resolution stream must pass through the live EQ")
        #expect(engine.processingSampleRate == 96_000)
        #expect(try await wait(seconds: 8) {
            deliveries.contains { if case .finished = $0.event { return true }; return false }
        })
        #expect(!deliveries.contains { if case .streamFailed = $0.event { return true }; return false })
    }

    @Test @MainActor func preparationUsesOneRequestAndQualityChangesReplaceIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try OfflineAudioFixture(.mp3)
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop() }
        let engine = PlaybackEngine()
        defer { engine.stop(); engine.cancelPreparedStream() }
        let part = root.appendingPathComponent("prepared.part")
        engine.prepareStream(from: server.url, formatHint: "mp3", writingTo: part)
        #expect(try await wait { engine.preparedStreamBufferCount > 0 })
        let preparedID = try #require(engine.preparedStreamLoaderID)
        engine.prepareStream(from: server.url, formatHint: "MP3", writingTo: part)
        #expect(engine.preparedStreamLoaderID == preparedID)
        engine.startStreaming(from: server.url, formatHint: "mp3", writingTo: part)
        #expect(engine.activeStreamLoaderID == preparedID)
        #expect(server.ranges.count == 1)
        engine.stop()
        engine.prepareStream(from: server.url, formatHint: "mp3", writingTo: root.appendingPathComponent("different.part"))
        let replacementID = try #require(engine.preparedStreamLoaderID)
        #expect(replacementID != preparedID)
        engine.startStreaming(from: server.url, formatHint: "mp3", writingTo: root.appendingPathComponent("hires.part"),
                              preserveSampleRate: true)
        #expect(engine.activeStreamLoaderID != replacementID)
        #expect(engine.preparedStreamLoaderID == nil)
    }

    @Test @MainActor func replacingASourceInvalidatesAlreadyQueuedEvents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try OfflineAudioFixture(.mp3)
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop() }
        let engine = PlaybackEngine()
        var deliveries: [PlaybackEngineEventDelivery] = []
        let consumer = Task { @MainActor in
            for await delivery in engine.eventDeliveries { deliveries.append(delivery) }
        }
        defer { consumer.cancel(); engine.stop(); engine.cancelPreparedStream() }
        engine.startStreaming(from: server.url, formatHint: "mp3", writingTo: root.appendingPathComponent("active.part"))
        #expect(try await wait { !deliveries.isEmpty })
        let old = try #require(deliveries.first)
        #expect(engine.isCurrent(old))
        engine.stop()
        #expect(!engine.isCurrent(old))
        engine.prepareStream(from: server.url, formatHint: "mp3", writingTo: root.appendingPathComponent("next.part"))
        #expect(try await wait { engine.preparedStreamBufferCount > 0 })
        engine.cancelPreparedStream()
        #expect(engine.preparedStreamLoaderID == nil)
        #expect(engine.activeStreamLoaderID == nil)
    }

    @Test @MainActor func highlyCompressedFLACKeepsPreparedPCMAtFourBuffersWhileTheMirrorCompletes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let flac = try makeFLAC(in: root, rate: 96_000, seconds: 30, silent: true)
        let payload = try Data(contentsOf: flac)
        #expect(payload.count < 32_768, "the fixture must fit many seconds into one parser read")
        let server = try TestHTTPServer(serving: payload)
        defer { server.stop() }
        let engine = PlaybackEngine()
        var mirrored = false
        let consumer = Task { @MainActor in
            for await event in engine.events {
                if case .preparedStreamDownloadCompleted = event { mirrored = true }
            }
        }
        defer { consumer.cancel(); engine.stop(); engine.cancelPreparedStream() }
        let part = root.appendingPathComponent("compressed.part")
        engine.prepareStream(from: server.url, formatHint: "flac", writingTo: part, preserveSampleRate: true)
        #expect(try await wait { mirrored && engine.preparedStreamBufferCount == 4 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.preparedStreamBufferCount == 4)
        #expect(try Data(contentsOf: part) == payload)
        engine.cancelPreparedStream()
        #expect(engine.preparedStreamBufferCount == 0)
        #expect(engine.preparedStreamLoaderID == nil)
    }

    @Test func seekingDiscardsAPausedConvertersRetainedInput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try OfflineAudioFixture(.mp3)
        let server = try TestHTTPServer(serving: fixture.data)
        defer { server.stop() }
        let queue = DispatchQueue(label: "prepared-stream-seek-test")
        let loader = ProgressiveLoader(remoteURL: server.url, formatHint: "mp3",
            partURL: root.appendingPathComponent("seek.part"),
            output: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!, queue: queue)
        final class State: @unchecked Sendable {
            var seeking = false
            var afterSeekFrames = 0
            var error: Error?
        }
        let state = State()
        let paused = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        loader.onBuffer = { [weak loader] buffer in
            if state.seeking { state.afterSeekFrames += Int(buffer.frameLength) }
            else { loader?.setDownloadSuspended(true); paused.signal() }
        }
        loader.onError = { state.error = $0; paused.signal(); completed.signal() }
        loader.onCompleted = { completed.signal() }
        loader.start()
        defer { loader.cancel() }
        #expect(paused.wait(timeout: .now() + 10) == .success)
        #expect(loader.canSeek)
        queue.sync { state.seeking = true }
        loader.seek(to: 1)
        #expect(completed.wait(timeout: .now() + 10) == .success)
        queue.sync {
            #expect(state.error == nil)
            #expect(state.afterSeekFrames > 0)
        }
    }

    @Test @MainActor func cancellingAnIncompletePreparedStreamDeletesItsPartialMirror() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try OfflineAudioFixture(.mp3)
        #expect(fixture.data.count > 16_384)
        let server = try await AudioFixtureServer(fixture: fixture, delay: 2)
        defer { server.stop() }
        let engine = PlaybackEngine()
        defer { engine.stop(); engine.cancelPreparedStream() }
        let part = root.appendingPathComponent("cancelled.part")
        engine.prepareStream(from: server.url, formatHint: "mp3", writingTo: part)
        #expect(try await wait { engine.preparedStreamBufferCount > 0 })
        #expect(try Data(contentsOf: part).count < fixture.data.count)
        engine.cancelPreparedStream()
        #expect(try await wait { !FileManager.default.fileExists(atPath: part.path) })
        #expect(engine.preparedStreamLoaderID == nil)
    }
}
