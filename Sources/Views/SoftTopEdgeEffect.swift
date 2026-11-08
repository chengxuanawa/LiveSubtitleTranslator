import SwiftUI

/// iOS 26 的柔和顶部滚动边缘效果（scroll edge effect），不显示灰色材质条。
struct SoftTopEdgeEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollEdgeEffectStyle(.soft, for: .top)
    }
}

extension View {
    func softTopEdgeEffect() -> some View {
        modifier(SoftTopEdgeEffectModifier())
    }
}