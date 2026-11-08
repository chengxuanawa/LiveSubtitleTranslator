import ActivityKit
import Foundation

/// 管理实时字幕 Live Activity 的启动 / 更新 / 结束。
/// 注意：受系统更新预算限制，按“完整句子”粒度更新（而非逐字部分结果）。
@MainActor
final class LiveActivityService: ObservableObject {

    @Published private(set) var isActive = false

    private var activity: Activity<LiveCaptionAttributes>?
    private var languagePair = ""

    /// 系统是否允许本 App 使用实时活动
    static var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 启动灵动岛字幕；返回是否成功
    @discardableResult
    func start(languagePair: String) -> Bool {
        guard Self.isSupported else { return false }
        if activity != nil {
            isActive = true
            return true
        }
        self.languagePair = languagePair
        let attributes = LiveCaptionAttributes(sessionID: UUID().uuidString)
        let state = LiveCaptionAttributes.ContentState(
            originalText: "正在聆听…",
            translatedText: nil,
            languagePair: languagePair
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            isActive = true
        } catch {
            activity = nil
            isActive = false
            #if DEBUG
            print("[LiveActivity] 启动失败：\(error.localizedDescription)")
            #endif
        }
        return isActive
    }

    func update(originalText: String, translatedText: String?) {
        guard let activity else { return }
        let state = LiveCaptionAttributes.ContentState(
            originalText: originalText,
            translatedText: translatedText,
            languagePair: languagePair
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        let current = activity
        activity = nil
        isActive = false
        guard let current else { return }
        Task {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }
}