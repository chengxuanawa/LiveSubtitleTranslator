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
}

/// 默认实现：非 Speech 引擎（如 WhisperKit）可按需覆盖
extension SpeechRecognizing {
    func startExternalAudio() async {}
    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {}
}

/// 基于 iOS 26 SpeechAnalyzer + SpeechTranscriber 的实时语音识别实现。
/// 新版模型自带断句、标点与上下文纠错，段落由系统按语义切分，
/// 不再依赖能量阈值或“静音多少秒”之类的启发式规则。
@MainActor
final class SpeechRecognizerService: ObservableObject, SpeechRecognizing {

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
    private var externalConverter: AVAudioConverter?
    private var externalInputFormat: AVAudioFormat?

    private var isTapInstalled = false
    private var isRunning = false
    private var sessionStartDate = Date()
    private var latestPartialText = ""
    private var lastSegmentEnd: TimeInterval = 0

    // MARK: - 生命周期（麦克风）

    func start() async {
        tearDown()

        guard await AVAudioApplication.requestRecordPermission() else {
            onError?("未获得麦克风权限，请到系统设置中授权。")
            return
        }

        guard let setup = await prepareAnalyzer() else { return }

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

        // 音频会话：录音模式
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
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
        latestPartialText = ""
        isRunning = false

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

        // 让引擎收尾并释放模型会话；结果流已不再需要
        let analyzer = self.analyzer
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }

        self.analyzer = nil
        analyzerFormat = nil
        externalConverter = nil
        externalInputFormat = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 系统共享音频

    func startExternalAudio() async {
        tearDown()
        guard let setup = await prepareAnalyzer() else { return }

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
    }

    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let continuation = inputContinuation else { return }

        let targetFormat = analyzerFormat ?? buffer.format
        if externalConverter == nil
            || externalInputFormat?.sampleRate != buffer.format.sampleRate
            || externalInputFormat?.channelCount != buffer.format.channelCount {
            externalConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            externalInputFormat = buffer.format
        }
        guard let converter = externalConverter,
              let converted = Self.convert(buffer, using: converter, to: targetFormat) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    // MARK: - 引擎准备

    /// 校验支持性、安装语言模型并创建 Analyzer
    private func prepareAnalyzer() async -> (SpeechAnalyzer, SpeechTranscriber)? {
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
        self.analyzer = analyzer
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
                    self.tearDown()
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
        isRunning = false
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
            await analyzer?.cancelAndFinishNow()
        }

        self.analyzer = nil
        analyzerFormat = nil
        externalConverter = nil
        externalInputFormat = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
