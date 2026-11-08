import Foundation

/// 音频来源
enum AudioSourceMode: String, CaseIterable {
    /// 麦克风直接收音
    case microphone
    /// 通过广播扩展捕获系统音频（可转写其他 App 播放的声音）
    case systemAudio

    var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统共享音频"
        }
    }
}