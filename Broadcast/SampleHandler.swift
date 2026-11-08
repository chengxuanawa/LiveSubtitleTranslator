import AVFoundation
import Network
import ReplayKit

/// 广播上传扩展：捕获系统音频（其他 App 播放的声音）并转发给主 App。
/// 仅负责转发，不做识别；音频统一转换为 44.1 kHz / 16-bit / 单声道，经 localhost TCP 发送。
final class SampleHandler: RPBroadcastSampleHandler {

    private let queue = DispatchQueue(label: "com.example.livesubtitletranslator.broadcast.audio")
    private var connection: NWConnection?
    private var isConnected = false
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    // MARK: - 广播生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        connect()
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    // MARK: - 采样处理

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp || sampleBufferType == .audioMic else { return }
        guard isConnected else { return }
        autoreleasepool {
            guard let packet = makePacket(from: sampleBuffer) else { return }
            send(packet)
        }
    }

    // MARK: - 网络

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: AudioStreamProtocol.port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
            case .failed, .cancelled, .waiting:
                self?.isConnected = false
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ packet: Data) {
        guard let connection, isConnected else { return }
        connection.send(content: packet, completion: .contentProcessed { _ in })
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
            converter?.sampleRateConverterQuality = .low
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