import Foundation

/// 主 App 与广播扩展之间的本地音频流协议（localhost TCP，无需 App Group）
enum AudioStreamProtocol {
    /// 本地环回端口
    static let port: UInt16 = 51234
    /// 统一音频格式：44.1 kHz / 16-bit / 单声道
    static let sampleRate: Double = 44100
    /// 单包长度上限（字节）
    static let maxPacketBytes = 1 << 20
}