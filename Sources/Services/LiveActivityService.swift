import ActivityKit
import Foundation

/// 灵动岛 / 锁屏实时字幕（基于 ActivityKit Live Activity）
struct LiveCaptionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 最新一句原文
        var originalText: String
        /// 最新一句译文（尚未翻译完成时为 nil）
        var translatedText: String?
        /// 语言对说明，如 "zh-Hans → en-US"
        var languagePair: String
        /// 会话开始时间
        var startedAt: Date
    }

    var sessionID: String
}

/// 管理实时字幕 Live Activity 的启动 / 更新 / 结束。
/// 注意：受系统更新预算限制，按“完整句子”粒度更新（而非逐字部分结果）。
@MainActor
final class LiveActivityService {

    private var activity: Activity<LiveCaptionAttributes>?
    private var languagePair = ""

    /// 系统是否允许本 App 使用实时活动
    static var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(languagePair: String) {
        guard Self.isSupported, activity == nil else { return }
        self.languagePair = languagePair
        let attributes = LiveCaptionAttributes(sessionID: UUID().uuidString)
        let state = LiveCaptionAttributes.ContentState(
            originalText: "正在聆听…",
            translatedText: nil,
            languagePair: languagePair,
            startedAt: .now
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            #if DEBUG
            print("[LiveActivity] 启动失败：\(error.localizedDescription)")
            #endif
        }
    }

    func update(originalText: String, translatedText: String?) {
        guard let activity else { return }
        let state = LiveCaptionAttributes.ContentState(
            originalText: originalText,
            translatedText: translatedText,
            languagePair: languagePair,
            startedAt: activity.content.state.startedAt
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        let current = activity
        self.activity = nil
        Task {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }
}