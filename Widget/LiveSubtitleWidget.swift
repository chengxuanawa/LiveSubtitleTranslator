import ActivityKit
import SwiftUI
import WidgetKit

/// Widget 扩展入口：提供实时字幕的锁屏 / 灵动岛界面
@main
struct LiveSubtitleWidgetBundle: WidgetBundle {
    var body: some Widget {
        LiveCaptionLiveActivity()
    }
}

struct LiveCaptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveCaptionAttributes.self) { context in
            LockScreenCaptionView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "captions.bubble")
                        .foregroundStyle(.yellow)
                }
                DynamicIslandExpandedRegion(.center) {
                    // 灵动岛不展示说话内容，只显示状态与语言对
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在聆听…")
                            .font(.caption.weight(.medium))
                        Text(context.state.languagePair)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                // 不展示字幕文本，仅保留聆听中的波形标识
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: 80, alignment: .trailing)
            } minimal: {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.yellow)
            }
            .keylineTint(.yellow)
        }
    }
}

/// 锁屏卡片视图
private struct LockScreenCaptionView: View {
    let state: LiveCaptionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.yellow)
                Text(state.languagePair)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("实时字幕")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(state.originalText)
                .font(.subheadline)
                .lineLimit(3)
            if let translated = state.translatedText {
                Text(translated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}