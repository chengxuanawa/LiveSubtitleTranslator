import AVFoundation
import Foundation
import Network

/// 接收广播扩展发来的系统音频（localhost TCP），转成 AVAudioPCMBuffer 交给识别服务。
@MainActor
final class SystemAudioStreamServer {

    private(set) var isReceivingAudio = false

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onBroadcastHeartbeat: (() -> Void)?
    var onStreamEnded: (() -> Void)?
    var onStreamStalled: (() -> Void)?
    var onReconnectTimedOut: (() -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var disconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var listenerRetryTask: Task<Void, Never>?
    private var lastPacketAt: ContinuousClock.Instant?
    private var receiveBuffer = Data()
    private var audioFormat: AVAudioFormat?
    /// 调用方是否希望持续监听；用于监听器进入 waiting/failed 后自动重建
    private var shouldListen = false
    /// App 是否在前台：后台被挂起时不能把“暂时收不到包”误判成共享结束
    private var isAppActive = true

    /// 开始监听广播连接；返回是否成功
    @discardableResult
    func start() -> Bool {
        shouldListen = true
        if let listener {
            // 监听器可能已被系统取消/失败，这种情况下要重建，否则会一直“假等待”
            switch listener.state {
            case .failed, .cancelled, .waiting:
                clearListener()
            default:
                return true
            }
        }
        guard let port = NWEndpoint.Port(rawValue: AudioStreamProtocol.port) else { return false }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .failed, .waiting:
                        // .waiting 通常是端口被占用/系统暂停监听：此时并没有真正接收连接，
                        // 必须取消后重建，否则界面会一直停在“等待广播”。
                        self.clearListener()
                        self.scheduleListenerRetry()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "system.audio.listener"))
            self.listener = listener
            return true
        } catch {
            scheduleListenerRetry()
            return false
        }
    }

    func stop() {
        shouldListen = false
        cancelTransportTimers()
        clearConnection()
        clearListener()
    }

    /// 广播是否仍在发送心跳或音频；用于前台恢复时判断连接是否真的存活
    var hasRecentActivity: Bool {
        guard let lastPacketAt else { return false }
        return lastPacketAt.duration(to: ContinuousClock().now) < .seconds(AudioStreamProtocol.streamTimeout)
    }

    /// 重建监听器：用于 App 从后台恢复。系统挂起后旧的 NWListener
    /// 可能仍显示 ready，但实际上已经不再接受连接，只能整体重建。
    func restartListener() {
        cancelTransportTimers()
        clearConnection()
        clearListener()
        start()
        if isAppActive {
            scheduleReconnectTimeout(after: .seconds(8))
        }
    }

    private func cancelTransportTimers() {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        disconnectTask?.cancel()
        disconnectTask = nil
    }

    private func clearConnection() {
        watchdogTask?.cancel()
        watchdogTask = nil
        let oldConnection = connection
        connection = nil
        oldConnection?.cancel()
        receiveBuffer.removeAll()
        lastPacketAt = nil
        isReceivingAudio = false
    }

    private func clearListener() {
        let oldListener = listener
        listener = nil
        oldListener?.cancel()
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        // 回到前台后重新启动看门狗；不能刷新 lastPacketAt，
        // 否则前台恢复逻辑会把已经失活的旧连接误判成刚刚收过包。
        if active, connection != nil {
            startWatchdog()
        }
    }

    // MARK: - 私有

    private func accept(_ connection: NWConnection) {
        disconnectTask?.cancel()
        disconnectTask = nil
        clearConnection()
        self.connection = connection
        lastPacketAt = ContinuousClock().now
        startWatchdog()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                // 旧连接被取消时不能影响新连接，否则会把刚建立的流一起断掉
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.disconnectTask?.cancel()
                    self.disconnectTask = nil
                    // 就绪和心跳只能证明连接存在，收到有效 PCM 后才标记为有音频。
                    self.lastPacketAt = ContinuousClock().now
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
                guard self.connection === connection else { return }
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
            // Data 被删除前缀后 startIndex 可能不再是 0，必须用当前索引计算范围，
            // 否则 removeSubrange 会因越界直接触发 SIGTRAP（历史上的闪退根因）
            let start = receiveBuffer.startIndex
            let headerEnd = start + 4
            // 手动按大端解析长度，避免 Data 内部指针未对齐时的 UInt32 未对齐读取
            let length = Int(receiveBuffer[start..<headerEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            // 长度为 0 是心跳包：只刷新存活时间，不产生音频
            if length == 0 {
                receiveBuffer.removeSubrange(start..<headerEnd)
                lastPacketAt = ContinuousClock().now
                onBroadcastHeartbeat?()
                continue
            }
            guard length <= AudioStreamProtocol.maxPacketBytes else {
                receiveBuffer.removeAll()
                return
            }
            guard receiveBuffer.count >= 4 + length else { return }
            let packetEnd = headerEnd + length
            let payload = receiveBuffer.subdata(in: headerEnd..<packetEnd)
            receiveBuffer.removeSubrange(start..<packetEnd)
            // 扩展明确告知广播已结束：立即收尾，不再等宽限期
            if payload == AudioStreamProtocol.stopPayload {
                handleStreamStopped()
                return
            }
            deliver(payload)
        }
    }

    private func deliver(_ payload: Data) {
        guard !payload.isEmpty, payload.count.isMultiple(of: MemoryLayout<Int16>.size) else { return }
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
        // 直接按字节拷贝到 Int16 声道，避免把可能未对齐的 Data 指针绑定成 Int16
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(channel, base, Int(frameCount) * MemoryLayout<Int16>.size)
            }
        }
        lastPacketAt = ContinuousClock().now
        isReceivingAudio = true
        onAudioBuffer?(buffer)
    }

    private func handleDisconnect() {
        clearConnection()
        if isAppActive {
            scheduleReconnectTimeout(after: .seconds(6))
        }
        onStreamStalled?()
    }

    /// 广播扩展明确发送了结束标记时立即收尾。
    private func handleStreamStopped() {
        disconnectTask?.cancel()
        disconnectTask = nil
        clearConnection()
        onStreamEnded?()
    }

    private func scheduleReconnectTimeout(after delay: Duration) {
        disconnectTask?.cancel()
        disconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.connection == nil else { return }
            self.disconnectTask = nil
            guard self.isAppActive else { return }
            self.onReconnectTimedOut?()
        }
    }

    /// 监听器进入 waiting/failed 后自动重建；广播扩展会持续重连，端口恢复后即可接上
    private func scheduleListenerRetry() {
        guard shouldListen, listenerRetryTask == nil else { return }
        listenerRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.listenerRetryTask = nil
            guard self.shouldListen, self.listener == nil else { return }
            _ = self.start()
        }
    }

    /// 连接可能“看起来还活着”但主 App 已被挂起，收不到任何包。
    /// 心跳超时后主动断开并重建监听器，让扩展下一轮重连重新握手。
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.connection != nil else { return }
                guard let lastPacketAt = self.lastPacketAt else { continue }
                if lastPacketAt.duration(to: ContinuousClock().now) >= .seconds(AudioStreamProtocol.streamTimeout) {
                    if self.isAppActive {
                        // 前台仍收不到心跳：旧监听器可能已失效，整体重建
                        self.onStreamStalled?()
                        self.restartListener()
                    } else {
                        // 后台被挂起时不能判定共享结束，等回到前台再校验
                        self.handleDisconnect()
                    }
                    return
                }
            }
        }
    }
}
