import AVFoundation
import Network
import ReplayKit

/// 广播上传扩展：捕获系统音频（其他 App 播放的声音）并转发给主 App。
/// 仅负责转发，不做识别；音频统一转换为 44.1 kHz / 16-bit / 单声道，经 localhost TCP 发送。
final class SampleHandler: RPBroadcastSampleHandler {

    private let queue = DispatchQueue(label: "com.example.livesubtitletranslator.broadcast.audio")
    private var connection: NWConnection?
    /// 连接状态会跨线程读取（采样回调 / 网络队列），用锁保护
    private let stateLock = NSLock()
    private var isConnected = false
    private var isBroadcasting = false
    private var reconnectScheduled = false
    private var heartbeatScheduled = false
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    /// 断线期间暂存的音频包：重连成功后立即补发，避免每次重连丢开头音频
    private var pendingPackets: [Data] = []
    /// 最多暂存的音频包数量（约 5 秒）
    private static let maxPendingPackets = 250

    private var connected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isConnected
    }

    private func setConnected(_ value: Bool) {
        stateLock.lock()
        isConnected = value
        stateLock.unlock()
    }

    // MARK: - 广播生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isBroadcasting = true
            self.connect()
        }
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isBroadcasting = false
            self.reconnectScheduled = false
            self.heartbeatScheduled = false
            self.pendingPackets.removeAll()
            let oldConnection = self.connection
            self.connection = nil
            self.setConnected(false)
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
        guard sampleBufferType == .audioApp || sampleBufferType == .audioMic else { return }
        // ReplayKit 可能在不同线程回调音频：转换与发包统一放到串行队列，
        // 否则共用 AVAudioConverter 会因并发丢包甚至崩溃（表现为偶发抓不到声音）
        queue.async { [weak self] in
            guard let self, self.isBroadcasting else { return }
            autoreleasepool {
                guard let packet = self.makePacket(from: sampleBuffer) else { return }
                self.send(packet)
            }
        }
    }

    // MARK: - 网络

    private func connect() {
        guard isBroadcasting else { return }
        guard let port = NWEndpoint.Port(rawValue: AudioStreamProtocol.port) else { return }
        let oldConnection = connection
        connection = nil
        oldConnection?.cancel()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.setConnected(true)
                self.flushPendingPackets()
                self.startHeartbeat()
            case .failed, .cancelled, .waiting:
                self.setConnected(false)
                // 主 App 的本地监听可能还没就绪或被系统挂起，1 秒后自动重连
                self.scheduleReconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
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
            if self.connected {
                self.send(Self.heartbeatPacket)
            }
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
            guard self.isBroadcasting, !self.connected else { return }
            self.connect()
        }
    }

    private func send(_ packet: Data) {
        guard let connection, connected else {
            // 连接尚未就绪或刚断开：先缓存，等重连成功后补发
            enqueuePending(packet)
            scheduleReconnect()
            return
        }
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, error != nil, self.connection === connection else { return }
            // 发送失败说明连接已经不可用，主动标记断线并重连，避免录屏还在跑但没有音频
            self.queue.async {
                self.setConnected(false)
                self.scheduleReconnect()
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

    private func makePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pcm = makePCMBuffer(from: sampleBuffer) else { return nil }
        guard let converted = convert(pcm), let samples = converted.int16ChannelData else { return nil }

        let frameLength = Int(converted.frameLength)
        guard frameLength > 0 else { return nil }
        let byteCount = frameLength * MemoryLayout<Int16>.size
        var packet = Data(capacity: byteCount + 4)
        var length = UInt32(byteCount).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(Data(bytes: samples[0], count: byteCount))
        return packet
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        guard let format = AVAudioFormat(streamDescription: asbdPointer) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        // 动态分配 AudioBufferList（多声道非交错时可能包含多个 AudioBuffer）
        var bufferListSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSize > 0 else { return nil }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let listPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let sourceList = UnsafeMutableAudioBufferListPointer(listPointer)
        let targetList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let channelCount = min(sourceList.count, targetList.count)
        for index in 0..<channelCount {
            guard let sourceData = sourceList[index].mData,
                  let targetData = targetList[index].mData else { continue }
            let bytes = Int(min(sourceList[index].mDataByteSize, targetList[index].mDataByteSize))
            memcpy(targetData, sourceData, bytes)
            targetList[index].mDataByteSize = UInt32(bytes)
        }
        return pcm
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if targetFormat == nil {
            targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: AudioStreamProtocol.sampleRate,
                channels: 1,
                interleaved: true
            )
        }
        guard let targetFormat else { return nil }

        if converter == nil || converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            converterInputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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
