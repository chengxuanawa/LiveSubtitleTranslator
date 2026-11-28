import AVFoundation
import CoreMedia
import Foundation
import Speech

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
    var onMicrophoneBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((_ message: String) -> Void)?

    // MARK: - 识别会话

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    /// 外部音频重采样放到后台串行队列，避免每个音频包占用主线程
    private let externalAudioQueue = DispatchQueue(label: "com.example.sublingo.external.audio", qos: .userInitiated)
    private var externalConverterBox = ExternalAudioConverter()

    private var generation = 0
    private var hasMicrophoneAudioSession = false
    private var isTapInstalled = false
    private var isRunning = false
    private var isExternalAudio = false
    /// 首帧音频可能早于识别会话就绪到达：先缓存，启动后立即补喂，避免开头整段丢失
    private var externalAudioBacklog: [(buffer: AVAudioPCMBuffer, receivedAt: Date)] = []
    private var sessionStartDate = Date()
    private var analysisTimeOffset: TimeInterval = 0
    private var latestPartialText = ""
    private var lastSegmentEnd: TimeInterval = 0

    // MARK: - 生命周期（麦克风）

    func start() async {
        tearDown()
        let generation = self.generation
        let granted = await AVAudioApplication.requestRecordPermission()
        guard isCurrent(generation) else { return }
        guard granted else {
            onError?("未获得麦克风权限，请到系统设置中授权。")
            return
        }

        do {
            try await startAnalysis(generation: generation)
        } catch {
            failStartup(error, generation: generation)
            return
        }
        guard isCurrent(generation) else { return }

        hasMicrophoneAudioSession = true
        do {
            try await AppAudioSession.activateMicrophone()
        } catch {
            guard isCurrent(generation) else { return }
            finishAnalysisWithError("音频会话启动失败：\(error.localizedDescription)")
            return
        }
        guard isCurrent(generation) else { return }

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
        let micHandler = onMicrophoneBuffer
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let converted = convertSpeechPCM(buffer, using: converter, to: targetFormat) else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
            micHandler?(converted)
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
        resetEngine(cancelAnalyzer: !isRunning, deactivateAudioSession: true)
    }

    // MARK: - 系统共享音频

    func startExternalAudio(sessionStartedAt: Date) async {
        stopExternalAudio(preserveBufferedAudio: true)
        externalConverterBox = ExternalAudioConverter()
        let generation = self.generation
        do {
            try await startAnalysis(generation: generation)
        } catch {
            failStartup(error, generation: generation)
            return
        }
        guard isCurrent(generation) else { return }
        sessionStartDate = sessionStartedAt
        let firstAudioAt = externalAudioBacklog.first?.receivedAt ?? Date()
        analysisTimeOffset = max(0, firstAudioAt.timeIntervalSince(sessionStartedAt))
        lastSegmentEnd = analysisTimeOffset
        flushExternalAudioBacklog()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private func failStartup(_ error: Error, generation: Int) {
        guard isCurrent(generation) else { return }
        let message = (error as? StartupError)?.errorDescription
            ?? "语音识别启动失败：\(error.localizedDescription)"
        finishAnalysisWithError(message)
    }

    private func finishAnalysisWithError(_ message: String) {
        if isExternalAudio {
            stopExternalAudio(preserveBufferedAudio: true)
        } else {
            tearDown()
        }
        onError?(message)
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
        guard isExternalAudioRunning, let continuation = inputContinuation, let targetFormat = analyzerFormat else {
            externalAudioBacklog.append((buffer, Date()))
            // 最多缓存约 4.5 秒音频：识别模型准备期间不丢开头，也不会无限增长
            if externalAudioBacklog.count > 200 {
                externalAudioBacklog.removeFirst(externalAudioBacklog.count - 200)
            }
            return
        }

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
        for packet in pending {
            appendExternalBuffer(packet.buffer)
        }
    }

    // MARK: - 引擎准备

    private enum StartupError: LocalizedError {
        case unsupportedDevice
        case unsupportedLocale(String)
        case missingAudioFormat
        case modelInstallation(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedDevice:
                return "当前设备不支持新一代本机识别。"
            case .unsupportedLocale(let identifier):
                return "当前引擎暂不支持所选语言（\(identifier)）。"
            case .missingAudioFormat:
                return "语音识别无法取得可用的音频格式。"
            case .modelInstallation(let error):
                return "语音模型安装失败：\(error.localizedDescription)"
            }
        }
    }

    /// 准备期间只使用局部变量。取消或超时的启动不能覆盖新会话的格式或输入流。
    private func startAnalysis(generation: Int) async throws {
        guard SpeechTranscriber.isAvailable else { throw StartupError.unsupportedDevice }
        let requestedLocale = locale
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        guard isCurrent(generation) else { return }
        guard let supportedLocale else { throw StartupError.unsupportedLocale(requestedLocale.identifier) }

        // volatile + fast：优先保证边说边出字，避免结果攒到一段结束才刷新
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        try await installModelIfNeeded(for: supportedLocale, transcriber: transcriber)
        guard isCurrent(generation) else { return }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard isCurrent(generation) else { return }
        guard let format else { throw StartupError.missingAudioFormat }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try? await analyzer.prepareToAnalyze(in: format)
        guard isCurrent(generation) else { return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        analyzerFormat = format
        inputContinuation = continuation
        sessionStartDate = Date()
        analysisTimeOffset = 0
        lastSegmentEnd = 0
        startResultsLoop(with: transcriber, generation: generation)
        try await analyzer.start(inputSequence: stream)
        guard isCurrent(generation) else { return }
        isRunning = true
    }

    private func installModelIfNeeded(for locale: Locale, transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        guard !isInstalled else { return }
        do {
            try Task.checkCancellation()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
            }
        } catch {
            throw StartupError.modelInstallation(error)
        }
    }

    private func startResultsLoop(with transcriber: SpeechTranscriber, generation: Int) {
        // 在主 actor 外消费结果，避免实时字幕被攒到一整段处理完才刷新。
        resultsTask = Task.detached { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !Task.isCancelled else { continue }
                    await self?.receiveResult(
                        text, isFinal: result.isFinal, audioStart: CMTimeGetSeconds(result.range.start),
                        generation: generation
                    )
                }
            } catch {
                await self?.handleResultsEnded(generation: generation, message: "识别中断：\(error.localizedDescription)")
                return
            }
            await self?.handleResultsEnded(generation: generation, message: "语音识别意外结束。")
        }
    }

    private func receiveResult(_ text: String, isFinal: Bool, audioStart: TimeInterval, generation: Int) {
        guard isCurrent(generation), isRunning else { return }
        handleResult(text: text, isFinal: isFinal, audioStart: audioStart)
    }

    private func handleResultsEnded(generation: Int, message: String) {
        guard isCurrent(generation) else { return }
        finishAnalysisWithError(message)
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
        generation += 1
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
        if deactivateAudioSession, hasMicrophoneAudioSession {
            hasMicrophoneAudioSession = false
            AppAudioSession.deactivate()
        }
    }

    // MARK: - 分段提交

    /// 段落落库：优先使用识别结果携带的音频时间，缺失时沿用上一段结束时间
    private func submitSegment(_ text: String, audioStart: TimeInterval?) {
        let now = Date().timeIntervalSince(sessionStartDate)
        let elapsedAudio = audioStart.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let start = min(elapsedAudio.map { $0 + analysisTimeOffset } ?? lastSegmentEnd, now)
        lastSegmentEnd = now
        onFinalSegment?(text, start)
    }
}
