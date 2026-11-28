import AVFoundation
import Network
import OSLog
import ReplayKit

/// 广播上传扩展：捕获系统音频（其他 App 播放的声音）并转发给主 App。
/// 仅负责转发，不做识别；音频统一转换为 44.1 kHz / 16-bit / 单声道，经 localhost TCP 发送。
final class SampleHandler: RPBroadcastSampleHandler {

    private let queue = DispatchQueue(label: "com.example.livesubtitletranslator.broadcast.audio")
    // 广播状态和连接的修改集中在 queue 上。
    private var connection: NWConnection?
    private var isConnected = false
    private var isBroadcasting = false
    private var reconnectScheduled = false
    private var heartbeatScheduled = false
    private var appAudioConverter = BroadcastAudioConverter()
    private var microphoneConverter = BroadcastAudioConverter()
    private let pendingAudio = DispatchSemaphore(value: 48)
    private let logger = Logger(subsystem: "com.example.sublingo.broadcast", category: "Audio")
    /// ReplayKit 串行调用采样与广播生命周期回调。
    private var hasLoggedCopyFailure = false
    /// 由网络队列读写，与转换器一起重置。
    private var hasLoggedConversionFailure = false
    /// 断线期间暂存的音频包：重连成功后立即补发，避免每次重连丢开头音频
    private var pendingPackets: [Data] = []
    /// 最多暂存的音频包数量（约 5 秒）
    private static let maxPendingPackets = 250

    // MARK: - 广播生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        hasLoggedCopyFailure = false
        queue.async { [weak self] in
            guard let self else { return }
            self.isBroadcasting = true
            self.resetConverters()
            self.connect()
        }
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {
        queue.async { [weak self] in
            guard let self, self.isBroadcasting else { return }
            self.resetConverters()
            if self.connection == nil {
                self.connect()
            }
        }
    }

    override func broadcastFinished() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isBroadcasting = false
            self.reconnectScheduled = false
            self.heartbeatScheduled = false
            self.pendingPackets.removeAll()
            let oldConnection = self.connection
            self.connection = nil
            self.isConnected = false
            guard let oldConnection else { return }
            // 立即通知主 App 共享已停止，避免它等心跳超时才收尾
            oldConnection.send(content: AudioStreamProtocol.stopPacket, completion: .contentProcessed { _ in
                oldConnection.cancel()
            })
            // 兜底：发送回调异常时也要在短时间内释放连接
            self.queue.asyncAfter(deadline: .now() + 0.8) {
                oldConnection.cancel()
            }
        }
    }

    // MARK: - 采样处理

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        let isAppAudio = sampleBufferType == .audioApp
        guard isAppAudio || sampleBufferType == .audioMic else { return }
        guard pendingAudio.wait(timeout: .now()) == .success else { return }

        // 回调返回后 ReplayKit 可重用采样。后台只处理扩展自己拥有的 PCM 副本。
        guard let pcm = Self.copyPCMBuffer(from: sampleBuffer) else {
            pendingAudio.signal()
            if !hasLoggedCopyFailure {
                hasLoggedCopyFailure = true
                logger.error("无法复制 ReplayKit 音频采样")
            }
            return
        }

        queue.async { [weak self, pendingAudio = self.pendingAudio] in
            defer { pendingAudio.signal() }
            self?.processOwnedPCM(pcm, isAppAudio: isAppAudio)
        }
    }

    private func processOwnedPCM(_ pcm: AVAudioPCMBuffer, isAppAudio: Bool) {
        guard isBroadcasting else { return }
        autoreleasepool {
            let converted = isAppAudio ? appAudioConverter.convert(pcm) : microphoneConverter.convert(pcm)
            guard let converted, let packet = Self.makePacket(from: converted) else {
                if !hasLoggedConversionFailure {
                    hasLoggedConversionFailure = true
                    logger.error("无法转换 ReplayKit 音频采样")
                }
                return
            }
            send(packet)
        }
    }

    private func resetConverters() {
        appAudioConverter = BroadcastAudioConverter()
        microphoneConverter = BroadcastAudioConverter()
        hasLoggedConversionFailure = false
    }

    // MARK: - 网络

    private func connect() {
        guard isBroadcasting else { return }
        guard let port = NWEndpoint.Port(rawValue: AudioStreamProtocol.port) else { return }
        let oldConnection = connection
        connection = nil
        isConnected = false
        oldConnection?.cancel()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.send(Self.heartbeatPacket, cacheWhenDisconnected: false)
                self.flushPendingPackets()
                self.startHeartbeat()
            case .failed, .cancelled, .waiting:
                self.disconnectAndRetry(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
            guard let self, let connection, !self.isConnected else { return }
            self.disconnectAndRetry(connection)
        }
    }

    private func disconnectAndRetry(_ failedConnection: NWConnection) {
        guard connection === failedConnection else { return }
        connection = nil
        isConnected = false
        failedConnection.cancel()
        scheduleReconnect()
    }

    /// 没有音频播放时也要让主 App 知道广播仍在运行：
    /// 长度为 0 的包不会进入识别，只用于刷新主 App 的存活计时。
    private func startHeartbeat() {
        guard isBroadcasting, !heartbeatScheduled else { return }
        heartbeatScheduled = true
        scheduleHeartbeatTick()
    }

    private func scheduleHeartbeatTick() {
        queue.asyncAfter(deadline: .now() + AudioStreamProtocol.heartbeatInterval) { [weak self] in
            guard let self else { return }
            guard self.isBroadcasting else {
                self.heartbeatScheduled = false
                return
            }
            self.send(Self.heartbeatPacket, cacheWhenDisconnected: false)
            self.scheduleHeartbeatTick()
        }
    }

    private static let heartbeatPacket = Data([0, 0, 0, 0])

    /// 主 App 尚未开始监听时持续重试，直到连接成功或广播结束
    private func scheduleReconnect() {
        guard isBroadcasting, !reconnectScheduled else { return }
        reconnectScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            guard self.isBroadcasting, self.connection == nil else { return }
            self.connect()
        }
    }

    private func send(_ packet: Data, cacheWhenDisconnected: Bool = true) {
        guard let connection, isConnected else {
            if cacheWhenDisconnected { enqueuePending(packet) }
            return
        }
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil, let self else { return }
            self.queue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.disconnectAndRetry(connection)
            }
        })
    }

    /// 断线期间缓存音频包，数量超限时丢弃最旧的，避免扩展内存持续增长
    private func enqueuePending(_ packet: Data) {
        pendingPackets.append(packet)
        if pendingPackets.count > Self.maxPendingPackets {
            pendingPackets.removeFirst(pendingPackets.count - Self.maxPendingPackets)
        }
    }

    /// 重连成功后将断线期间积累的音频按顺序补发
    private func flushPendingPackets() {
        guard !pendingPackets.isEmpty else { return }
        let packets = pendingPackets
        pendingPackets.removeAll()
        for packet in packets {
            send(packet)
        }
    }

    // MARK: - 音频转换与打包

    private static func makePacket(from pcm: AVAudioPCMBuffer) -> Data? {
        guard pcm.frameLength > 0, let samples = pcm.int16ChannelData else { return nil }
        let byteCount = Int(pcm.frameLength) * MemoryLayout<Int16>.size
        var packet = Data(capacity: byteCount + 4)
        var length = UInt32(byteCount).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(Data(bytes: samples[0], count: byteCount))
        return packet
    }

    private static func copyPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: stream),
              format.sampleRate > 0, format.channelCount > 0 else { return nil }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0, let frameCount = Int32(exactly: sampleCount),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: frameCount,
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}

/// App 音轨和麦克风音轨可能交替到达，分别保留重采样状态。
private struct BroadcastAudioConverter {
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AudioStreamProtocol.sampleRate,
        channels: 1,
        interleaved: true
    )

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    mutating func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = Self.targetFormat else { return nil }
        if input.format == format { return input }
        if converter == nil || sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            sourceFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var provided = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
