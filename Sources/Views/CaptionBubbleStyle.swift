import SwiftUI
import UIKit

/// 字幕气泡统一背景：secondary 圆角底 + 细描边，实时字幕与历史记录共用
struct CaptionBubbleBackground: View {
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
    }
}

extension View {
    /// 应用统一的字幕气泡背景与描边
    func captionBubbleBackground(cornerRadius: CGFloat = 12) -> some View {
        background(CaptionBubbleBackground(cornerRadius: cornerRadius))
    }
}
