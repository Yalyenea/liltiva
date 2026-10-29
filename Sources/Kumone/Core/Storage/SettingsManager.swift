import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: SettingsManager.Keys.language)
        // The app-specific AppleLanguages override is read at the next launch,
        // covering Foundation strings, SwiftUI views, and native AppKit menus.
        if self == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([rawValue], forKey: "AppleLanguages") }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to show above Japanese lyrics.
enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

public enum NowPlayingMode: String, CaseIterable, Identifiable {
    case vinyl
    case classic
    case lyrics

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .lyrics: return String(localized: "歌词模式")
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Internal rather than private: `AudioCache` reads its own limit straight
    /// from `UserDefaults` before any settings object exists, and must spell
    /// the key the same way.
    enum Keys {
        static let quality = "settings.audioQuality"
        static let language = "settings.language"
        static let aiSoundEffect = "settings.aiSoundEffect"
        static let aiSoundEffectStrength = "settings.aiSoundEffectStrength"
        static let soundEffectMode = "settings.soundEffectMode"
        static let soundEffectPreset = "settings.soundEffectPreset"
        static let aiTuningPreferences = "settings.aiTuningPreferences"
        static let appearance = "settings.appearance"
        static let nowPlayingMode = "settings.nowPlayingMode"
        static let transparentPlayback = "settings.transparentPlayback"
        static let playbackTransparency = "settings.playbackTransparency"
        static let pinnedNavigationPages = "settings.pinnedNavigationPages"
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"  // migrated to `annotation`
        static let annotation = "settings.lyricsAnnotation"
        static let verbatimLyrics = "settings.verbatimLyrics"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let desktopLyrics = "settings.showDesktopLyrics"
        static let audioCacheLimit = "settings.audioCacheLimit"
        static let outputDevice = "settings.outputDeviceUID"
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
        static let enableAudioCache = "settings.enableAudioCache"
        static let audioCacheSizeMB = "settings.audioCacheSizeMB"
        static let audioCacheAutomatic = "settings.audioCacheAutomatic"
    }

    @Published var language: AppLanguage {
        didSet { language.persist(to: .standard) }
    }
    private let launchLanguage: AppLanguage
    var needsLanguageRestart: Bool { language != launchLanguage }

    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    @Published var soundEffectMode: SoundEffectMode {
        didSet {
            UserDefaults.standard.set(soundEffectMode.rawValue, forKey: Keys.soundEffectMode)
        }
    }
    @Published var soundEffectPresetID: Int {
        didSet { UserDefaults.standard.set(soundEffectPresetID, forKey: Keys.soundEffectPreset) }
    }
    @Published var aiTuningPreferences: Set<AITuningPreference> {
        didSet { UserDefaults.standard.set(aiTuningPreferences.map(\.rawValue).sorted(), forKey: Keys.aiTuningPreferences) }
    }
    @Published var aiSoundEffectStrength: Double {
        didSet { UserDefaults.standard.set(aiSoundEffectStrength, forKey: Keys.aiSoundEffectStrength) }
    }

    static let audioCacheSizeRangeMB = 100...10_000
    static let audioCacheSizeStepMB = 100

    /// Use locally stored audio files before resolving a remote source and
    /// retain completed remote playback for future requests.
    @Published var enableAudioCache: Bool {
        didSet { UserDefaults.standard.set(enableAudioCache, forKey: Keys.enableAudioCache) }
    }

    /// Size the song cache from the device's free space instead of
    /// `audioCacheSizeMB`; see `AutomaticCacheLimit`.
    @Published var audioCacheAutomatic: Bool {
        didSet { UserDefaults.standard.set(audioCacheAutomatic, forKey: Keys.audioCacheAutomatic) }
    }

    static func normalizedAudioCacheSizeMB(_ value: Int) -> Int {
        let boundedValue = min(
            max(value, audioCacheSizeRangeMB.lowerBound),
            audioCacheSizeRangeMB.upperBound
        )
        let distanceFromLowerBound = boundedValue - audioCacheSizeRangeMB.lowerBound
        return audioCacheSizeRangeMB.lowerBound
            + Int((Double(distanceFromLowerBound) / Double(audioCacheSizeStepMB)).rounded())
                * audioCacheSizeStepMB
    }

    @Published var audioCacheSizeMB: Int {
        didSet {
            let normalizedValue = Self.normalizedAudioCacheSizeMB(audioCacheSizeMB)
            guard normalizedValue == audioCacheSizeMB else {
                audioCacheSizeMB = normalizedValue
                return
            }
            UserDefaults.standard.set(audioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var nowPlayingMode: NowPlayingMode {
        didSet { UserDefaults.standard.set(nowPlayingMode.rawValue, forKey: Keys.nowPlayingMode) }
    }

    @Published var transparentPlayback: Bool {
        didSet { UserDefaults.standard.set(transparentPlayback, forKey: Keys.transparentPlayback) }
    }

    static let playbackTransparencyRange = 0.0...1.0
    static let defaultPlaybackTransparency = 0.35

    @Published var playbackTransparency: Double {
        didSet { UserDefaults.standard.set(playbackTransparency, forKey: Keys.playbackTransparency) }
    }

    @Published var pinnedNavigationPages: [RootPage] {
        didSet {
            UserDefaults.standard.set(pinnedNavigationPages.map(\.rawValue), forKey: Keys.pinnedNavigationPages)
        }
    }

    @Published var showLyricsTranslation: Bool {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: Keys.showTranslation) }
    }

    /// Reading shown for Japanese lyrics: a romaji line above, furigana over
    /// the kanji, or nothing.
    @Published var lyricsAnnotation: LyricsAnnotation {
        didSet { UserDefaults.standard.set(lyricsAnnotation.rawValue, forKey: Keys.annotation) }
    }

    /// Karaoke-style word-by-word highlighting when the song has verbatim
    /// (yrc) lyrics; falls back to line highlighting when it doesn't.
    @Published var verbatimLyrics: Bool {
        didSet { UserDefaults.standard.set(verbatimLyrics, forKey: Keys.verbatimLyrics) }
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
    }

    /// Audio cache LRU limit in bytes; 0 = unlimited. AudioCache reads the
    /// same defaults key at startup and receives changes from here.
    @Published var audioCacheLimit: Int64 {
        didSet {
            UserDefaults.standard.set(audioCacheLimit, forKey: Keys.audioCacheLimit)
            Task { await EngineAudioCache.shared.setLimitBytes(audioCacheLimit) }
        }
    }

    /// CoreAudio UID of the chosen output device; "" follows the system
    /// default. UID rather than the numeric AudioDeviceID, which is not
    /// stable across launches. Written by `AudioOutputController`.
    @Published var outputDeviceUID: String {
        didSet { UserDefaults.standard.set(outputDeviceUID, forKey: Keys.outputDevice) }
    }

    /// Lock the desktop-lyrics capsule to the horizontal centre of the screen
    /// instead of the free-drag position (#48).
    @Published var desktopLyricsCentered: Bool {
        didSet { UserDefaults.standard.set(desktopLyricsCentered, forKey: Keys.desktopLyricsCentered) }
    }

    static let mainWindowAmbientBackgroundIntensityRange = 0.5...1.5

    /// Default song-cache ceiling, shared with `AudioCache` so the two cannot
    /// disagree about what "unset" means.
    nonisolated static let defaultAudioCacheLimit: Int64 = 2_147_483_648  // 2 GB

    /// Artwork-tinted overlay on the main app interface.
    @Published var showMainWindowAmbientBackground: Bool {
        didSet {
            UserDefaults.standard.set(
                showMainWindowAmbientBackground,
                forKey: Keys.mainWindowAmbientBackground
            )
        }
    }

    /// Multiplier applied to the main interface's artwork tint.
    @Published var mainWindowAmbientBackgroundIntensity: Double {
        didSet {
            UserDefaults.standard.set(
                mainWindowAmbientBackgroundIntensity,
                forKey: Keys.mainWindowAmbientBackgroundIntensity
            )
        }
    }
    private init() {
        let defaults = UserDefaults.standard
        let language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init) ?? .system
        self.language = language
        launchLanguage = language
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init) ?? .exhigh
        soundEffectMode = defaults.string(forKey: Keys.soundEffectMode).flatMap(SoundEffectMode.init)
            ?? (defaults.bool(forKey: Keys.aiSoundEffect) ? .aiMaster : .off)
        soundEffectPresetID = defaults.object(forKey: Keys.soundEffectPreset) as? Int ?? 3592428
        aiTuningPreferences = Set((defaults.stringArray(forKey: Keys.aiTuningPreferences) ?? []).compactMap(AITuningPreference.init))
        let effectStrength = defaults.object(forKey: Keys.aiSoundEffectStrength) as? Double ?? 1
        aiSoundEffectStrength = effectStrength.isFinite ? min(1, max(0, effectStrength)) : 1
        enableAudioCache = defaults.object(forKey: Keys.enableAudioCache) as? Bool ?? true
        // A size somebody chose stays chosen; the untouched default becomes automatic.
        audioCacheAutomatic = defaults.object(forKey: Keys.audioCacheAutomatic) as? Bool
            ?? (defaults.object(forKey: Keys.audioCacheSizeMB) as? Int).map { $0 == AudioCache.defaultMaximumSizeMB } ?? true
        let storedAudioCacheSizeMB = defaults.object(forKey: Keys.audioCacheSizeMB) as? Int
            ?? AudioCache.defaultMaximumSizeMB
        let normalizedAudioCacheSizeMB = Self.normalizedAudioCacheSizeMB(storedAudioCacheSizeMB)
        audioCacheSizeMB = normalizedAudioCacheSizeMB
        defaults.set(normalizedAudioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .classic
        transparentPlayback = defaults.bool(forKey: Keys.transparentPlayback)
        let storedPlaybackTransparency = defaults.object(forKey: Keys.playbackTransparency) as? Double
            ?? Self.defaultPlaybackTransparency
        playbackTransparency = min(max(storedPlaybackTransparency, Self.playbackTransparencyRange.lowerBound),
                                   Self.playbackTransparencyRange.upperBound)
        let storedPins = defaults.stringArray(forKey: Keys.pinnedNavigationPages) ?? []
        let restoredPins = RootPage.restoredPinnedPages(storedPins)
        pinnedNavigationPages = restoredPins
        if storedPins != restoredPins.map(\.rawValue) {
            defaults.set(restoredPins.map(\.rawValue), forKey: Keys.pinnedNavigationPages)
        }
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        // Carry over the old on/off romaji toggle for anyone who had it on.
        lyricsAnnotation = defaults.string(forKey: Keys.annotation).flatMap(LyricsAnnotation.init)
            ?? (defaults.bool(forKey: Keys.showRomaji) ? .romaji : .off)
        verbatimLyrics = defaults.object(forKey: Keys.verbatimLyrics) as? Bool ?? true
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
        audioCacheLimit = (defaults.object(forKey: Keys.audioCacheLimit) as? Int64)
            ?? Self.defaultAudioCacheLimit
        outputDeviceUID = defaults.string(forKey: Keys.outputDevice) ?? ""
        desktopLyricsCentered = defaults.object(forKey: Keys.desktopLyricsCentered) as? Bool ?? false
        showMainWindowAmbientBackground = defaults.object(
            forKey: Keys.mainWindowAmbientBackground
        ) as? Bool ?? true
        let storedAmbientBackgroundIntensity = defaults.object(
            forKey: Keys.mainWindowAmbientBackgroundIntensity
        ) as? Double ?? 1
        mainWindowAmbientBackgroundIntensity = min(
            max(storedAmbientBackgroundIntensity, Self.mainWindowAmbientBackgroundIntensityRange.lowerBound),
            Self.mainWindowAmbientBackgroundIntensityRange.upperBound
        )
    }
}
