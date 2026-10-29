import Foundation
import Testing
@testable import KumoneCore

@Suite("App language settings")
struct LanguageSettingsTests {
    @Test func languageOverrideIsScopedToTheAppAndSystemChoiceRemovesIt() throws {
        let domain = "io.github.yalyenea.Liltiva.language-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let originalSystemLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages")

        AppLanguage.simplifiedChinese.persist(to: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        #expect(defaults.string(forKey: SettingsManager.Keys.language) == "zh-Hans")
        AppLanguage.english.persist(to: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
        AppLanguage.system.persist(to: defaults)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        #expect(defaults.string(forKey: SettingsManager.Keys.language) == "system")
        #expect(UserDefaults.standard.stringArray(forKey: "AppleLanguages") == originalSystemLanguages)
    }

    @Test func onlyQualityAndEffectNamesStayChineseInTheEnglishInterface() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Kumone/Resources")
        let english = try #require(Bundle(url: resources.appendingPathComponent("en.lproj")))
        let chinese = try #require(Bundle(url: resources.appendingPathComponent("zh-Hans.lproj")))
        let names = AudioQuality.allCases.map(\.displayName) + ["高解析", "AI调音大师", "智能音效", "情绪调音师"]
        for name in names {
            #expect(english.localizedString(forKey: name, value: nil, table: nil) == name)
            #expect(chinese.localizedString(forKey: name, value: nil, table: nil) == name)
        }
        // These labels and states were accidentally forced to Chinese before.
        for label in ["音质", "播放音质", "账号权益", "普通账号", "黑胶 VIP", "音效模式", "音效状态",
                      "音效已应用", "调音强度", "低频增强", "重试音效", "播放页模式", "背景透明度", "语言"] {
            #expect(english.localizedString(forKey: label, value: nil, table: nil) != label)
        }
    }
}
