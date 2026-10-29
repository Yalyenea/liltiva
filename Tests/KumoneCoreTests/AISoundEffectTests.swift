import CryptoKit
import Foundation
import Testing
@testable import KumoneCore

private func effectFixture(_ name: String = "ai-eq") throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ncae", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("NCAE parameter decoding")
struct NCAEDecodingTests {
    @Test func serverPackageMatchesOfficialDecodedParameters() throws {
        // Recorded API parameter document, containing no audio or account data.
        let effect = try AISoundEffect.decode(package: effectFixture())
        #expect(effect.effectStyle == "key_transparent")
        #expect(effect.aev2.eq.on)
        #expect(effect.aev2.eq.eqs == [-1.82, 0.76, 0.41, -0.83, -0.16, 1.22, 0.87, 1.53, 1.8, 1.75])
        #expect(try JSONDecoder().decode(AISoundEffect.self, from: JSONEncoder().encode(effect)) == effect)
    }

    @Test func everyTruncatedPackageIsRejected() throws {
        let data = try effectFixture()
        for count in 0..<data.count {
            #expect(throws: (any Error).self) { _ = try NCAEContainer.decode(data.prefix(count)) }
        }
    }

    @Test func unsupportedAndInconsistentHeadersAreRejected() throws {
        let data = try effectFixture()
        for offset in [0, 4, 12, 14, 16] {
            var invalid = data
            invalid[offset] ^= 0x7f
            #expect(throws: (any Error).self) { _ = try NCAEContainer.decode(invalid) }
        }
        #expect(throws: NCAEContainer.DecodingError.tooLarge) {
            _ = try NCAEContainer.decode(Data(count: NCAEContainer.maximumPackageBytes + 1))
        }
    }

    @Test func decompressionHasAnIndependentOutputLimit() throws {
        #expect(throws: NCAEContainer.DecodingError.tooLarge) {
            _ = try NCAEContainer.decode(effectFixture("ai-eq-expansion-limit"))
        }
    }

    @Test func invalidBandCountsAndGainsAreRejected() {
        for gains in [Array(repeating: 0.0, count: 9), Array(repeating: 25.0, count: 10), Array(repeating: Double.nan, count: 10)] {
            let effect = AISoundEffect(aev2: .init(eq: .init(on: true, eqs: gains)), effectStyle: nil)
            #expect(throws: (any Error).self) { try effect.validate() }
        }
    }

    @Test func intensityScalesTheCurveAndZeroHasNoHeadroomAttenuation() throws {
        let effect = try AISoundEffect.decode(package: effectFixture())
        #expect(effect.gains(strength: 0) == Array(repeating: 0, count: 10))
        #expect(effect.gains(strength: 0.5) == effect.aev2.eq.eqs.map { $0 * 0.5 })
        #expect(AISoundEffect.preampDB(gains: effect.gains(strength: 0), sampleRate: 96_000) == 0)
        #expect(AISoundEffect.preampDB(gains: effect.gains(strength: 1), sampleRate: 96_000) < -1)
    }
}

private final class SoundEffectProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite("AI sound effect requests", .serialized)
struct AISoundEffectRequestTests {
    private func sessions() -> (NeteaseClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SoundEffectProtocol.self]
        let client = NeteaseClient(configuration: config, persistsCookies: false)
        client.setCookies(["MUSIC_U": "test-account-a"])
        return (client, URLSession(configuration: config))
    }

    private func response(_ package: Data, md5: String? = nil, scheme: String = "https") throws -> Data {
        let digest = md5 ?? Insecure.MD5.hash(data: package).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: ["code": 200, "data": [
            ["id": 491107880, "effect": ["url": "\(scheme)://d2.music.126.net/effect.ncae", "size": package.count, "md5": digest]]
        ]])
    }

    @Test(arguments: ["http", "https"])
    func authenticatedAPIToPackageToParametersIsIndependentOfOfficialApp(_ scheme: String) async throws {
        let package = try effectFixture(), metadata = try response(package, scheme: scheme)
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        SoundEffectProtocol.handler = { request in
            if request.url?.host == "music.163.com" {
                #expect(request.url?.path == "/weapi/vip-rights/svip/sound/effect/get")
                #expect(request.httpMethod == "POST")
                return (200, metadata)
            }
            #expect(request.url?.scheme == "https")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return (200, package)
        }
        let effect = try await NeteaseAPI.aiSoundEffect(songID: 491107880, using: client, assets: assets)
        #expect(effect?.effectStyle == "key_transparent")
    }

    @Test func modifiedPackageFailsItsIntegrityCheck() async throws {
        let package = try effectFixture(), metadata = try response(package, md5: String(repeating: "0", count: 32))
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        SoundEffectProtocol.handler = { ($0.url?.host == "music.163.com") ? (200, metadata) : (200, package) }
        await #expect(throws: NCAEContainer.DecodingError.invalidPayload) {
            _ = try await NeteaseAPI.aiSoundEffect(songID: 491107880, using: client, assets: assets)
        }
    }

    @Test func accountChangeDuringAssetDownloadRejectsTheResult() async throws {
        let package = try effectFixture(), metadata = try response(package)
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        SoundEffectProtocol.handler = { request in
            if request.url?.host == "music.163.com" { return (200, metadata) }
            client.setCookies(["MUSIC_U": "test-account-b"])
            return (200, package)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await NeteaseAPI.aiSoundEffect(songID: 491107880, using: client, assets: assets)
        }
    }

    @Test func missingSongAndDeniedMembershipNeverApplyAnEffect() async throws {
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        SoundEffectProtocol.handler = { _ in (200, Data(#"{"code":200,"data":[]}"#.utf8)) }
        #expect(try await NeteaseAPI.aiSoundEffect(songID: 491107880, using: client, assets: assets) == nil)
        SoundEffectProtocol.handler = { _ in (200, Data(#"{"code":403,"message":"SVIP required"}"#.utf8)) }
        await #expect(throws: NeteaseAPIError.self) {
            _ = try await NeteaseAPI.aiSoundEffect(songID: 491107880, using: client, assets: assets)
        }
    }

    @Test func offlineParameterCacheIsScopedToItsAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = directory.appendingPathComponent("1")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let effect = try AISoundEffect.decode(package: effectFixture())
        struct Cached: Encodable { let fetchedAt: Date; let effect: AISoundEffect }
        try JSONEncoder().encode(Cached(fetchedAt: .now, effect: effect))
            .write(to: account.appendingPathComponent("491107880.json"))
        let store = AISoundEffectStore(directory: directory)
        #expect(try await store.effect(songID: 491107880, accountID: 1, offline: true) == effect)
        #expect(try await store.effect(songID: 491107880, accountID: 2, offline: true) == nil)
    }
}

extension AISoundEffectRequestTests {
    @Test func catalogUsesCurrentOfficialNamesMaterialsAndEntitlements() async throws {
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        SoundEffectProtocol.handler = { request in
            #expect(request.url?.path == "/weapi/usertool/sound/queryAllSound")
            return (200, Data(#"{"code":200,"data":[{"id":3592428,"name":"3D环绕","vipAuthRespItem":{"interestsVipType":0,"authResult":{"canUse":true}},"soundMaterialList":[{"size":100,"md5":"00000000000000000000000000000000","link":"http://d1.music.126.net/effect.ncae"}]},{"id":3592400,"name":"8D环绕","vipAuthRespItem":{"interestsVipType":15,"authResult":{"canUse":true}},"soundMaterialList":[{"size":100,"md5":"00000000000000000000000000000000","link":"http://d1.music.126.net/effect.ncae"}]}]}"#.utf8))
        }
        let catalog = try await NeteaseAPI.soundEffectCatalog(using: client)
        #expect(catalog.count == 2)
        #expect(catalog[0].canUse(tier: .free))
        #expect(!catalog[1].canUse(tier: .vip))
        #expect(catalog[1].canUse(tier: .svip))
        #expect(SoundEffectMode.aiMaster.minimumMembership == .svip)
        #expect(SoundEffectMode.smart.minimumMembership == .vip)
    }

    @Test func permissionDenialAndAccountChangesDoNotGrantEffects() async throws {
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        SoundEffectProtocol.handler = { request in
            #expect(request.url?.path == "/weapi/vipauth/app/interests/auth/query")
            return (200, Data(#"{"code":200,"data":[{"interestsId":200,"authResp":{"interestsVipType":6,"authResult":{"canUse":false}}}]}"#.utf8))
        }
        #expect(try await !NeteaseAPI.soundEffectAuthorized(id: 200, special: true, using: client))
        SoundEffectProtocol.handler = { _ in
            client.setCookies(["MUSIC_U": "test-account-b"])
            return (200, Data(#"{"code":200,"data":[]}"#.utf8))
        }
        await #expect(throws: (any Error).self) { _ = try await NeteaseAPI.soundEffectCatalog(using: client) }
    }

    @Test func cachedSmartEffectCannotCrossAccountsOrOutliveMembership() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/sound-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = directory.appendingPathComponent("1")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        struct Cached: Encodable { let date: Date; let value: AISoundEffect }
        let effect = try AISoundEffect.decode(package: effectFixture())
        try JSONEncoder().encode(Cached(date: .now, value: effect)).write(to: account.appendingPathComponent("smart-123.json"))
        let store = SoundEffectStore(directory: directory), (client, assets) = sessions()
        defer { assets.invalidateAndCancel() }
        #expect(try await store.effect(mode: .smart, presetID: 0, songID: 123, accountID: 1, tier: .vip, offline: true, client: client) == effect)
        #expect(try await store.effect(mode: .smart, presetID: 0, songID: 123, accountID: 2, tier: .svip, offline: true, client: client) == nil)
        await #expect(throws: SoundEffectError.unauthorized) {
            _ = try await store.effect(mode: .smart, presetID: 0, songID: 123, accountID: 1, tier: .free, offline: true, client: client)
        }
    }
}

extension AISoundEffectRequestTests {
    @Test func smartSelectionFetchesVerifiedBankAndUsesExactlyTheReturnedKey() async throws {
        let (client, assets) = sessions()
        defer { assets.invalidateAndCancel(); SoundEffectProtocol.handler = nil }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/smart-request-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bank = try effectFixture("effect-smart")
        var key = "1"
        SoundEffectProtocol.handler = { request in
            if request.url?.host == "d2.music.126.net" {
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                return (200, bank)
            }
            if request.url?.path.hasSuffix("/vipauth/app/interests/auth/query") == true {
                return (200, Data(#"{"code":200,"data":[{"interestsId":200,"authResp":{"interestsVipType":6,"authResult":{"canUse":true}}}]}"#.utf8))
            }
            #expect(request.url?.path == "/weapi/usertool/smart/sound/get")
            return (200, try JSONSerialization.data(withJSONObject: ["code": 200, "data": ["soundKey": key]]))
        }
        let store = SoundEffectStore(directory: directory, assets: assets)
        let effect = try await store.effect(mode: .smart, presetID: 0, songID: 123, accountID: 1,
                                            tier: .vip, offline: false, client: client)
        #expect(effect?.aev2.eq.eqs == [-1, -0.6, 0, 0, 0, 1, 1.8, 2.8, 1.8, -1])
        key = "unknown-genre"
        #expect(try await store.effect(mode: .smart, presetID: 0, songID: 124, accountID: 1,
                                       tier: .vip, offline: false, client: client) == nil)
    }
}
