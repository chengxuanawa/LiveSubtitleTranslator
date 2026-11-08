import Foundation

/// 一次完整的字幕会话（结束后保存，可在记录页回看）
struct TranscriptSession: Identifiable, Codable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let sourceLanguageIdentifier: String
    let targetLanguageIdentifier: String
    var segments: [CaptionSegment]
    /// AI 摘要（生成后随会话一起保存）
    var summary: String?
    /// 录制地点名（定位成功时写入，用于「位置」标题）
    var locationName: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        sourceLanguageIdentifier: String,
        targetLanguageIdentifier: String,
        segments: [CaptionSegment],
        summary: String? = nil,
        locationName: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sourceLanguageIdentifier = sourceLanguageIdentifier
        self.targetLanguageIdentifier = targetLanguageIdentifier
        self.segments = segments
        self.summary = summary
        self.locationName = locationName
    }

    /// 会话时长
    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// 导出的纯文本内容（用于分享 / 拷贝）
    func exportText() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = [
            "会话时间：\(dateFormatter.string(from: startedAt))",
            "识别语言：\(sourceLanguageIdentifier) → \(targetLanguageIdentifier)",
        ]
        if let summary {
            lines.append("")
            lines.append("AI 摘要：")
            lines.append(summary)
        }
        lines.append("")
        for segment in segments {
            lines.append("[\(Self.timestamp(segment.startTime))] \(segment.originalText)")
            if let translated = segment.displayTranslatedText {
                lines.append("    \(translated)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}