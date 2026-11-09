import Foundation

/// 一条字幕片段：原始识别文本 + 翻译结果 + 时间信息
struct CaptionSegment: Identifiable, Codable, Hashable {
    let id: UUID
    /// 语音识别得到的原始文本
    let originalText: String
    /// 翻译后的文本（翻译尚未完成时为 nil）
    var translatedText: String?
    /// AI 润色后的译文（未润色时为 nil）
    var polishedText: String?
    /// 是否已播放过入场动画；流式追加与列表复用时不会再播一次
    var hasAnimated: Bool

    /// 展示用译文：优先润色结果
    var displayTranslatedText: String? { polishedText ?? translatedText }
    /// 语音开始时间（相对本次会话起点，单位：秒）
    let startTime: TimeInterval
    /// 生成时间
    let createdAt: Date

    init(
        id: UUID = UUID(),
        originalText: String,
        translatedText: String? = nil,
        polishedText: String? = nil,
        startTime: TimeInterval,
        createdAt: Date = .now,
        hasAnimated: Bool = false
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.polishedText = polishedText
        self.startTime = startTime
        self.createdAt = createdAt
        self.hasAnimated = hasAnimated
    }

    private enum CodingKeys: String, CodingKey {
        case id, originalText, translatedText, polishedText, startTime, createdAt, hasAnimated
    }

    /// 兼容旧记录：没有 hasAnimated 字段时视为已播放，历史列表不会重播动画
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalText = try container.decode(String.self, forKey: .originalText)
        translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
        polishedText = try container.decodeIfPresent(String.self, forKey: .polishedText)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        hasAnimated = try container.decodeIfPresent(Bool.self, forKey: .hasAnimated) ?? true
    }
}