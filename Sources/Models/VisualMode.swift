import Foundation

/// 字幕浮窗显示方式
enum VisualMode: String, CaseIterable, Identifiable {
    /// 自动：有灵动岛的 iPhone 用灵动岛；iPad 等默认画中画小窗口
    case auto
    /// 强制使用灵动岛 / 锁屏实时活动
    case liveActivity
    /// 强制使用画中画小窗口
    case pictureInPicture

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动（按机型）"
        case .liveActivity: return "灵动岛 / 锁屏"
        case .pictureInPicture: return "画中画小窗口"
        }
    }
}