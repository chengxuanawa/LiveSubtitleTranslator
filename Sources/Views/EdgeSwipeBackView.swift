import SwiftUI
import UIKit

/// 在左边缘安装系统级边缘手势识别器。
///
/// SwiftUI 的 `.defersSystemGestures(on: .leading)` 只负责请求系统延后自己的
/// 边缘手势；如果 App 没有真正参与竞争的手势，第一次滑动只会显示系统提示而
/// 不会执行返回。这里把识别器挂到窗口根视图，避免用透明遮罩挡住页面内容。
struct EdgeSwipeBackView: UIViewRepresentable {
    let isEnabled: Bool
    let onSwipeBack: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onSwipeBack: onSwipeBack)
    }

    func makeUIView(context: Context) -> EdgeSwipeBackHostView {
        let view = EdgeSwipeBackHostView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.updateWindow(window)
        }
        return view
    }

    func updateUIView(_ uiView: EdgeSwipeBackHostView, context: Context) {
        context.coordinator.update(isEnabled: isEnabled, onSwipeBack: onSwipeBack)
        context.coordinator.updateWindow(uiView.window)
    }

    static func dismantleUIView(_ uiView: EdgeSwipeBackHostView, coordinator: Coordinator) {
        uiView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var isEnabled: Bool
        var onSwipeBack: () -> Void

        private weak var window: UIWindow?
        private var recognizer: UIScreenEdgePanGestureRecognizer?

        init(isEnabled: Bool, onSwipeBack: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onSwipeBack = onSwipeBack
        }

        func update(isEnabled: Bool, onSwipeBack: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onSwipeBack = onSwipeBack
            refreshRecognizer()
        }

        func updateWindow(_ window: UIWindow?) {
            self.window = window
            refreshRecognizer()
        }

        private func refreshRecognizer() {
            guard isEnabled, let window = window else {
                removeRecognizer()
                return
            }

            let targetView = window.rootViewController?.view ?? window
            if let recognizer = recognizer, recognizer.view === targetView {
                return
            }
            removeRecognizer()

            let recognizer = UIScreenEdgePanGestureRecognizer(
                target: self,
                action: #selector(handlePan(_:))
            )
            recognizer.edges = .left
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            targetView.addGestureRecognizer(recognizer)

            self.recognizer = recognizer
        }

        func detach() {
            removeRecognizer()
            window = nil
        }

        private func removeRecognizer() {
            if let recognizer = recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
        }

        @objc private func handlePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard isEnabled else { return }
            guard let window = window, window.isKeyWindow else { return }
            guard window.rootViewController?.presentedViewController == nil else { return }
            guard let view = recognizer.view else { return }

            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)

            guard recognizer.state == .ended else { return }
            let hasEnoughDistance = translation.x > 56
            let hasEnoughMomentum = translation.x > 28 && velocity.x > 450
            let isMostlyHorizontal = abs(translation.y) < max(56, translation.x * 0.8)

            guard (hasEnoughDistance || hasEnoughMomentum), isMostlyHorizontal else { return }
            onSwipeBack()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let translation = pan.translation(in: pan.view)
            if abs(translation.x) > abs(translation.y) {
                return translation.x > 0
            }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
        }
    }
}

/// 只负责观察自己何时进入/离开窗口；识别器实际挂在窗口根视图上。
@MainActor
final class EdgeSwipeBackHostView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}
