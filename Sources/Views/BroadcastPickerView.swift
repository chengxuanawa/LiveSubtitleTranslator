import ReplayKit
import SwiftUI
import UIKit

/// 程序化触发系统广播选择器：`RPSystemBroadcastPickerView` 没有公开的弹出方法，
/// 这里找到其内部的 UIButton 并发送点击事件，外层即可使用自定义样式的按钮。
final class BroadcastPickerTrigger {
    static let shared = BroadcastPickerTrigger()
    weak var picker: RPSystemBroadcastPickerView?

    func trigger() {
        guard let picker, let button = Self.findButton(in: picker) else { return }
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

/// 系统广播选择器：点击后弹出系统"广播"选择器，选择本 App 的扩展即可开始共享。
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String
    var showsMicrophoneButton = false

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = showsMicrophoneButton
        BroadcastPickerTrigger.shared.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}