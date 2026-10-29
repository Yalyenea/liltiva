import Foundation

struct EmotionSoundAnalysis: Codable, Equatable, Sendable {
    let song_id: Int
    let emotion_label: String
    let repbpm: Double
    let dynamic_range: Double
    let stereo_width_ratio: Double
    let vocal_energy_ratio: Double
    let drum_energy_ratio: Double
    let bass_energy_ratio: Double

    func validate() throws {
        guard song_id > 0, emotion_label.count <= 512, !emotion_label.isEmpty,
              (0...400).contains(repbpm), (0...100).contains(dynamic_range),
              [stereo_width_ratio, vocal_energy_ratio, drum_energy_ratio, bass_energy_ratio]
                .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw NCAEContainer.DecodingError.invalidPayload
        }
    }

    /// A local, deliberately modest tuning rule. These coefficients do not
    /// reproduce NetEase's native emotion model: the interface says "本地".
    /// Calm songs get softer highs and space; energetic songs retain attack.
    func localEffect() throws -> AISoundEffect {
        try validate()
        let labels = emotion_label.split(separator: ",").map(String.init)
        let calmLabels: Set<String> = ["平静", "治愈", "悲伤", "抒情", "伤感情绪", "安静"]
        let livelyLabels: Set<String> = ["欢快", "快乐", "兴奋", "热血", "自信", "活力"]
        let calm = Double(labels.filter { calmLabels.contains($0) }.count)
        let lively = Double(labels.filter { livelyLabels.contains($0) }.count)
        let mood = max(-1, min(1, (lively - calm) / 3))
        let low = max(-1.5, min(1.5, (0.22 - bass_energy_ratio - drum_energy_ratio * 0.3) * 5))
        let voice = vocal_energy_ratio >= 0.2 ? 0.7 : 0
        let eq = [low * 0.5, low, low * 0.4, -0.3, 0, voice * 0.4, voice, mood * 0.5, mood, mood * 0.7]
        let width = max(0, min(1.5, (0.5 - stereo_width_ratio) * 4))
        var groups: [String: SoundEffectValue] = [
            "se": .object(["on": .bool(true), "presence": .number(max(0, mood * 0.8)),
                "stereoizer": .number(width), "sshaper": .bool(false), "ambience": .number(max(0, -mood * 1.5))])
        ]
        // Gentle peak compression only for a wide dynamic range. Preserve
        // already compressed recordings instead of adding loudness gain.
        if dynamic_range > 18 {
            groups["cmp"] = .object(["on": .bool(true), "ratio": .number(1.25), "threshold": .number(-12),
                "attack": .number(0.025), "release": .number(0.18), "pregain": .number(-0.5)])
        }
        let effect = AISoundEffect(aev2: .init(eq: .init(on: true, eqs: eq), groups: groups),
            effectStyle: nil, feature: .object(["emotion_label": .string(emotion_label)]))
        try effect.validate()
        return effect
    }
}

extension NeteaseAPI {
    static func emotionSoundAnalysis(songID: Int, using client: NeteaseClient = .shared) async throws -> EmotionSoundAnalysis? {
        struct Response: Decodable { let data: [EmotionSoundAnalysis] }
        guard let session = client.authenticationFingerprint else { throw NeteaseAPIError.needLogin }
        let data = try await client.weapi("/vip-rights/emotion/audio/effect/get", ["songIds": [songID]], absorbResponseCookies: false)
        let result = try client.decoded(Response.self, from: data).data.first { $0.song_id == songID }
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        try result?.validate()
        return result
    }
}
