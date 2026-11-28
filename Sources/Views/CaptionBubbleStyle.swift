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
    /// 应用统一的字幕气泡背景与描边
    func captionBubbleBackground(speakerLabel: String?) -> some View {
        background(CaptionBubbleBackground(speakerLabel: speakerLabel))
    }
}
