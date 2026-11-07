import Foundation
import Testing
import Darwin
@testable import KumoneCore

private final class RangeFaultServer: @unchecked Sendable {
    let url: URL
    let requested = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let fd: Int32
    init(header: String?) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let socketFD = fd
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socketFD, $0, &length) }
        }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/audio")!
        let requested = requested
        let release = release
        DispatchQueue.global().async {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            guard read(client, &buffer, buffer.count) > 0 else { return }
            requested.signal()
            if let header {
                // Supply a small prefix so CFNetwork can surface its response even
                // on platforms that probe content before the delegate callback.
                // The large advertised remainder never arrives.
                (Data(header.utf8) + Data(repeating: 0, count: 1024)).withUnsafeBytes {
                    raw in _ = write(client, raw.baseAddress!, raw.count)
                }
            }
            // The rest of the response body deliberately never arrives. Rejection and cancel
            // must wake the reader without relying on transfer completion.
            _ = release.wait(timeout: .now() + 5)
        }
    }
    func stop() { release.signal(); shutdown(fd, SHUT_RDWR); close(fd) }
}

@Suite("Remote audio HTTP range boundaries", .serialized)
struct RemoteAudioRangeReaderTests {
    @Test func rejectsIgnoredRangeWithoutDownloadingTheAdvertisedBody() throws {
        let server = try RangeFaultServer(header: "HTTP/1.1 200 OK\r\nContent-Type: audio/flac\r\nContent-Length: 99999999\r\n\r\n")
        defer { server.stop() }
        let reader = RemoteAudioRangeReader(url: server.url)
        let started = Date()
        do {
            try reader.prepare(generation: reader.advance())
            Issue.record("A server ignoring Range must be rejected")
        } catch {
            #expect(Date().timeIntervalSince(started) < 2)
            #expect(reader.receivedByteCount == 0)
        }
    }

    @Test func rejectsWrongRangeWithoutWaitingForTheRemainder() throws {
        let server = try RangeFaultServer(header: "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/flac\r\nContent-Range: bytes 1-65536/999999\r\nContent-Length: 65536\r\n\r\n")
        defer { server.stop() }
        let reader = RemoteAudioRangeReader(url: server.url)
        let started = Date()
        do {
            try reader.prepare(generation: reader.advance())
            Issue.record("The returned bytes must begin at the requested position")
        } catch { #expect(Date().timeIntervalSince(started) < 2) }
    }

    @Test(arguments: [false, true])
    func seekAndCancelInterruptPendingNetworkWait(terminate: Bool) throws {
        let server = try RangeFaultServer(header: nil)
        defer { server.stop() }
        let reader = RemoteAudioRangeReader(url: server.url)
        let generation = reader.advance()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try reader.prepare(generation: generation)
                Issue.record("A stale or cancelled request must not return data")
            } catch { }
            finished.signal()
        }
        #expect(server.requested.wait(timeout: .now() + 2) == .success)
        reader.advance(cancel: terminate)
        #expect(finished.wait(timeout: .now() + 0.5) == .success)
        #expect(!reader.isCurrent(generation))
    }

    @Test func overlappingReadsReuseCachedBlocksAndSeekInvalidatesOldReads() throws {
        let payload = Data((0..<262144).map { UInt8($0 % 251) })
        let server = try TestHTTPServer(serving: payload)
        defer { server.stop() }
        let reader = RemoteAudioRangeReader(url: server.url)
        let generation = reader.advance()
        try reader.prepare(generation: generation)
        let before = reader.receivedByteCount
        #expect(try reader.read(at: 100, count: 1000, generation: generation) == payload.subdata(in: 100..<1100))
        #expect(reader.receivedByteCount == before)
        #expect(try reader.read(at: 65000, count: 1000, generation: generation) == payload.subdata(in: 65000..<66000))
        let after = reader.receivedByteCount
        let next = reader.advance()
        #expect(try reader.read(at: 65000, count: 1000, generation: next) == payload.subdata(in: 65000..<66000))
        #expect(reader.receivedByteCount == after)
        do {
            _ = try reader.read(at: 100, count: 1, generation: generation)
            Issue.record("Old seeks must not read even cached bytes")
        } catch { }
    }
}
