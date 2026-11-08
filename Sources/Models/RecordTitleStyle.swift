import Foundation

/// 字幕记录列表的标题样式
enum RecordTitleStyle: String, CaseIterable, Identifiable {
    /// 显示会话时间
    case time
    /// 显示首句字幕片段
    case snippet
    /// 显示 AI 摘要首行（无摘要时回退时间）
    case aiTitle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .time: return "时间"
        case .snippet: return "位置"
        case .aiTitle: return "AI 标题"
        }
    }
}