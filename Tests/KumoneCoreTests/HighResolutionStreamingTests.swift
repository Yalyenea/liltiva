import AVFoundation
import Foundation
import Testing
import Darwin
@testable import KumoneCore

/// A cold network source whose tail is withheld until the test has heard from
/// the decoder. Fast localhost transfers alone cannot prove progressive startup.
private final class GatedAudioServer: @unchecked Sendable {
    private let socketFD: Int32
    private let tail = DispatchSemaphore(value: 0)
    let url: URL

    init(data: Data) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &size) }
        }
        socketFD = fd
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/cold.flac")!
        let gate = tail
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var request = [UInt8](repeating: 0, count: 8192)
            guard read(client, &request, request.count) > 0 else { return }
            func send(_ bytes: Data) {
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { return }
                        offset += n
                    }
                }
            }
            send(Data("HTTP/1.1 200 OK\r\nContent-Type: audio/flac\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8))
            let split = min(data.count / 2, 262_144)
            send(data.prefix(split))
            _ = gate.wait(timeout: .now() + 15)
            send(data.dropFirst(split))
        }
    }
    func releaseTail() { tail.signal() }
    func stop() { tail.signal(); shutdown(socketFD, SHUT_RDWR); close(socketFD) }
}

@Suite("High-resolution progressive startup", .serialized)
struct HighResolutionStreamingTests {
    @Test(arguments: [96_000.0, 192_000.0])
    func decodesOriginalRateBeforeDownloadCompletes(rate: Double) throws {
        // Several frequencies retain enough encoded data that withholding the
        // second half really separates first audio from download completion.
        let caf = try Fixtures.writeCAF(seconds: 8, sampleRate: rate, channels: 2,
                                        name: "progressive-hires-\(Int(rate))") { frame in
            Float(sin(Double(frame) * 0.047) * 0.25 + sin(Double(frame) * 0.113) * 0.1)
        }
        let flac = try ProgressiveLoaderFLACTests.flacFixture(from: caf, name: "progressive-hires-\(Int(rate))")
        let payload = try Data(contentsOf: flac)
        let server = try GatedAudioServer(data: payload)
        defer { server.stop() }
        let queue = DispatchQueue(label: "hires-stream-test")
        let loader = ProgressiveLoader(remoteURL: server.url, formatHint: "flac",
            partURL: Fixtures.dir.appendingPathComponent("hires-\(Int(rate)).part"),
            output: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!,
            queue: queue, preserveSampleRate: true)
        final class Result: @unchecked Sendable {
            var rate: Double = 0
            var frames: Int64 = 0
            var mirrored = false
            var error: Error?
            var formatArrived = false
            var bufferBeforeFormat = false
        }
        let result = Result()
        let first = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        loader.onFormat = { format in result.rate = format.sampleRate; result.formatArrived = true }
        loader.onBuffer = { buffer in
            if !result.formatArrived { result.bufferBeforeFormat = true }
            if result.frames == 0 { first.signal() }
            result.frames += Int64(buffer.frameLength)
        }
        loader.onMirrorCompleted = { _ in result.mirrored = true }
        loader.onError = { error in result.error = error; first.signal(); completed.signal() }
        loader.onCompleted = { completed.signal() }
        loader.start()
        defer { loader.cancel() }
        #expect(first.wait(timeout: .now() + 10) == .success)
        queue.sync {
            #expect(result.error == nil)
            #expect(result.frames > 0)
            #expect(result.rate == rate)
            #expect(!result.bufferBeforeFormat)
            #expect(!result.mirrored, "first audio must not wait for the complete file")
        }
        server.releaseTail()
        #expect(completed.wait(timeout: .now() + 10) == .success)
        queue.sync {
            #expect(result.error == nil)
            #expect(result.mirrored)
            #expect(result.frames == Int64(rate * 8))
        }
    }
}
