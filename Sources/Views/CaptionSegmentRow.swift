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
    /// 入场动画开始时回调，用于把 hasAnimated 写回数据源，避免列表复用重播
    var onReveal: (() -> Void)? = nil
    /// 单击原文单词时回调（单词, 所在句子）
    var onWordTap: ((_ word: String, _ sentence: String) -> Void)? = nil
    /// 实验性说话人标签，如「说话人 1」
    var speakerLabel: String? = nil

    /// 原文 / 译文的模糊渐显进度
    @State private var originalProgress: Double
    @State private var translatedProgress: Double
    /// 本次实例是否已经触发过入场动画
    @State private var didTriggerReveal = false

    init(
        segment: CaptionSegment,
        showTranslationFailure: Bool = false,
        showsPolishedHighlight: Bool = false,
        onRetryTranslation: (() -> Void)? = nil,
        onPolishRequest: (() -> Void)? = nil,
        onReveal: (() -> Void)? = nil,
        onWordTap: ((_ word: String, _ sentence: String) -> Void)? = nil,
        speakerLabel: String? = nil
    ) {
        self.segment = segment
        self.showTranslationFailure = showTranslationFailure
        self.showsPolishedHighlight = showsPolishedHighlight
        self.onRetryTranslation = onRetryTranslation
        self.onPolishRequest = onPolishRequest
        self.onReveal = onReveal
        self.onWordTap = onWordTap
        self.speakerLabel = speakerLabel
        // 新卡片以不可见文字参与布局，等一帧后再模糊淡入；
        // 历史或已播放过的卡片直接以最终状态显示
        _originalProgress = State(initialValue: segment.hasAnimated ? 1 : 0)
        _translatedProgress = State(initialValue: segment.hasAnimated ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speakerLabel {
                HStack(spacing: 5) {
                    Circle()
                        .fill(speakerTint)
                        .frame(width: 6, height: 6)
                    Text(speakerLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            WordFlowText(
                text: segment.originalText,
                font: .body,
                blurProgress: originalProgress,
                onWordTap: { word in
                    onWordTap?(word, segment.originalText)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: CGFloat(max(0, 1 - originalProgress)) * 10)

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
                            .textRenderer(BlurTextRenderer(progress: translatedProgress))
                            .offset(y: CGFloat(max(0, 1 - translatedProgress)) * 8)
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
        .captionBubbleBackground()
        .padding(.horizontal, 12)
        .onChange(of: segment.displayTranslatedText) { oldValue, newValue in
            // 译文是异步回填的：首次出现时同样播一遍模糊 + 上浮动画
            guard oldValue == nil, newValue != nil else { return }
            translatedProgress = 0
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 16_000_000)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    translatedProgress = 1
                }
            }
        }
        .task(id: segment.id) {
            // 离屏取消后重新出现时，直接落到最终状态，避免文字停在透明
            guard !segment.hasAnimated, !didTriggerReveal else {
                if originalProgress < 1 { originalProgress = 1 }
                if translatedProgress < 1 { translatedProgress = 1 }
                return
            }
            didTriggerReveal = true
            // 稍等一帧，让卡片插入动画先开始，再让文字模糊淡入
            try? await Task.sleep(nanoseconds: 60_000_000)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                originalProgress = 1
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(0.12)) {
                translatedProgress = 1
            }
            // 动画播完再回写标记，避免列表在动画首帧重算造成卡顿
            try? await Task.sleep(nanoseconds: 750_000_000)
            if originalProgress < 1 { originalProgress = 1 }
            if translatedProgress < 1 { translatedProgress = 1 }
            onReveal?()
        }
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

    /// 说话人标签颜色：按编号轮换，方便区分两个人
    private var speakerTint: Color {
        guard let number = speakerLabel?.compactMap(\.wholeNumberValue).last else { return .secondary }
        switch number % 3 {
        case 1: return .blue
        case 2: return .orange
        default: return .green
        }
    }
}
