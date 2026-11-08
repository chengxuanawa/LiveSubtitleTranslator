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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.originalText)
                            .font(.caption)
                            .lineLimit(2)
                        if let translated = context.state.translatedText {
                            Text(translated)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                Text(context.state.translatedText ?? context.state.originalText)
                    .font(.caption2)
                    .lineLimit(1)
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