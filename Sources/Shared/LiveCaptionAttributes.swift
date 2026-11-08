import ActivityKit
import Foundation

/// 灵动岛 / 锁屏实时字幕的属性（主 App 与 Widget 扩展共享编译）
struct LiveCaptionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 最新一句原文
        var originalText: String
        /// 最新一句译文（尚未翻译完成时为 nil）
        var translatedText: String?
        /// 语言对说明，如 "zh-Hans → en-US"
        var languagePair: String
    }

    var sessionID: String
}