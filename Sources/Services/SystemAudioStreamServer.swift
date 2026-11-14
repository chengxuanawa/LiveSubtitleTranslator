import AVFoundation
import Foundation
import Network

/// 接收广播扩展发来的系统音频（localhost TCP），转成 AVAudioPCMBuffer 交给识别服务。
@MainActor
final class SystemAudioStreamServer: ObservableObject {

    @Published private(set) var isWaitingForBroadcast = false
    @Published private(set) var isReceivingAudio = false

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStreamStarted: (() -> Void)?
    var onStreamEnded: (() -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var disconnectTask: Task<Void, Never>?
    private var receiveBuffer = Data()
    private var audioFormat: AVAudioFormat?

    /// 开始监听广播连接；返回是否成功
    @discardableResult
    func start() -> Bool {
        if let listener {
            // 监听器可能已被系统取消/失败，这种情况下要重建，否则会一直“假等待”
            switch listener.state {
            case .failed, .cancelled:
                self.listener = nil
            default:
                isWaitingForBroadcast = true
                return true
            }
        }
        guard let port = NWEndpoint.Port(rawValue: AudioStreamProtocol.port) else { return false }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else { return }
                    if case .failed = state {
                        listener.cancel()
                        self.listener = nil
                        self.isWaitingForBroadcast = false
                        self.isReceivingAudio = false
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "system.audio.listener"))
            self.listener = listener
            isWaitingForBroadcast = true
            return true
        } catch {
            isWaitingForBroadcast = false
            return false
        }
    }

    func stop() {
        disconnectTask?.cancel()
        disconnectTask = nil
        let oldConnection = connection
        connection = nil
        oldConnection?.cancel()
        let oldListener = listener
        listener = nil
        oldListener?.cancel()
        receiveBuffer.removeAll()
        isWaitingForBroadcast = false
        isReceivingAudio = false
    }

    // MARK: - 私有

    private func accept(_ connection: NWConnection) {
        disconnectTask?.cancel()
        disconnectTask = nil
        let oldConnection = self.connection
        self.connection = connection
        oldConnection?.cancel()
        receiveBuffer.removeAll()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                // 旧连接被取消时不能影响新连接，否则会把刚建立的流一起断掉
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.disconnectTask?.cancel()
                    self.disconnectTask = nil
                    self.isReceivingAudio = true
                    self.onStreamStarted?()
                    // NWConnection 必须先进入 ready 才能接收数据；在 start 后立刻
                    // 调用 receive 可能返回错误，把刚建立的广播误判为断开。
                    self.receiveNext()
                case .failed, .cancelled:
                    self.handleDisconnect()
                default:
                    break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "system.audio.connection"))
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                // 旧连接的接收回调可能晚于新连接到达，不能让它消费或断开新连接
                guard let self, let connection, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.consume(data)
                }
                if isComplete || error != nil {
                    self.handleDisconnect()
                    return
                }
                self.receiveNext()
            }
        }
    }

    /// 解析「4 字节长度前缀 + PCM 数据」的包
    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        while receiveBuffer.count >= 4 {
            let length = Int(receiveBuffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0, length <= AudioStreamProtocol.maxPacketBytes else {
                receiveBuffer.removeAll()
                return
            }
            guard receiveBuffer.count >= 4 + length else { return }
            let payload = receiveBuffer.subdata(in: 4..<(4 + length))
            receiveBuffer.removeSubrange(0..<(4 + length))
            deliver(payload)
        }
    }

    private func deliver(_ payload: Data) {
        if audioFormat == nil {
            audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: AudioStreamProtocol.sampleRate,
                channels: 1,
                interleaved: true
            )
        }
        guard let format = audioFormat else { return }
        let frameCount = AVAudioFrameCount(payload.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frameCount
        payload.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress {
                channel.update(from: base, count: Int(frameCount))
            }
        }
        onAudioBuffer?(buffer)
    }

    private func handleDisconnect() {
        guard connection != nil else { return }
        let oldConnection = connection
        connection = nil
        oldConnection?.cancel()
        isReceivingAudio = false
        // 广播扩展断线后会自动重连，先留出宽限期；只有持续没有新连接才视为共享结束
        disconnectTask?.cancel()
        disconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.connection == nil else { return }
            self.disconnectTask = nil
            self.onStreamEnded?()
        }
    }
}
