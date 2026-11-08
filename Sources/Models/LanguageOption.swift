import Foundation

/// 支持的语言选项
struct LanguageOption: Identifiable, Hashable {
    /// 语言标识，例如 zh-Hans、en-US
    let identifier: String
    /// 界面显示名称
    let displayName: String

    var id: String { identifier }

    var locale: Locale { Locale(identifier: identifier) }
    var localeLanguage: Locale.Language { Locale.Language(identifier: identifier) }

    static let all: [LanguageOption] = [
        LanguageOption(identifier: "zh-Hans", displayName: "中文（简体）"),
        LanguageOption(identifier: "zh-TW", displayName: "中文（繁體）"),
        LanguageOption(identifier: "en-US", displayName: "英语（美国）"),
        LanguageOption(identifier: "en-GB", displayName: "英语（英国）"),
        LanguageOption(identifier: "ja-JP", displayName: "日语"),
        LanguageOption(identifier: "ko-KR", displayName: "韩语"),
        LanguageOption(identifier: "fr-FR", displayName: "法语"),
        LanguageOption(identifier: "de-DE", displayName: "德语"),
        LanguageOption(identifier: "es-ES", displayName: "西班牙语"),
        LanguageOption(identifier: "ru-RU", displayName: "俄语"),
        LanguageOption(identifier: "it-IT", displayName: "意大利语"),
        LanguageOption(identifier: "pt-BR", displayName: "葡萄牙语（巴西）"),
        LanguageOption(identifier: "th-TH", displayName: "泰语"),
        LanguageOption(identifier: "vi-VN", displayName: "越南语"),
        LanguageOption(identifier: "id-ID", displayName: "印尼语"),
        LanguageOption(identifier: "ar-SA", displayName: "阿拉伯语"),
    ]

    /// 根据标识取语言；未知标识时原样展示
    static func option(for identifier: String) -> LanguageOption {
        all.first { $0.identifier == identifier } ?? LanguageOption(identifier: identifier, displayName: identifier)
    }
}