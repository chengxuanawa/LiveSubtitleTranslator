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

/// 文本 AI 能力抽象（摘要 / 润色 / 断句），可自由替换为任意实现
@MainActor
protocol TextAIProviding: AnyObject {
    func summarize(_ text: String) async throws -> String?
    /// 润色译文；targetLanguage 用于约束输出语言，禁止翻译成其他语言
    func polish(_ text: String, targetLanguage: String) async throws -> String?
    /// 只插入换行做语义断句，返回按行排列的原句，不改写原文
    /// - Parameter context: 前几段已确定字幕，仅用于理解语境，不参与输出
    func segment(_ text: String, context: String?) async throws -> String?
}

/// 断句提示词：仅允许插入换行，保证原文不被改写；支持带上下文理解
enum AISegmentationPrompt {
    static let system = """
    你负责为实时语音字幕做语义断句。用户会先给出一段「前文上下文」，再给出「待分段文本」。前文只用于理解语境，绝对不要输出前文。

    必须遵守：
    1. 只能对待分段文本插入换行，不能增加、删除或修改任何文字、标点、数字。
    2. 每行输出一句，不要编号，不要解释，不要 Markdown 或引号。
    3. 待分段文本已经是一句完整的话时直接原样输出。
    4. 所有行按顺序拼接后必须与「待分段文本」完全一致，不能包含任何前文内容。
    5. 结合前文判断句子是否完整：当前文语义未结束时不要强行断句。
    """

    /// 把上下文和待分段文本拼成一条用户消息
    static func userMessage(text: String, context: String?) -> String {
        guard let context, !context.isEmpty else { return text }
        return """
        前文上下文（仅供理解语境，不要输出、不要分段）：
        \(context)

        待分段文本（只对它分段）：
        \(text)
        """
    }
}

/// 解析并校验断句结果；模型改动原文时返回 nil，交由本地规则兜底
enum AISegmentationParser {
    static func lines(from content: String, original: String) -> [String]? {
        let rawLines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return nil }

        let normalizedOriginal = normalize(original)
        let normalizedJoined = normalize(rawLines.joined())
        guard normalizedOriginal == normalizedJoined else { return nil }
        return rawLines
    }

    private static func normalize(_ text: String) -> String {
        // 保留单词之间的空格，只把连续空白压缩成一个空格，避免模型悄悄改词距
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 严格摘要提示词：只对已有字幕做压缩归纳，不改写、不扩写、不新增内容
enum AISummaryPrompt {
    static let system = """
    你是一名严格的字幕摘要编辑。用户会提供一段实时字幕记录（含原文与译文）。你的唯一任务是对已有内容做压缩归纳，不是改写、扩写、补充或评价。

    必须遵守：
    1. 只使用字幕中明确出现的信息，不得新增原文没有的事实、背景、数字、人名、原因、结论、建议或推测。
    2. 不得改变原意，不得把不确定的内容写成确定，不得把不同话题合并成原文没有的结论。
    3. 第一句用一句话总括；只有内容足够时才用「1. 2. 3.」列出关键点，最多 5 条；内容较短时只输出 1-2 句，禁止为凑条数而补充内容。
    4. 保留原文中的专有名词、数字和关键限定词；译文仅用于辅助理解，不要逐句复述。
    5. 只输出纯文本，不要 Markdown、星号、井号、引号等格式符号，不要加“总结如下”等开场白。
    """
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