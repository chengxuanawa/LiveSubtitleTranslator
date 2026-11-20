import SwiftUI
import UIKit

/// 首页顶部的柔和模糊过渡：内容滚到标题栏下方时逐渐虚化并淡出。
/// iOS 26 的 `scrollEdgeEffectStyle(.soft)` 在自定义 safeAreaInset 顶栏下不生效，
/// 这里用带渐变遮罩的 UIVisualEffectView 自绘一个等效效果。
struct SoftTopBlurView: UIViewRepresentable {

    func makeUIView(context: Context) -> SoftTopBlurUIView {
        SoftTopBlurUIView()
    }

    func updateUIView(_ uiView: SoftTopBlurUIView, context: Context) {}
}

/// 顶部向下逐渐减弱模糊的视图：上半部接近完全模糊，底部完全透明
final class SoftTopBlurUIView: UIView {

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let maskLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        blurView.isUserInteractionEnabled = false
        addSubview(blurView)

        // 渐变遮罩让模糊从顶部到底部逐渐消失，形成柔和的过渡带
        maskLayer.colors = [
            UIColor.black.cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.clear.cgColor,
        ]
        maskLayer.locations = [0, 0.55, 1]
        maskLayer.startPoint = CGPoint(x: 0.5, y: 0)
        maskLayer.endPoint = CGPoint(x: 0.5, y: 1)
        blurView.layer.mask = maskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurView.frame = bounds
        maskLayer.frame = blurView.bounds
        CATransaction.commit()
    }
}
