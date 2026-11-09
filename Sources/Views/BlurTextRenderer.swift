import SwiftUI

/// 字符级模糊渐显渲染器：progress 从 0 到 1 时，文字由模糊透明过渡到完全清晰。
/// 相比 `.blur()` 修饰符，它只接管绘制、不额外生成离屏图层，适合在列表中逐条播放入场。
struct BlurTextRenderer: TextRenderer, Animatable {

    /// 入场进度：0 = 模糊且透明，1 = 完全清晰
    var progress: Double
    /// 起始模糊半径
    var maxBlur: CGFloat = 4

    /// TextRenderer 继承自 Animatable，暴露进度后即可被 withAnimation 平滑插值
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// 给模糊后的字形预留绘制空间，避免边缘被裁掉
    var displayPadding: EdgeInsets {
        EdgeInsets(top: maxBlur * 2, leading: maxBlur * 2, bottom: maxBlur * 2, trailing: maxBlur * 2)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // 动画结束后按默认方式绘制，不再生成任何滤镜，长列表滚动零额外开销
        guard progress < 0.999 else {
            for line in layout {
                context.draw(line)
            }
            return
        }

        let clamped = min(max(progress, 0), 1)
        var blurContext = context
        blurContext.opacity = clamped
        blurContext.addFilter(.blur(radius: maxBlur * CGFloat(1 - clamped)))

        // 整行一起去模糊：滤镜只作用于少量绘制命令，
        // 比逐字符叠滤镜轻得多，避免入场时掉帧
        for line in layout {
            blurContext.draw(line)
        }
    }
}
