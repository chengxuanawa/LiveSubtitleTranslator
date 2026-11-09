import SwiftUI
import UIKit

/// 单条字幕行：原文 + 译文（长按可拷贝 / AI 润色）
struct CaptionSegmentRow: View {
    let segment: CaptionSegment
    /// 译文生成失败时展示提示与重试按钮
    var showTranslationFailure = false
    /// 重试翻译回调
    var onRetryTranslation: (() -> Void)? = nil
    /// 可选的 AI 润色回调；为 nil 时不显示润色按钮
    var onPolishRequest: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.originalText)
                .font(.body)

            if let translated = segment.displayTranslatedText {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.top, 2)
                    Text(translated)
                        .font(.subheadline)
                        .foregroundStyle(segment.polishedText == nil ? .secondary : .primary)
                }
            } else if showTranslationFailure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("译文未生成")
                    Button {
                        onRetryTranslation?()
                    } label: {
                        Text("重试")
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .contextMenu {
            Button {
                UIPasteboard.general.string = segment.originalText
            } label: {
                Label("拷贝原文", systemImage: "doc.on.doc")
            }
            if let translated = segment.displayTranslatedText {
                Button {
                    UIPasteboard.general.string = translated
                } label: {
                    Label("拷贝译文", systemImage: "character.bubble")
                }
                if let onPolishRequest {
                    Button {
                        onPolishRequest()
                    } label: {
                        Label(
                            segment.polishedText == nil ? "AI 润色译文" : "重新润色",
                            systemImage: "sparkles"
                        )
                    }
                }
            } else if showTranslationFailure, let onRetryTranslation {
                Button {
                    onRetryTranslation()
                } label: {
                    Label("重试翻译", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}