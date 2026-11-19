import ReplayKit
import SwiftUI
import UIKit

/// 程序化触发系统广播选择器：`RPSystemBroadcastPickerView` 没有公开的弹出方法，
/// 这里找到其内部的 UIButton 并发送点击事件，外层即可使用自定义样式的按钮。
final class BroadcastPickerTrigger {
    static let shared = BroadcastPickerTrigger()
    weak var picker: RPSystemBroadcastPickerView?

    /// 触发系统面板；选择器必须已挂到窗口上，否则推迟一帧再试，避免在已移除的视图上点击
    func trigger(canRetry: Bool = true) {
        guard let picker else { return }
        guard picker.window != nil else {
            guard canRetry else { return }
            DispatchQueue.main.async { [weak self] in
                self?.trigger(canRetry: false)
            }
            return
        }
        guard let button = Self.findButton(in: picker) else { return }
        button.sendActions(for: .touchUpInside)
    }

    private static func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}

/// 系统广播选择器：点击后弹出系统“广播”选择器，选择本 App 的扩展即可开始共享。
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = preferredExtension
        BroadcastPickerTrigger.shared.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
