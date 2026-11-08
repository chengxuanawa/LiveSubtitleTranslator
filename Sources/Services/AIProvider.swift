import Foundation

/// AI 引擎选择
enum AIProviderMode: String, CaseIterable {
    /// 自动：优先苹果智能（设备端），不可用且有 API 配置时回退自定义 API
    case auto
    /// 仅苹果智能（设备端）
    case apple
    /// 自定义 OpenAI 兼容 API
    case api
    /// 关闭 AI 功能
    case off

    var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .apple: return "苹果智能（设备端）"
        case .api: return "自定义 AI API"
        case .off: return "关闭 AI 功能"
        }
    }
}

/// 文本 AI 能力抽象（摘要 / 润色），可自由替换为任意实现
@MainActor
protocol TextAIProviding: AnyObject {
    func summarize(_ text: String) async throws -> String?
    func polish(_ text: String) async throws -> String?
}