import CoreGraphics

/// 画中画字幕窗口形状
enum PiPShape: String, CaseIterable, Identifiable {
    /// 默认 16:9 横向窗口
    case standard
    /// 长条状，适合单行字幕
    case strip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "默认"
        case .strip: return "长条"
        }
    }

    /// 渲染画布尺寸，决定系统画中画窗口的宽高比
    var renderSize: CGSize {
        switch self {
        // 16:9，接近系统默认画中画比例
        case .standard: return CGSize(width: 640, height: 360)
        // 7:1 的细长条；比例决定窗口形状，画布分辨率决定清晰度，
        // 用较高分辨率避免小窗放大后文字发虚
        case .strip: return CGSize(width: 2100, height: 300)
        }
    }
}
