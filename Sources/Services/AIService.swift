import Foundation
import SwiftUI

/// AI 服务编排：按设置与设备能力选择引擎（苹果智能 → 自定义 API → 关闭）
@MainActor
final class AIService: ObservableObject {

    private let settings: SettingsStore
    /// 苹果智能 Provider 的存储（AnyObject 承载，避免在不满足 iOS 26 可用性的位置直接引用该类）
    private var appleProviderStorage: AnyObject?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - 能力查询

    /// 设备是否可用苹果智能（iOS 26 + Apple Intelligence 机型且已开启）
    static var appleIntelligenceAvailable: Bool {
        AppleIntelligenceAvailability.isAvailable
    }

    static var appleIntelligenceUnavailableReason: String? {
        AppleIntelligenceAvailability.unavailabilityReason
    }

    /// 是否有可用的 AI 引擎供摘要 / 润色使用
    var isAvailable: Bool {
        switch resolvedMode {
        case .apple:
            return Self.appleIntelligenceAvailable
        case .api:
            return settings.isAPIConfigured
        case .auto, .off:
            return false
        }
    }

    /// 当前引擎的展示文案
    var statusText: String {
        switch resolvedMode {
        case .apple where Self.appleIntelligenceAvailable:
            return "苹果智能（设备端）"
        case .apple:
            return "苹果智能（不可用）"
        case .api where settings.isAPIConfigured:
            return "自定义 AI API"
        case .api:
            return "自定义 AI API（未配置）"
        case .off:
            return "已关闭"
        case .auto:
            return "未选择引擎"
        }
    }

    // MARK: - 能力

    func summarize(session: TranscriptSession) async -> String? {
        guard isAvailable else { return nil }
        let parts = session.segments.map { segment -> String in
            if let translated = segment.displayTranslatedText {
                return "\(segment.originalText)\n译文：\(translated)"
            }
            return segment.originalText
        }
        return await run { provider in
            try await provider.summarize(parts.joined(separator: "\n"))
        }
    }

    func polish(segment: CaptionSegment, targetLanguage: String? = nil) async -> String? {
        guard isAvailable, let text = segment.translatedText else { return nil }
        let identifier = targetLanguage ?? settings.targetLanguageIdentifier
        let languageName = LanguageOption.option(for: identifier).displayName
        return await run { provider in
            try await provider.polish(text, targetLanguage: languageName)
        }
    }

    /// AI 语义断句：返回按顺序排列的完整句子；模型改写原文时返回 nil
    func segmentSentences(_ text: String) async -> [String]? {
        guard isAvailable else { return nil }
        guard let content = await run({ provider in
            try await provider.segment(text)
        }) else { return nil }
        return AISegmentationParser.lines(from: content, original: text)
    }

    // MARK: - 私有

    private var resolvedMode: AIProviderMode {
        switch settings.aiProviderMode {
        case .auto:
            if Self.appleIntelligenceAvailable {
                return .apple
            }
            return settings.isAPIConfigured ? .api : .off
        case .apple, .api, .off:
            return settings.aiProviderMode
        }
    }

    private func run(_ operation: (any TextAIProviding) async throws -> String?) async -> String? {
        do {
            switch resolvedMode {
            case .apple:
                guard Self.appleIntelligenceAvailable, let provider = appleProviderValue() else { return nil }
                return try await operation(provider)
            case .api:
                guard settings.isAPIConfigured else { return nil }
                let provider = OpenAICompatibleProvider(config: .init(
                    endpoint: settings.aiAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: settings.apiKey,
                    model: settings.aiAPIModel.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                return try await operation(provider)
            case .auto, .off:
                return nil
            }
        } catch {
            #if DEBUG
            print("[AIService] 请求失败：\(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func appleProviderValue() -> (any TextAIProviding)? {
        #if canImport(FoundationModels)
        if let provider = appleProviderStorage as? AppleIntelligenceProvider {
            return provider
        }
        let provider = AppleIntelligenceProvider()
        appleProviderStorage = provider
        return provider
        #else
        return nil
        #endif
    }
}