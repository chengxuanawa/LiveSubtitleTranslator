import ReplayKit
import SwiftUI
import UIKit

/// 系统广播选择器：直接把 `RPSystemBroadcastPickerView` 作为点击目标。
/// 不再通过遍历私有子按钮并 `sendActions` 程序化触发——该做法在 iOS 26 上
/// 可能直接导致 App 闪退，且点击失败时用户会误以为已开始共享。
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String
    /// 点击选择器时同步执行（用于提前启动本地监听与静音保活）
    var onTap: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = preferredExtension
        picker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(picker)

        // 不拦截系统按钮的触摸，仅旁路通知调用方做准备工作
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        container.addGestureRecognizer(tap)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?

        init(onTap: (() -> Void)?) {
            self.onTap = onTap
            super.init()
        }

        @objc func handleTap() {
            onTap?()
        }

        /// 与系统选择器内部的点击手势同时识别，保证保活/监听准备不会丢失
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
