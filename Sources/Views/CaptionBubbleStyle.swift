import SwiftUI
import UIKit

/// 字幕气泡统一背景：secondary 圆角底 + 细描边，实时字幕与历史记录共用
struct CaptionBubbleBackground: View {
    let speakerLabel: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tint = speakerLabel.map { SpeakerPalette.tint(for: $0).opacity(0.16) } ?? .clear
        shape
            .fill(Color(.secondarySystemBackground))
            .overlay(shape.fill(tint))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
    }
}

extension View {
    /// 气泡保持满宽，标签沿上边线分边摆放，不占正文布局空间。
    func captionBubbleStyle(speakerLabel: String?) -> some View {
        let badgeAlignment: Alignment = SpeakerPalette.isRightAligned(label: speakerLabel) ? .topTrailing : .topLeading
        return background(CaptionBubbleBackground(speakerLabel: speakerLabel))
            .overlay(alignment: badgeAlignment) {
                if let speakerLabel, SpeakerPalette.index(from: speakerLabel) != nil {
                    SpeakerEdgeBadge(label: speakerLabel)
                        .padding(.horizontal, 13)
                        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                        .allowsHitTesting(false)
                }
            }
    }
}
