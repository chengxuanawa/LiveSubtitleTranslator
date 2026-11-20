import ReplayKit
import SwiftUI
import UIKit

/// 程序化触发系统广播选择器：`RPSystemBroadcastPickerView` 没有公开的弹出方法，
/// 这里找到其内部的 UIButton 并发送点击事件，外层即可使用自定义样式的按钮。
final class BroadcastPickerTrigger {
    static let shared = BroadcastPickerTrigger()
    weak var picker: RPSystemBroadcastPickerView?
    /// 正在唤起系统面板：冷却期内忽略重复点击，避免面板延迟时多次点击排队、之后一起弹出
    private var isTriggering = false

    /// 触发系统共享面板；选择器或内部按钮尚未就绪时在随后几帧内自动重试
    func trigger() {
        guard !isTriggering else { return }
        isTriggering = true
        attempt(remaining: 12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isTriggering = false
        }
    }

    private func attempt(remaining: Int) {
        guard remaining > 0 else { return }
        guard let picker,
              picker.window != nil,
              picker.bounds.width > 0,
              let button = Self.findButton(in: picker) else {
            // 选择器可能刚被 SwiftUI 重建，等下一帧再试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.attempt(remaining: remaining - 1)
            }
            return
        }
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
