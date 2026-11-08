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
            to: "请只对以下字幕做压缩归纳，不要新增或改写内容：\n\n\(text)",
            options: GenerationOptions(temperature: 0.1)
        )
        return AITextSanitizer.plainText(response.content)
    }

    func polish(_ text: String) async throws -> String? {
        let response = try await polishSessionValue().respond(
            to: "请把下面的翻译改写得更自然、更口语化。保持原意，只输出改写后的译文：\n\n\(text)",
            options: GenerationOptions(temperature: 0.4)
        )
        return AITextSanitizer.plainText(response.content)
    }

    // MARK: - 私有

    private func summarizeSessionValue() throws -> LanguageModelSession {
        if let summarizeSession { return summarizeSession }
        let session = LanguageModelSession(
            instructions: Instructions {
                AISummaryPrompt.system
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
                "保持原意不变，只改进表达。只输出改写后的纯文本：不要引号、不要星号或任何格式符号。"
            }
        )
        session.prewarm()
        polishSession = session
        return session
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
        return AppleIntelligenceSupport.isAvailable
        #else
        return false
        #endif
    }

    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        let reason = AppleIntelligenceSupport.unavailabilityReason
        return reason.isEmpty ? nil : reason
        #else
        return "当前设备或系统版本不支持 Apple Intelligence"
        #endif
    }
}