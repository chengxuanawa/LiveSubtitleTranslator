import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 实时语音识别能力抽象。
/// 二次开发时可使用 WhisperKit、sherpa-onnx 等引擎实现该协议进行替换。
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// 识别语言
    var locale: Locale { get set }
    /// 识别到一句完整的话（终态结果）
    var onFinalSegment: ((_ text: String, _ startTime: TimeInterval) -> Void)? { get set }
    /// 实时部分识别结果（用于打字机式预览）
    var onPartialUpdate: ((_ text: String) -> Void)? { get set }
    /// 发生错误（权限被拒、语言不支持等）
    var onError: ((_ message: String) -> Void)? { get set }

    func start() async
    func stop()

    /// 以外部音频流启动识别（系统共享音频，不启动麦克风引擎）
    func startExternalAudio() async
    /// 向识别请求喂入外部音频缓冲
    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer)
    /// 外部音频识别是否已成功启动并在运行（用于判断启动是否失败）
    var isExternalAudioRunning: Bool { get }
}

/// 默认实现：非 Speech 引擎（如 WhisperKit）可按需覆盖
extension SpeechRecognizing {
    func startExternalAudio() async {}
    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {}
    var isExternalAudioRunning: Bool { true }
}

/// 基于 iOS 26 SpeechAnalyzer + SpeechTranscriber 的实时语音识别实现。
/// 新版模型自带断句、标点与上下文纠错，段落由系统按语义切分，
/// 不再依赖能量阈值或“静音多少秒”之类的启发式规则。
@MainActor
final class SpeechRecognizerService: SpeechRecognizing {

    // MARK: - 配置

    var locale: Locale = Locale(identifier: "zh-Hans")

    // MARK: - 回调

    var onFinalSegment: ((_ text: String, _ startTime: TimeInterval) -> Void)?
    var onPartialUpdate: ((_ text: String) -> Void)?
    var onError: ((_ message: String) -> Void)?

    // MARK: - 识别会话

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    /// 外部音频重采样放到后台串行队列，避免每个音频包占用主线程
    private let externalAudioQueue = DispatchQueue(label: "com.example.sublingo.external.audio", qos: .userInitiated)
    private let externalConverterBox = ExternalAudioConverter()

    private var isTapInstalled = false
    private var isRunning = false
    private var isExternalAudio = false
    /// 首帧音频可能早于识别会话就绪到达：先缓存，启动后立即补喂，避免开头整段丢失
    private var externalAudioBacklog: [AVAudioPCMBuffer] = []
    private var sessionStartDate = Date()
    private var latestPartialText = ""
    private var lastSegmentEnd: TimeInterval = 0

    // MARK: - 生命周期（麦克风）

    func start() async {
        tearDown()
        isExternalAudio = false
        externalAudioBacklog.removeAll()

        guard await AVAudioApplication.requestRecordPermission() else {
            onError?("未获得麦克风权限，请到系统设置中授权。")
            return
        }

        guard let setup = await prepareAnalyzer() else { return }
        self.analyzer = setup.analyzer

        sessionStartDate = Date()
        lastSegmentEnd = 0
        latestPartialText = ""
        isRunning = true

        do {
            try await beginAnalysis(setup)
        } catch {
            onError?("语音识别启动失败：\(error.localizedDescription)")
            tearDown()
            return
        }

        // 音频会话：录音 + 与其他 App 音频混音，避免播放音频时麦克风会话被抢占
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .defaultToSpeaker]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?("音频会话启动失败：\(error.localizedDescription)")
            tearDown()
            return
        }

        // 校验麦克风输入格式（采样率或通道为 0 时 installTap 会崩溃）
        let inputNode = audioEngine.inputNode
        var format = inputNode.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = inputNode.inputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("未检测到可用的麦克风输入，请检查麦克风或蓝牙耳机连接后重试。")
            tearDown()
            return
        }

        let targetFormat = analyzerFormat ?? format
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            onError?("无法创建音频转换器，请重试。")
            tearDown()
            return
        }
        let continuation = inputContinuation

        // 安装音频 Tap：转换成识别引擎需要的格式后喂入 AnalyzerInput
        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: targetFormat) else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("音频引擎启动失败：\(error.localizedDescription)")
            tearDown()
            return
        }
    }

    func stop() {
        // 提交尚未终态的最后一句话，避免停止后内容丢失
        if isRunning {
            let trailing = latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                submitSegment(trailing, audioStart: nil)
            }
        }
        resetEngine(cancelAnalyzer: false, deactivateAudioSession: true)
    }

    // MARK: - 系统共享音频

    func startExternalAudio() async {
        isExternalAudio = true
        stopExternalAudio(preserveBufferedAudio: true)
        guard let setup = await prepareAnalyzer() else {
            stopExternalAudio()
            return
        }
        self.analyzer = setup.analyzer

        sessionStartDate = Date()
        lastSegmentEnd = 0
        latestPartialText = ""
        isRunning = true

        do {
            try await beginAnalysis(setup)
        } catch {
            onError?("语音识别启动失败：\(error.localizedDescription)")
            stopExternalAudio()
            return
        }
        flushExternalAudioBacklog()
    }

    /// 系统共享音频模式只释放识别资源，不关闭 App 的音频会话：
    /// 广播期间主 App 在后台，保活播放器仍需要这个会话来避免被系统挂起。
    private func stopExternalAudio(preserveBufferedAudio: Bool = false) {
        resetEngine(
            cancelAnalyzer: true,
            deactivateAudioSession: false,
            preserveBufferedAudio: preserveBufferedAudio
        )
    }

    var isExternalAudioRunning: Bool { isRunning && isExternalAudio }

    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let continuation = inputContinuation else {
            externalAudioBacklog.append(buffer)
            // 最多缓存约 4.5 秒音频：识别模型准备期间不丢开头，也不会无限增长
            if externalAudioBacklog.count > 200 {
                externalAudioBacklog.removeFirst(externalAudioBacklog.count - 200)
            }
            return
        }

        let targetFormat = analyzerFormat ?? buffer.format
        // 重采样在后台串行队列完成，保持音频顺序且不阻塞主线程
        let converterBox = externalConverterBox
        externalAudioQueue.async {
            guard let converted = converterBox.convert(buffer, to: targetFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func flushExternalAudioBacklog() {
        let pending = externalAudioBacklog
        externalAudioBacklog.removeAll()
        for buffer in pending {
            appendExternalBuffer(buffer)
        }
    }

    // MARK: - 引擎准备

    /// 校验支持性、安装语言模型并创建 Analyzer
    private func prepareAnalyzer() async -> (analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber)? {
        guard SpeechTranscriber.isAvailable else {
            onError?("当前设备不支持新一代本机识别。")
            return nil
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            onError?("当前引擎暂不支持所选语言（\(locale.identifier)），请更换语言后重试。")
            return nil
        }

        // volatile + fast：优先保证边说边出字，避免结果攒到一段结束才刷新
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        do {
            // 首次使用某语言时下载模型；已安装时直接跳过
            let installed = await SpeechTranscriber.installedLocales
            let isInstalled = installed.contains {
                $0.identifier(.bcp47) == supportedLocale.identifier(.bcp47)
            }
            if !isInstalled,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            onError?("语音模型安装失败：\(error.localizedDescription)")
            return nil
        }

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // 预加载识别资源，降低第一句字幕的延迟
        if let analyzerFormat {
            try? await analyzer.prepareToAnalyze(in: analyzerFormat)
        }
        return (analyzer, transcriber)
    }

    /// 启动输入流并持续消费识别结果
    private func beginAnalysis(_ setup: (analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber)) async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        // 先开始消费结果，再启动分析，避免首批结果到达时无人接收
        startResultsLoop(with: setup.transcriber)
        try await setup.analyzer.start(inputSequence: stream)
    }

    private func startResultsLoop(with transcriber: SpeechTranscriber) {
        resultsTask?.cancel()
        // 结果消费放在主线程之外：iOS 26 的 SpeechTranscriber 若在主 actor 上迭代，
        // 结果可能被攒到整段处理完才一起刷新（表现为必须重新进入 App 才看到字幕）。
        resultsTask = Task.detached { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let isFinal = result.isFinal
                    let audioStart = CMTimeGetSeconds(result.range.start)
                    await MainActor.run {
                        guard let self, self.isRunning else { return }
                        self.handleResult(text: text, isFinal: isFinal, audioStart: audioStart)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.onError?("识别中断：\(error.localizedDescription)")
                    if self.isExternalAudio {
                        self.stopExternalAudio()
                    } else {
                        self.tearDown()
                    }
                }
            }
        }
    }

    /// 结果处理：volatile 用于实时预览，final 落库为一条字幕
    private func handleResult(text: String, isFinal: Bool, audioStart: TimeInterval) {
        if isFinal {
            latestPartialText = ""
            submitSegment(text, audioStart: audioStart)
        } else {
            latestPartialText = text
            onPartialUpdate?(text)
        }
    }

    // MARK: - 收尾

    private func tearDown() {
        resetEngine(cancelAnalyzer: true, deactivateAudioSession: true)
    }

    /// 统一释放识别会话资源，避免停止 / 收尾 / 外部音频三条路径各写一遍
    private func resetEngine(
        cancelAnalyzer: Bool,
        deactivateAudioSession: Bool,
        preserveBufferedAudio: Bool = false
    ) {
        isRunning = false
        isExternalAudio = preserveBufferedAudio
        if !preserveBufferedAudio {
            externalAudioBacklog.removeAll()
        }
        latestPartialText = ""

        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        let analyzer = self.analyzer
        Task {
            if cancelAnalyzer {
                await analyzer?.cancelAndFinishNow()
            } else {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            }
        }

        self.analyzer = nil
        analyzerFormat = nil
        if deactivateAudioSession {
            // 会话失活可能阻塞，放到后台执行，避免停止识别时卡住主线程
            DispatchQueue.global(qos: .utility).async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - 分段提交

    /// 段落落库：优先使用识别结果携带的音频时间，缺失时沿用上一段结束时间
    private func submitSegment(_ text: String, audioStart: TimeInterval?) {
        let now = Date().timeIntervalSince(sessionStartDate)
        var start = audioStart ?? lastSegmentEnd
        if !start.isFinite || start < 0 {
            start = lastSegmentEnd
        }
        // 音频时间轴可能略滞后于墙钟时间，限制在当前时长内
        start = min(start, now)
        lastSegmentEnd = now
        onFinalSegment?(text, start)
    }

    // MARK: - 音频转换

    /// 把麦克风 / 外部音频缓冲转换成识别引擎需要的格式
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// 外部音频 → 识别格式转换器：只在串行后台队列上调用，避免重采样占用主线程
private final class ExternalAudioConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let input = buffer.format
        if converter == nil
            || inputFormat?.sampleRate != input.sampleRate
            || inputFormat?.channelCount != input.channelCount
            || outputFormat?.sampleRate != targetFormat.sampleRate
            || outputFormat?.channelCount != targetFormat.channelCount {
            converter = AVAudioConverter(from: input, to: targetFormat)
            inputFormat = input
            outputFormat = targetFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
