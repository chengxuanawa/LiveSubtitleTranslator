import SwiftUI

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

/// 说话人小胶囊：彩色圆点 / 图标 + 标签
struct SpeakerChip: View {
    let label: String
    /// 传入图标后替代圆点，用于实时气泡
    var icon: String? = nil

    private var tint: Color {
        SpeakerPalette.tint(for: label)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
        )
    }
}
