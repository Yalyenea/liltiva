import Foundation

/// Mirrors the official composer's closing and merge rules. A requested
/// enhancement can remain selected while being unsuitable for this song.
enum AITuningComposer {
    struct Result {
        let effect: AISoundEffect
        let closed: [AITuningPreference: String]
    }

    static func compose(song: AISoundEffect, preferences: Set<AITuningPreference>,
                        materials: [String: SoundEffectValue]) throws -> Result {
        var selected = preferences
        var closed: [AITuningPreference: String] = [:]
        let feature = song.feature ?? .null
        func close(_ preference: AITuningPreference, _ reason: String) {
            if selected.remove(preference) != nil { closed[preference] = reason }
        }
        let ratios = feature["vocal_drum_bass_other_ratio"].array.compactMap(\.number)
        let energies = feature["low_mid_high_ratio"].array.compactMap(\.number)
        let eq = song.aev2.eq.eqs
        if ratios.count > 1, ratios[1] < 0.05 { close(.bass, String(localized: "鼓声较少，本曲未启用")) }
        if let low = energies.first, eq.prefix(3).reduce(0, +) / 3 + 6 * (1 - low) > 6 {
            close(.bass, String(localized: "低频已充足，本曲未启用"))
        }
        if feature.number("vocal_main_freq") > 600 || feature.number("audio_spectral_centroid") > 4000
            || eq.suffix(3).reduce(0, +) / 3 > 5 { close(.treble, String(localized: "高频已充足，本曲未启用")) }
        if let vocal = ratios.first, vocal < 0.2 { close(.vocal, String(localized: "人声较少，本曲未启用")) }
        if selected.contains(.vibe), selected.contains(.live) {
            if song.aev2["rvb"].enabled { close(.live, String(localized: "本曲采用氛围增强")) }
            else { close(.vibe, String(localized: "本曲采用现场增强")) }
        }
        for preference in selected {
            guard materials[preference.rawValue] != nil else { throw NCAEContainer.DecodingError.invalidPayload }
        }
        var result = song
        var parameters = song.aev2
        let bass = selected.contains(.bass), treble = selected.contains(.treble)
        if bass || treble {
            var bt = (materials[(bass ? AITuningPreference.bass : .treble).rawValue] ?? .null)["bt"].object
            if bass && treble {
                let high = (materials[AITuningPreference.treble.rawValue] ?? .null)["bt"]
                for key in ["treble", "trebleFreq", "trebleQ"] { bt[key] = high[key] }
            }
            parameters["bt"] = .object(bt)
        }
        if selected.contains(.vocal) { parameters["peq"] = (materials[AITuningPreference.vocal.rawValue] ?? .null)["peq"] }
        var compressor = parameters["cmp"].object
        var pregain = parameters["cmp"].number("pregain")
        if selected.contains(.vibe) {
            var reverb = parameters["rvb"].object
            reverb["on"] = .bool(false)
            parameters["rvb"] = .object(reverb)
            let vibe = materials[AITuningPreference.vibe.rawValue] ?? .null
            parameters["se"] = vibe["se"]
            pregain += vibe["cmp"].number("pregain")
        }
        if selected.contains(.live) { parameters["rvb"] = (materials[AITuningPreference.live.rawValue] ?? .null)["rvb"] }
        if !selected.isEmpty {
            pregain += [0, -0.5, -1.2, -2.1, -3][min(4, selected.count)]
            compressor["pregain"] = .number(pregain)
            compressor["on"] = .bool(pregain != 0)
            parameters["cmp"] = .object(compressor)
        }
        result.aev2 = parameters
        try result.validate()
        return Result(effect: result, closed: closed)
    }
}
