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
        createdAt: Date = .now
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.polishedText = polishedText
        self.startTime = startTime
        self.createdAt = createdAt
    }
}