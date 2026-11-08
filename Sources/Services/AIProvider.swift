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

/// 清理模型输出中的 Markdown 格式符号，保证摘要 / 润色以纯文本展示
enum AITextSanitizer {
    static func plainText(_ content: String) -> String? {
        var result: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // 去除行首 Markdown 记号（*、-、#、>、• 等）
            while let first = line.first, ["*", "-", "#", ">", "•", "·"].contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        let joined = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}