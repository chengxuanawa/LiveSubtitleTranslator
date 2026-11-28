import SwiftUI
import UIKit

/// 说话人配色与标签样式：按「说话人 N」的编号轮换颜色
enum SpeakerPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    /// 从标签中解析说话人序号
    static func index(from label: String?) -> Int? {
        guard let label, let range = label.range(of: "说话人 ") else { return nil }
        let digits = label[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    static func tint(for label: String?) -> Color {
        guard let index = index(from: label), index > 0 else { return .secondary }
        return colors[(index - 1) % colors.count]
    }

    /// 男声靠左、女声靠右；性别未知时按序号奇偶分边
    static func isRightAligned(label: String?) -> Bool {
        guard let label else { return false }
        if label.contains("女声") { return true }
        if label.contains("男声") { return false }
        guard let index = index(from: label) else { return false }
        return index % 2 == 0
    }
}

/// 嵌在气泡上沿的小标签，正文和译文都不需要另起一行。
struct SpeakerEdgeBadge: View {
    let label: String

    private var shortLabel: String {
        let prefix = "说话人 "
        guard label.hasPrefix(prefix) else { return label }
        return String(label.dropFirst(prefix.count))
    }

    var body: some View {
        let tint = SpeakerPalette.tint(for: label)
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(shortLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .fixedSize()
        .background {
            Capsule()
                .fill(Color(.secondarySystemBackground))
                .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.75))
        }
        .accessibilityLabel(Text(label))
    }
}
