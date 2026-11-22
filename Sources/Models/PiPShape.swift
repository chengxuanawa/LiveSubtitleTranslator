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

    /// 原文字号占画布高度的比例（iPad 的大窗口需要更克制的字号）
    var originalFontRatio: CGFloat {
        switch self {
        case .standard: return 0.115
        case .strip: return 0.21
        }
    }

    /// 译文字号占画布高度的比例
    var translatedFontRatio: CGFloat {
        switch self {
        case .standard: return 0.095
        case .strip: return 0.17
        }
    }

    /// 原文最多显示的行数；超出后自动滚动显示最新内容
    var originalMaxLines: Int {
        switch self {
        case .standard: return 2
        // 长条虽然很宽，但长句仍可能放不下：允许换到第二行
        case .strip: return 2
        }
    }

    /// 译文最多显示的行数；超出后自动滚动显示最新内容
    var translatedMaxLines: Int {
        switch self {
        case .standard: return 2
        // 长条高度有限，译文保持一行，优先保证原文两行
        case .strip: return 1
        }
    }
}
