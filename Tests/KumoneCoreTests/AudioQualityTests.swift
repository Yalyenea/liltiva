import AVFoundation
import CommonCrypto
import Foundation
import Testing
@testable import KumoneCore

private final class QualityAPIProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
            }
            let form = try #require(String(data: body, encoding: .utf8))
            let hex = try #require(form.split(separator: "=").last.map(String.init))
            let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            let encrypted = Data(bytes), key = Data("e82ckenh8dichen8".utf8)
            var output = Data(count: encrypted.count + 16), written = 0
            let status = output.withUnsafeMutableBytes { out in
                encrypted.withUnsafeBytes { input in
                    key.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                                key.baseAddress, 16, nil, input.baseAddress, encrypted.count,
                                out.baseAddress, out.count, &written)
                    }
                }
            }
            #expect(status == kCCSuccess)
            let plain = try #require(String(data: output.prefix(written), encoding: .utf8))
            let parts = plain.components(separatedBy: "-36cd479b6b5-")
            let payload = try #require(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any])
            let level = try #require(payload["level"] as? String)
            let header = try #require(payload["header"] as? [String: String])
            #expect(parts[0] == "/api/song/enhance/player/url/v1")
            #expect(payload["ids"] as? String == "[1]")
            if level == "vivid" {
                #expect(payload["encodeType"] as? String == "mp3")
                #expect(header["os"] == "android" && header["appver"] == "9.5.61")
                #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("os=android") == true)
            } else {
                #expect(payload["encodeType"] as? String == "flac")
                #expect(header["os"] == "pc")
            }
            if level == "sky" { #expect(payload["immerseType"] as? String == "c51") }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // A server downgrade must survive decoding as the actual quality.
            client?.urlProtocol(self, didLoad: Data("""
            {"code":200,"data":[{"id":1,"url":"https://example.test/audio.flac","level":"jyeffect"}]}
            """.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@Suite("Account audio quality")
struct AudioQualityTests {
    @Test func membershipUsesActiveBenefitsRatherThanLoyaltyLevel() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func decode(_ json: String) throws -> MusicMembership {
            try JSONDecoder().decode(MusicMembership.self, from: Data(json.utf8))
        }
        #expect(try decode("{\"redVipLevel\":7}").tier(at: now) == .free)
        let vip = try decode("""
        {"redVipLevel":7,"associator":{"vipCode":100,"expireTime":1800000100000},
         "redplus":{"vipCode":300,"expireTime":1799999999000}}
        """)
        #expect(vip.tier(at: now) == .vip)
        #expect(vip.tier(at: now.addingTimeInterval(100)) == .free)
        let svip = try decode("{\"redplus\":{\"vipCode\":300,\"expireTime\":1800000100000}}")
        #expect(svip.tier(at: now) == .svip)
    }

    @Test func qualityChoicesExpandWithMembership() {
        #expect(AudioQuality.available(for: .free) == [.standard, .higher, .exhigh])
        #expect(AudioQuality.available(for: .vip) == [.standard, .higher, .exhigh, .lossless, .hires, .jyeffect])
        #expect(AudioQuality.available(for: .svip) == AudioQuality.allCases)
        #expect(!AudioQuality.hires.usesNativePlayback)
        #expect([AudioQuality.hires, .jyeffect, .jymaster].allSatisfy { $0.preservesSampleRate })
        #expect(AudioQuality.allCases.filter(\.isSpatial).allSatisfy { $0.usesNativePlayback })
    }

    @Test func cachedSpatialMixesNeverReplaceStereoMastersOrOtherSpatialMixes() {
        #expect(AudioQuality.hires.canSubstitute(for: .lossless))
        #expect(!AudioQuality.jymaster.canSubstitute(for: .hires))
        #expect(!AudioQuality.jyeffect.canSubstitute(for: .hires))
        #expect(!AudioQuality.sky.canSubstitute(for: .hires))
        #expect(!AudioQuality.dolby.canSubstitute(for: .sky))
        #expect(!AudioQuality.jymaster.canSubstitute(for: .vivid))
        #expect(AudioQuality.vivid.canSubstitute(for: .vivid))
    }

    @Test(arguments: [AudioQuality.sky, .vivid, .jymaster, .dolby])
    func encryptedRequestCarriesTheRequiredClientProfile(_ quality: AudioQuality) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QualityAPIProtocol.self]
        let client = NeteaseClient(configuration: configuration, persistsCookies: false)
        let response = try await NeteaseAPI.songURL(ids: [1], level: quality.rawValue, using: client)
        #expect(response.first?.level == "jyeffect")
    }

    @Test func aSpatialDownloadDoesNotSatisfyAStereoDownload() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let spatial = OfflineAudioDescriptor(identity: .init(accountScope: "test-account", trackID: 1,
            source: "netease", quality: "sky", format: .flac, contentMD5: fixture.descriptor.identity.contentMD5),
            byteCount: fixture.descriptor.byteCount, duration: 3)
        try await store.importFixture(fixture.data, descriptor: spatial)
        #expect(try await store.reusableDescriptor(accountScope: "test-account", trackID: 1, quality: "hires") == nil)
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1,
                                       preferredQuality: "jymaster", allowLowerQuality: false) == nil)
    }
}

@Suite("Native audio playback", .serialized)
struct NativeAudioPlaybackTests {
    @Test @MainActor func highResolutionPlaybackSupportsPauseSeekResumeAndEngineSwitching() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/native-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384_000))
            buffer.frameLength = 384_000
            try file.write(from: buffer)
        }
        let engine = PlaybackEngine()
        engine.outputVolume = 0
        var finished = false
        let events = Task { @MainActor in
            for await event in engine.events {
                if case .finished = event { finished = true }
            }
        }
        defer { events.cancel() }
        defer { engine.stop() }
        engine.loadNative(from: url, duration: 4)
        #expect(engine.usesNativePlayback)
        engine.play(from: 0)
        for _ in 0..<100 where engine.position < 0.15 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.position >= 0.15)
        engine.pause()
        try await Task.sleep(for: .milliseconds(150))
        let paused = engine.position
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(engine.position - paused) < 0.05)
        engine.seek(to: 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(engine.position - 2) < 0.05)
        engine.resume()
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.position > 2.1)
        engine.seek(to: 3.8)
        for _ in 0..<60 where !finished { try await Task.sleep(for: .milliseconds(50)) }
        #expect(finished)
        engine.stop()
        #expect(!engine.usesNativePlayback)
        _ = try engine.loadFile(at: url)
        #expect(!engine.usesNativePlayback)
        engine.play(from: 0)
        try await Task.sleep(for: .milliseconds(250))
        #expect(engine.position > 0)
    }

    @Test @MainActor func undecodableNativeSourceReportsFailure() async throws {
        let engine = PlaybackEngine()
        engine.outputVolume = 0
        var failed = false
        let events = Task { @MainActor in
            for await event in engine.events {
                if case .streamFailed(_) = event { failed = true }
            }
        }
        defer { events.cancel(); engine.stop() }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/nonexistent-\(UUID()).flac")
        engine.loadNative(from: url, duration: 3)
        engine.play(from: 0)
        for _ in 0..<60 where !failed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(failed)
    }
}
