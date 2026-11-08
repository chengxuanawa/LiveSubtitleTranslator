import ReplayKit
import SwiftUI

/// 系统广播选择器：点击后弹出系统"广播"选择器，选择本 App 的扩展即可开始共享。
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String
    var showsMicrophoneButton = false

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = showsMicrophoneButton
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}