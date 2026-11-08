import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// 基于 iOS 26 Foundation Models 框架的实现：直接调用驱动 Apple Intelligence 的设备端大模型。
/// 需要 Xcode 26 编译，且运行在支持 Apple Intelligence 的设备上。
@available(iOS 26.0, *)
@MainActor
final class AppleIntelligenceProvider: TextAIProviding {

    private var summarizeSession: LanguageModelSession?
    private var polishSession: LanguageModelSession?

    func summarize(_ text: String) async throws -> String? {
        let response = try await summarizeSessionValue().respond(
            to: "请总结以下字幕会话：\n\n\(text)",
            options: GenerationOptions(temperature: 0.2)
        )
        return cleaned(response.content)
    }

    func polish(_ text: String) async throws -> String? {
        let response = try await polishSessionValue().respond(
            to: "请把下面的翻译改写得更自然、更口语化。保持原意，只输出改写后的译文：\n\n\(text)",
            options: GenerationOptions(temperature: 0.4)
        )
        return cleaned(response.content)
    }

    // MARK: - 私有

    private func summarizeSessionValue() throws -> LanguageModelSession {
        if let summarizeSession { return summarizeSession }
        let session = LanguageModelSession(
            instructions: Instructions {
                "你是一名专业的会议与对话摘要助手。"
                "用户会提供一段带原文和译文的字幕记录。"
                "输出简洁的中文摘要：先用一句话总括，再列 3-5 个要点。"
                "不要编造字幕中没有的内容。"
            }
        )
        session.prewarm()
        summarizeSession = session
        return session
    }

    private func polishSessionValue() throws -> LanguageModelSession {
        if let polishSession { return polishSession }
        let session = LanguageModelSession(
            instructions: Instructions {
                "你是翻译校对助手，负责把直译的句子改写得更自然、口语化，符合目标语言习惯。"
                "保持原意不变，只改进表达。输出时只给改写后的文本。"
            }
        )
        session.prewarm()
        polishSession = session
        return session
    }

    private func cleaned(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 苹果智能可用性检查（iOS 26+ 专用）
@available(iOS 26.0, *)
enum AppleIntelligenceSupport {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailabilityReason: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(.appleIntelligenceNotEnabled):
            return "系统未开启 Apple Intelligence"
        case .unavailable(.modelNotReady):
            return "模型尚未就绪，请稍后重试"
        default:
            return "当前设备或系统版本不支持 Apple Intelligence"
        }
    }
}

#else
// 编译环境不含 FoundationModels（Xcode 16 或更低 SDK）时的占位实现，
// 此时 AI 自动降级为自定义 API 或关闭。
@MainActor
final class AppleIntelligenceProvider: TextAIProviding {
    func summarize(_ text: String) async throws -> String? { nil }
    func polish(_ text: String) async throws -> String? { nil }
}
#endif

/// 苹果智能可用性查询（跨 SDK 版本安全，未限定系统版本的代码统一从这里判断）
enum AppleIntelligenceAvailability {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleIntelligenceSupport.isAvailable
        }
        #endif
        return false
    }

    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let reason = AppleIntelligenceSupport.unavailabilityReason
            return reason.isEmpty ? nil : reason
        }
        #endif
        return "当前设备或系统版本不支持 Apple Intelligence"
    }
}