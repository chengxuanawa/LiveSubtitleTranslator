import SwiftUI
import UIKit

/// 单条字幕行：原文 + 译文（长按可拷贝 / AI 润色）
struct CaptionSegmentRow: View {
    let segment: CaptionSegment
    /// 译文生成失败时展示提示与重试按钮
    var showTranslationFailure = false
    /// 历史会话中给 AI 润色内容加彩色光效卡片
    var showsPolishedHighlight = false
    /// 重试翻译回调
    var onRetryTranslation: (() -> Void)? = nil
    /// 可选的 AI 润色回调；为 nil 时不显示润色按钮
    var onPolishRequest: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.originalText)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if let translated = segment.displayTranslatedText {
                if showsPolishedHighlight, segment.polishedText != nil {
                    polishedCard(translated)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 3)
                            .padding(.top, 2)
                        Text(translated)
                            .font(.subheadline)
                            .foregroundStyle(segment.polishedText == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    /// AI 润色内容卡片：彩色渐变描边 + 柔和彩色光晕
    private func polishedCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(
                    LinearGradient(
                        colors: [.cyan, .blue, .purple, .pink],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .purple, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("AI 润色")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.semibold))

                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.35),
                            Color.blue.opacity(0.25),
                            Color.purple.opacity(0.3),
                            Color.pink.opacity(0.3),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: 10)
                .padding(-3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.8),
                            Color.blue.opacity(0.5),
                            Color.purple.opacity(0.7),
                            Color.pink.opacity(0.8),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.purple.opacity(0.18), radius: 8, x: 0, y: 3)
    }
}