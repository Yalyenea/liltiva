import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

@Suite("Remote range playback engine", .serialized)
struct RemotePlaybackEngineTests {
    private final class Energy: @unchecked Sendable {
        private let lock = NSLock()
        private var sum = 0.0
        private var count = 0

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let samples = buffer.floatChannelData else { return }
            lock.lock()
            defer { lock.unlock() }
            for frame in 0..<Int(buffer.frameLength) {
                let value = Double(samples[0][frame])
                sum += value * value
            }
            count += Int(buffer.frameLength)
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            sum = 0
            count = 0
        }

        var rms: Double {
            lock.lock()
            defer { lock.unlock() }
            return sqrt(sum / Double(max(1, count)))
        }
    }

    @MainActor private func wait(seconds: Double = 10, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        return predicate()
    }

    private func fixture(in root: URL, rate: Double = 96_000, seconds: Double = 30) throws -> URL {
        let caf = root.appendingPathComponent("source.caf")
        let flac = root.appendingPathComponent("source.flac")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: caf, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var offset = 0
        while offset < Int(rate * seconds) {
            let frames = min(4096, Int(rate * seconds) - offset)
            for channel in 0..<2 {
                for frame in 0..<frames {
                    // The distant seek target is silent, so any old PCM or
                    // effect history leaking past the seek is observable.
                    buffer.floatChannelData![channel][frame] = offset + frame < Int(rate * 18)
                        ? 0.2 * sinf(2 * .pi * 440 * Float(offset + frame) / Float(rate)) : 0
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            offset += frames
        }
        let conversion = Process()
        conversion.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        conversion.arguments = ["-f", "flac", "-d", "flac", caf.path, flac.path]
        try conversion.run()
        conversion.waitUntilExit()
        try #require(conversion.terminationStatus == 0)
        return flac
    }

    @Test @MainActor func initialPlaySurvivesLate192kHzFormatDiscoveryAndFinishes() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/remote-engine-format-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let flac = try fixture(in: root, rate: 192_000, seconds: 3)
        let server = try TestHTTPServer(serving: Data(contentsOf: flac))
        defer { server.stop() }
        let engine = PlaybackEngine()
        var deliveries: [PlaybackEngineEventDelivery] = []
        let consumer = Task { @MainActor in
            for await delivery in engine.eventDeliveries { deliveries.append(delivery) }
        }
        defer { consumer.cancel(); engine.stop() }
        engine.outputVolume = 0
        engine.startRemote(from: server.url, formatHint: "flac", at: 1, preserveSampleRate: true)
        engine.play(from: 1)
        #expect(try await wait { engine.position > 1.3 })
        #expect(engine.processingSampleRate == 192_000)
        #expect(try await wait {
            deliveries.contains { if case .finished = $0.event { return true }; return false }
        })
        #expect(abs(engine.position - 3) < 0.05)
        #expect(!deliveries.contains { if case .streamFailed = $0.event { return true }; return false })
    }

    @Test @MainActor func initialNetworkWaitKeepsTheRequestedPosition() async throws {
        let fixture = try OfflineAudioFixture(.mp3)
        try #require(fixture.data.count > 16_384)
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.5)
        defer { server.stop() }
        let engine = PlaybackEngine()
        defer { engine.stop() }
        engine.outputVolume = 0
        engine.startRemote(from: server.url, formatHint: "mp3", at: 1)
        engine.play(from: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.scheduledBufferCount == 0)
        #expect(engine.position == 1, "the empty player clock must not advance during a cold HTTP wait")
    }

    @Test @MainActor func coldHiResSourceKeepsEQAndResumesAfterAPausedSeek() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/remote-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try TestHTTPServer(serving: Data(contentsOf: fixture(in: root)))
        defer { server.stop() }
        let engine = PlaybackEngine()
        let energy = Energy()
        var deliveries: [PlaybackEngineEventDelivery] = []
        let consumer = Task { @MainActor in
            for await delivery in engine.eventDeliveries {
                deliveries.append(delivery)
                if case .streamFailed(let error) = delivery.event { print("Remote engine source failure: \(error)") }
            }
        }
        defer {
            consumer.cancel()
            engine.setOutputSampleSink(nil)
            engine.stop()
        }
        engine.outputVolume = 0.01
        engine.setOutputSampleSink { energy.append($0) }
        engine.startRemote(from: server.url, formatHint: "flac", at: 4, preserveSampleRate: true)
        #expect(engine.position == 4)
        #expect(try await wait { engine.scheduledBufferCount == 40 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.scheduledBufferCount == 40, "paused remote PCM must stay bounded")
        #expect(engine.processingSampleRate == 96_000)
        let loaderID = try #require(engine.activeRemoteLoaderID)
        engine.play(from: 4)
        #expect(try await wait { engine.position > 4.4 })
        energy.reset()
        #expect(try await wait { engine.position > 4.9 })
        let dry = energy.rms
        engine.setSoundEffect(AISoundEffect(aev2: .init(eq: .init(on: true,
            eqs: Array(repeating: -12, count: 10))), effectStyle: nil))
        #expect(try await wait { engine.position > 5.4 })
        energy.reset()
        #expect(try await wait { engine.position > 5.9 })
        #expect(dry > 0.0001)
        #expect(energy.rms < dry * 0.5, "range-backed high-resolution audio must pass through live EQ")
        engine.pause()
        let paused = engine.position
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(engine.position - paused) < 0.01)
        let oldEvent = try #require(deliveries.first)
        engine.seek(to: 20)
        #expect(engine.position == 20)
        #expect(!engine.isCurrent(oldEvent))
        #expect(engine.activeRemoteLoaderID == loaderID, "seek must reuse the bounded range cache")
        #expect(try await wait { engine.scheduledBufferCount > 0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.position == 20, "a paused seek must not start playback")
        engine.resume()
        #expect(try await wait { engine.position > 20.3 })
        energy.reset()
        #expect(try await wait { engine.position > 20.8 })
        #expect(energy.rms < 0.000001, "seek must discard old PCM and effect history")
        #expect(engine.processingSampleRate == 96_000)
        #expect(!deliveries.contains { if case .streamFailed = $0.event { return true }; return false })
    }
}
