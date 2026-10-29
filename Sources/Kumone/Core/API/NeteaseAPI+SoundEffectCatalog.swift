import CryptoKit
import Foundation

struct SoundEffectAsset: Codable, Equatable, Sendable {
    let size: Int
    let md5: String
    let link: URL
}

struct SoundEffectPreset: Codable, Identifiable, Equatable, Sendable {
    struct Rights: Codable, Equatable, Sendable {
        struct Result: Codable, Equatable, Sendable { let canUse: Bool }
        let interestsVipType: Int
        let authResult: Result
        var membership: MusicMembershipTier {
            switch interestsVipType { case 0: return .free; case 6: return .vip; default: return .svip }
        }
    }
    let id: Int
    let name: String
    let vipAuthRespItem: Rights
    let soundMaterialList: [SoundEffectAsset]?
    var membership: MusicMembershipTier { vipAuthRespItem.membership }
    func canUse(tier: MusicMembershipTier) -> Bool { tier >= membership && vipAuthRespItem.authResult.canUse }
}

extension NeteaseAPI {
    static func soundEffectCatalog(using client: NeteaseClient = .shared) async throws -> [SoundEffectPreset] {
        struct Response: Decodable { let data: [SoundEffectPreset] }
        guard let session = client.authenticationFingerprint else { throw NeteaseAPIError.needLogin }
        let data = try await client.weapi("/usertool/sound/queryAllSound", ["exposeType": 7], absorbResponseCookies: false)
        let catalog = try client.decoded(Response.self, from: data).data
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        // This endpoint supplies ordinary presets. Device/HRTF compensation is
        // intentionally excluded; its material cannot be applied to all devices.
        return catalog.filter { !($0.soundMaterialList?.isEmpty ?? true) }
    }

    static func soundEffectAuthorized(id: Int, special: Bool, using client: NeteaseClient = .shared) async throws -> Bool {
        struct Response: Decodable {
            struct Item: Decodable { let interestsId: Int; let authResp: SoundEffectPreset.Rights }
            let data: [Item]
        }
        guard let session = client.authenticationFingerprint else { throw NeteaseAPIError.needLogin }
        let query = try JSONSerialization.data(withJSONObject: ["interestsMap": [special ? "116" : "127": [id]]])
        let data = try await client.weapi("/vipauth/app/interests/auth/query",
            ["queryInfo": String(decoding: query, as: UTF8.self)], absorbResponseCookies: false)
        let rights = try client.decoded(Response.self, from: data)
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        return rights.data.first(where: { $0.interestsId == id })?.authResp.authResult.canUse == true
    }

    static func smartSoundKey(songID: Int, using client: NeteaseClient = .shared) async throws -> String? {
        struct Response: Decodable { struct Item: Decodable { let soundKey: String? }; let data: Item? }
        guard let session = client.authenticationFingerprint else { throw NeteaseAPIError.needLogin }
        let data = try await client.weapi("/usertool/smart/sound/get", ["songId": songID], absorbResponseCookies: false)
        let key = try client.decoded(Response.self, from: data).data?.soundKey
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        return key
    }

    static func soundEffectAsset(_ asset: SoundEffectAsset, assets: URLSession = soundAssetSession) async throws -> Data {
        guard asset.size > 0, asset.size <= NCAEContainer.maximumPackageBytes,
              asset.md5.count == 32, asset.md5.allSatisfy(\.isHexDigit),
              var url = URLComponents(url: asset.link, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), host.hasSuffix(".music.126.net") else {
            throw NCAEContainer.DecodingError.invalidHeader
        }
        url.scheme = "https"
        guard let link = url.url else { throw NCAEContainer.DecodingError.invalidHeader }
        let (data, response) = try await assets.data(from: link)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == asset.size,
              Insecure.MD5.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.md5.lowercased() else {
            throw NCAEContainer.DecodingError.invalidPayload
        }
        return data
    }

    static let soundAssetSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
}

/// Entitlements and per-song decisions belong to an account; public, verified
/// material bytes may be shared. Cache misses remain visible when offline.
actor SoundEffectStore {
    static let shared = SoundEffectStore()
    private let directory: URL
    private let assets: URLSession
    init(directory: URL = KumoneDirectories.caches("SoundEffects"), assets: URLSession = NeteaseAPI.soundAssetSession) {
        self.directory = directory
        self.assets = assets
    }
    private struct Cached<T: Codable>: Codable { let date: Date; let value: T }

    func catalog(accountID: Int, offline: Bool, refresh: Bool = false,
                 client: NeteaseClient = .shared) async throws -> [SoundEffectPreset] {
        let key = "\(accountID)/catalog"
        if !refresh, let cached: Cached<[SoundEffectPreset]> = read(key),
           offline || Date().timeIntervalSince(cached.date) < 86_400 { return cached.value }
        guard !offline else { return [] }
        let value = try await NeteaseAPI.soundEffectCatalog(using: client)
        try save(value, key: key)
        return value
    }

    func effect(mode: SoundEffectMode, presetID: Int, songID: Int, accountID: Int,
                tier: MusicMembershipTier, offline: Bool, refresh: Bool = false,
                client: NeteaseClient = .shared) async throws -> AISoundEffect? {
        guard let session = client.authenticationFingerprint else { throw NeteaseAPIError.needLogin }
        let key = "\(accountID)/\(mode.rawValue)-\(mode == .preset ? presetID : songID)"
        if offline {
            guard let cached: Cached<AISoundEffect> = read(key) else { return nil }
            let allowed: Bool
            if mode == .smart || mode == .emotion { allowed = tier >= mode.minimumMembership }
            else { allowed = try await catalog(accountID: accountID, offline: true)
                .first(where: { $0.id == presetID })?.canUse(tier: tier) == true }
            guard allowed else { throw SoundEffectError.unauthorized }
            try cached.value.validate()
            return cached.value
        }
        let effect: AISoundEffect
        switch mode {
        case .emotion:
            guard tier >= .svip, try await NeteaseAPI.soundEffectAuthorized(id: 202, special: true, using: client) else {
                throw SoundEffectError.unauthorized
            }
            guard let analysis = try await NeteaseAPI.emotionSoundAnalysis(songID: songID, using: client) else { return nil }
            effect = try analysis.localEffect()
        case .smart:
            guard tier >= .vip, try await NeteaseAPI.soundEffectAuthorized(id: 200, special: true, using: client) else {
                throw SoundEffectError.unauthorized
            }
            guard let soundKey = try await NeteaseAPI.smartSoundKey(songID: songID, using: client) else { return nil }
            let bank = try await material(Self.smartAsset, offline: false)
            let values = try JSONDecoder().decode([String: SoundEffectValue].self, from: NCAEContainer.decode(bank))
            guard let value = values[soundKey] else { return nil }
            effect = try JSONDecoder().decode(AISoundEffect.self, from: JSONEncoder().encode(value))
        case .preset:
            let list = try await catalog(accountID: accountID, offline: false, refresh: refresh, client: client)
            guard let preset = list.first(where: { $0.id == presetID }) else { return nil }
            guard preset.canUse(tier: tier), try await NeteaseAPI.soundEffectAuthorized(id: presetID, special: false, using: client) else {
                throw SoundEffectError.unauthorized
            }
            guard let assets = preset.soundMaterialList, assets.count == 1, let asset = assets.first else {
                throw NCAEContainer.DecodingError.unsupportedVersion
            }
            effect = try AISoundEffect.decode(package: await material(asset, offline: false))
        default: return nil
        }
        try effect.validate()
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        try Task.checkCancellation()
        try save(effect, key: key)
        return effect
    }

    func tuningMaterials(offline: Bool) async throws -> [String: SoundEffectValue] {
        let data = try await material(Self.diyAsset, offline: offline)
        return try JSONDecoder().decode([String: SoundEffectValue].self, from: NCAEContainer.decode(data))
    }

    private func material(_ asset: SoundEffectAsset, offline: Bool) async throws -> Data {
        guard asset.size > 0, asset.size <= NCAEContainer.maximumPackageBytes,
              asset.md5.count == 32, asset.md5.allSatisfy(\.isHexDigit) else {
            throw NCAEContainer.DecodingError.invalidHeader
        }
        let file = directory.appendingPathComponent("materials/\(asset.md5).ncae")
        if let bytes = try? Data(contentsOf: file), bytes.count == asset.size,
           Insecure.MD5.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == asset.md5 { return bytes }
        guard !offline else { throw SoundEffectError.offlineMissing }
        let data = try await NeteaseAPI.soundEffectAsset(asset, assets: assets)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
    }

    private func read<T: Codable>(_ key: String) -> Cached<T>? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(Cached<T>.self, from: data)
    }
    private func save<T: Codable>(_ value: T, key: String) throws {
        let file = directory.appendingPathComponent(key + ".json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Cached(date: .now, value: value)).write(to: file, options: .atomic)
        // Bound per-account decisions; material bytes are content-addressed.
        let files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.lastPathComponent != "catalog.json" }
        if files.count > 256 {
            let sorted = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in sorted.prefix(files.count - 256) { try FileManager.default.removeItem(at: old) }
        }
    }
    // Resource revisions advertised by the official desktop client. Their
    // immutable paths and MD5 digests keep stale/corrupt downloads detectable.
    private static let smartAsset = SoundEffectAsset(size: 1389, md5: "54952e98082a1f745f7771414e98cb95",
        link: URL(string: "https://d2.music.126.net/dmusic/obj/w5zCg8OAw6HDjzjDgMK_/62216307145/3eff/0421/151f/54952e98082a1f745f7771414e98cb95.ncae")!)
    private static let diyAsset = SoundEffectAsset(size: 596, md5: "d79417b1e6a0c01144b874dfd87359fa",
        link: URL(string: "https://d2.music.126.net/dmusic/obj/w5zCg8OAw6HDjzjDgMK_/62316193532/981d/97b6/8e40/d79417b1e6a0c01144b874dfd87359fa.data?download=effect_diy_ncae")!)
}

enum SoundEffectError: Error { case unauthorized, offlineMissing }
