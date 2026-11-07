import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import KumoneCore

@Suite("Remote audio random access", .serialized)
struct RemoteAudioLoaderTests {
    private static let directory: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = root.appendingPathComponent(".tmp/RemoteAudioLoaderTests")
        try! FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }()
    private func fixture(rate: Double, seconds: Int, container: String) throws -> URL {
        let name = "noise-\(Int(rate))-\(seconds)"
        let caf = Self.directory.appendingPathComponent(name + ".caf")
        if !FileManager.default.fileExists(atPath: caf.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let file = try AVAudioFile(forWriting: caf, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            var frame = 0
            let total = Int(rate) * seconds
            while frame < total {
                let count = min(4096, total - frame)
                buffer.frameLength = UInt32(count)
                for i in 0..<count {
                    // Stateless noise survives lossless compression poorly,
                    // making first-PCM network ratios meaningful.
                    var value = UInt32(truncatingIfNeeded: frame + i) &* 747796405 &+ 2891336453
                    value = ((value >> ((value >> 28) + 4)) ^ value) &* 277803737
                    let noise = Float(value >> 8) / Float(0x00ff_ffff) - 0.5
                    let amplitude: Float = ((frame + i) / Int(rate * 2)) % 3 == 0 ? 0.01 : 0.5
                    buffer.floatChannelData![0][i] = noise * amplitude
                    buffer.floatChannelData![1][i] = noise * amplitude * 0.8
                }
                try file.write(from: buffer)
                frame += count
            }
        }
        let destination = Self.directory.appendingPathComponent(name + "." + container)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let process = Process()
            if container == "mp3" || container == "cbr.mp3" {
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
                process.arguments = ["-hide_banner", "-loglevel", "error", "-i", caf.path, "-codec:a", "libmp3lame"] + (container == "mp3" ? ["-q:a", "2"] : ["-b:a", "256k"]) + [destination.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                process.arguments = ["-f", container == "flac" ? "flac" : "m4af", "-d", container == "flac" ? "flac" : "aac", caf.path, destination.path]
            }
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        return destination
    }
    private final class ResultBox: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var error: Error?
        var bytes: Int64 = 0
        var frames: Int64 = 0
        var formats: [Double] = []
        var completed = false
    }
    private func reference(_ url: URL, at seconds: Double, frames: UInt32 = 2048) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = Int64((seconds * file.processingFormat.sampleRate).rounded(.down))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        return buffer
    }
    @Test(arguments: [96_000.0, 192_000.0])
    func flacWithoutSeekTableStartsAtAnExactMiddleSampleUsingFewRanges(rate: Double) throws {
        let url = try fixture(rate: rate, seconds: 24, container: "flac")
        let payload = try Data(contentsOf: url)
        var metadataOffset = 4
        while metadataOffset < payload.count {
            #expect(payload[metadataOffset] & 0x7f != 3, "This fixture must exercise a FLAC with no seek table")
            let last = payload[metadataOffset] & 0x80 != 0
            metadataOffset += 4 + Int(remoteBigEndian(payload, at: metadataOffset + 1, count: 3))
            if last { break }
        }
        let server = try TestHTTPServer(serving: payload)
        defer { server.stop() }
        let queue = DispatchQueue(label: "remote-audio.test.flac")
        let target = 12.12345
        let loader = RemoteAudioLoader(remoteURL: server.url, formatHint: "flac",
            output: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!, queue: queue,
            preserveSampleRate: true, initialPosition: target)
        let result = ResultBox()
        let first = DispatchSemaphore(value: 0)
        loader.onFormat = { result.formats.append($0.sampleRate) }
        loader.onBuffer = { buffer in
            loader.setDownloadSuspended(true)
            result.buffer = buffer; result.bytes = loader.receivedByteCount; first.signal()
        }
        loader.onError = { result.error = $0; first.signal() }
        loader.start()
        defer { loader.cancel() }
        #expect(first.wait(timeout: .now() + 30) == .success)
        queue.sync {}
        let buffer = try #require(result.buffer, "\(String(describing: result.error))")
        #expect(result.formats == [rate])
        #expect(Double(result.bytes) < Double(payload.count) * 0.25)
        let local = try reference(url, at: target)
        var difference: Float = 0
        for i in 0..<Int(local.frameLength) {
            difference = max(difference, abs(buffer.floatChannelData![0][i] - local.floatChannelData![0][i]))
        }
        print("Remote FLAC \(Int(rate)) firstPCM=\(result.bytes)/\(payload.count), maxSampleError=\(difference)")
        #expect(difference < 0.000001)
        // A seek must clear prior PCM backpressure and use a fresh generation.
        result.buffer = nil
        loader.seek(to: 20.017)
        #expect(first.wait(timeout: .now() + 15) == .success)
        queue.sync {}
        let second = try #require(result.buffer, "\(String(describing: result.error))")
        let secondReference = try reference(url, at: 20.017)
        #expect(abs(second.floatChannelData![0][0] - secondReference.floatChannelData![0][0]) < 0.000001)
    }
    @Test func m4aWithTailMetadataSeeksWithoutFetchingItsAudioPrefix() throws {
        let original = try fixture(rate: 48_000, seconds: 90, container: "m4a")
        var payload = try Data(contentsOf: original)
        // Preserve mdat's absolute chunk offsets by retaining the original
        // moov atom's footprint as free space and appending moov at the tail.
        var position = 0
        while position + 8 <= payload.count {
            let size = Int(remoteBigEndian(payload, at: position, count: 4))
            guard size >= 8, position + size <= payload.count else { throw CocoaError(.fileReadCorruptFile) }
            if payload[position + 4..<position + 8] == Data("moov".utf8) {
                let atom = payload.subdata(in: position..<(position + size))
                payload.replaceSubrange(position + 4..<position + 8, with: Data("free".utf8))
                payload.append(atom)
                break
            }
            position += size
        }
        let url = Self.directory.appendingPathComponent("tail-moov.m4a")
        try payload.write(to: url)
        let mdat = try #require(payload.range(of: Data("mdat".utf8)))
        let moov = try #require(payload.range(of: Data("moov".utf8)))
        #expect(moov.lowerBound > mdat.lowerBound)
        let server = try TestHTTPServer(serving: payload)
        defer { server.stop() }
        let queue = DispatchQueue(label: "remote-audio.test.m4a")
        let loader = RemoteAudioLoader(remoteURL: server.url, formatHint: "mp3",
            output: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, queue: queue, initialPosition: 45.123)
        let result = ResultBox(); let first = DispatchSemaphore(value: 0)
        loader.onBuffer = { result.buffer = $0; result.bytes = loader.receivedByteCount; loader.setDownloadSuspended(true); first.signal() }
        loader.onError = { result.error = $0; first.signal() }
        loader.start(); defer { loader.cancel() }
        #expect(first.wait(timeout: .now() + 30) == .success)
        queue.sync {}
        let buffer = try #require(result.buffer, "\(String(describing: result.error))")
        #expect(result.bytes < Int64(Double(payload.count) * 0.25))
        let local = try reference(url, at: 45.123)
        var error: Float = 0
        for i in 0..<Int(local.frameLength) { error = max(error, abs(local.floatChannelData![0][i] - buffer.floatChannelData![0][i])) }
        print("Remote M4A firstPCM=\(result.bytes)/\(payload.count), maxSampleError=\(error)")
        #expect(error < 0.00001)
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg"), "ffmpeg is used only to generate the MP3 fixtures"), arguments: ["mp3", "cbr.mp3"])
    func mp3SeeksWithoutPrefixScanAndWarmsTheBitReservoir(container: String) throws {
        let url = try fixture(rate: 48_000, seconds: 90, container: container)
        let payload = try Data(contentsOf: url)
        #expect(payload.range(of: Data((container == "mp3" ? "Xing" : "Info").utf8)) != nil)
        let server = try TestHTTPServer(serving: payload)
        defer { server.stop() }
        let queue = DispatchQueue(label: "remote-audio.test.mp3")
        let loader = RemoteAudioLoader(remoteURL: server.url, formatHint: "mp3",
            output: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, queue: queue, initialPosition: 45.123)
        let result = ResultBox(); let first = DispatchSemaphore(value: 0)
        loader.onBuffer = { result.buffer = $0; result.bytes = loader.receivedByteCount; loader.setDownloadSuspended(true); first.signal() }
        loader.onError = { result.error = $0; first.signal() }
        loader.start(); defer { loader.cancel() }
        #expect(first.wait(timeout: .now() + 30) == .success)
        queue.sync {}
        let buffer = try #require(result.buffer, "\(String(describing: result.error))")
        #expect(result.bytes < Int64(Double(payload.count) * 0.25))
        // Xing is an approximate byte table. Locate the delivered waveform in
        // a one-second local window and quantify the actual timeline error.
        let local = try reference(url, at: 44.623, frames: 48_000)
        let actual = buffer.floatChannelData![0]
        let expected = local.floatChannelData![0]
        var best: Float = .greatestFiniteMagnitude
        var bestOffset = 0
        for offset in 0..<(Int(local.frameLength) - 64) {
            var error: Float = 0
            for i in 0..<64 { error += abs(actual[i] - expected[offset + i]) }
            if error < best { best = error; bestOffset = offset }
        }
        let timingError = Double(bestOffset) / 48_000 - 0.5
        print("Remote \(container) firstPCM=\(result.bytes)/\(payload.count), timelineError=\(timingError)s, sampleMAE=\(best / 64)")
        #expect(abs(timingError) < (container == "mp3" ? 0.4 : 1.0 / 48_000))
        #expect(best / 64 < 0.001)
    }
    @Test func flacTailHasTheExactRemainingFramesAndOutOfBoundsSeekCompletes() throws {
        let url = try fixture(rate: 96_000, seconds: 24, container: "flac")
        let server = try TestHTTPServer(serving: Data(contentsOf: url)); defer { server.stop() }
        let queue = DispatchQueue(label: "remote-audio.test.eof")
        let loader = RemoteAudioLoader(remoteURL: server.url, formatHint: "flac",
            output: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!, queue: queue,
            preserveSampleRate: true, initialPosition: 23.125)
        let box = ResultBox(); let done = DispatchSemaphore(value: 0)
        loader.onBuffer = { box.frames += Int64($0.frameLength) }
        loader.onCompleted = { box.completed = true; done.signal() }
        loader.onError = { box.error = $0; done.signal() }
        loader.start(); defer { loader.cancel() }
        #expect(done.wait(timeout: .now() + 30) == .success)
        queue.sync {}
        #expect(box.error == nil)
        #expect(box.completed)
        #expect(box.frames == 84_000)
        box.completed = false; box.frames = 0
        loader.seek(to: 999)
        #expect(done.wait(timeout: .now() + 10) == .success)
        queue.sync {}
        #expect(box.completed)
        #expect(box.frames == 0)
    }
}
