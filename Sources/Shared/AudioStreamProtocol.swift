import Foundation

/// 主 App 与广播扩展之间的本地音频流协议（localhost TCP，无需 App Group）
enum AudioStreamProtocol {
    /// 本地环回端口
    static let port: UInt16 = 51234
    /// 统一音频格式：44.1 kHz / 16-bit / 单声道
    static let sampleRate: Double = 44100
    /// 单包长度上限（字节）
    static let maxPacketBytes = 1 << 20
    /// 广播扩展心跳间隔：长度为 0 的包只用于证明广播仍存活
    static let heartbeatInterval: TimeInterval = 1
    /// 超过该时间没有收到任何包（音频或心跳）即认为连接已失效
    static let streamTimeout: TimeInterval = 5
    /// 广播结束标记：用户停止共享时由扩展立即发送，主 App 收到后立刻收尾
    /// 不使用长度 0（那是心跳），用固定 4 字节负载与音频区分
    static let stopPayload = Data("STOP".utf8)
    static let stopPacket = Data([0, 0, 0, 4]) + stopPayload
}
