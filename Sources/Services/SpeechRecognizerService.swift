import AVFoundation
import AVFAudio
import Foundation
import Speech

/// 实时语音识别能力抽象。
/// 二次开发时可使用 WhisperKit、sherpa-onnx 等引擎实现该协议进行替换。
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// 识别语言
    var locale: Locale { get set }
    /// 是否仅使用设备端识别（离线）
    var requiresOnDeviceRecognition: Bool { get set }
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

/// 基于系统 Speech 框架 + AVAudioEngine 的实时语音识别实现。
/// 段落切分采用简易静音检测（VAD）：说话后静音约 1.1 秒即结束当前识别任务并落库，
/// 因此“一句话说完就切段”，不依赖标点或固定字数。
@MainActor
final class SpeechRecognizerService: ObservableObject, SpeechRecognizing {

    // MARK: - 配置

    var locale: Locale = Locale(identifier: "zh-Hans")
    var requiresOnDeviceRecognition = true

    // MARK: - 回调

    var onFinalSegment: ((_ text: String, _ startTime: TimeInterval) -> Void)?
    var onPartialUpdate: ((_ text: String) -> Void)?
    var onError: ((_ message: String) -> Void)?

    // MARK: - 内部对象

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionStartDate = Date()
    private var isTapInstalled = false
    private var isRunning = false
    private var consecutiveTaskErrors = 0
    private var isFinalizing = false
    private var finalizationDeadline: Date?
    private var pendingPartialText = ""
    private var lastSegmentEnd: TimeInterval = 0

    // MARK: - 静音检测（VAD）

    private var lastVoiceTime = Date()
    private var silenceTriggered = false
    private var hasSpeechInCurrentSegment = false

    /// 简易能量阈值（float 采样，0-1）
    private static let silenceThreshold: Float = 0.012
    /// 连续静音超过该时长即视为一句结束
    private static let silenceDuration: TimeInterval = 1.1

    // MARK: - 生命周期

    func start() async {
        tearDown()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onError?("当前设备不支持所选识别语言，请更换语言后重试。")
            return
        }
        if requiresOnDeviceRecognition && !recognizer.supportsOnDeviceRecognition {
            onError?("当前语言或设备不支持离线识别，可在设置中关闭“仅在本机识别”。")
            return
        }
        guard await requestAuthorization() else {
            onError?("未获得麦克风或语音识别权限，请到系统设置中授权。")
            return
        }

        // 1. 音频会话：录音模式
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?("音频会话启动失败：\(error.localizedDescription)")
            return
        }

        // 2. 校验麦克风输入格式（采样率或通道为 0 时 installTap 会崩溃）
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

        // 3. 识别请求
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if requiresOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognizer = recognizer
        self.recognitionRequest = request

        // 4. 安装音频 Tap（同时做能量检测用于自动断句）
        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            let rms = SpeechRecognizerService.rms(of: buffer)
            Task { @MainActor [weak self] in
                self?.handleAudioLevel(rms: rms)
            }
        }
        isTapInstalled = true

        // 5. 启动引擎
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("音频引擎启动失败：\(error.localizedDescription)")
            tearDown()
            return
        }

        // 6. 开始识别任务
        sessionStartDate = Date()
        resetSessionState()
        isRunning = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }

    func stop() {
        // 提交尚未终态的最后一句话，避免停止后内容丢失
        if isRunning {
            let trailing = pendingPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                submitSegment(trailing)
            }
        }
        pendingPartialText = ""
        isRunning = false
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        tearDown()
    }

    // MARK: - 系统共享音频

    func startExternalAudio() async {
        tearDown()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onError?("当前设备不支持所选识别语言，请更换语言后重试。")
            return
        }
        if requiresOnDeviceRecognition && !recognizer.supportsOnDeviceRecognition {
            onError?("当前语言或设备不支持离线识别，可在设置中关闭“仅在本机识别”。")
            return
        }
        guard await requestAuthorization() else {
            onError?("未获得语音识别权限，请到系统设置中授权。")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if requiresOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognizer = recognizer
        self.recognitionRequest = request
        sessionStartDate = Date()
        resetSessionState()
        isRunning = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }

    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
        handleAudioLevel(rms: Self.rms(of: buffer))
    }

    private func tearDown() {
        isRunning = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 权限

    private func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - 静音检测与断句

    private func handleAudioLevel(rms: Float) {
        guard isRunning else { return }
        let now = Date()
        if rms > Self.silenceThreshold {
            lastVoiceTime = now
            silenceTriggered = false
            hasSpeechInCurrentSegment = true
        } else if hasSpeechInCurrentSegment,
                  !silenceTriggered,
                  now.timeIntervalSince(lastVoiceTime) > Self.silenceDuration {
            silenceTriggered = true
            requestFinalForSilence()
        }
    }

    /// 静音达到阈值：主动结束当前识别任务，触发 final 后落库
    private func requestFinalForSilence() {
        guard isRunning, !isFinalizing else { return }
        let text = pendingPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isFinalizing = true
        finalizationDeadline = Date().addingTimeInterval(2.0)
        recognitionRequest?.endAudio()
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        if let floatData = buffer.floatChannelData?[0] {
            var sum: Double = 0
            for index in 0..<count {
                let value = Double(floatData[index])
                sum += value * value
            }
            return Float((sum / Double(count)).squareRoot())
        }
        if let int16Data = buffer.int16ChannelData?[0] {
            var sum: Double = 0
            for index in 0..<count {
                let value = Double(int16Data[index]) / 32768.0
                sum += value * value
            }
            return Float((sum / Double(count)).squareRoot())
        }
        return 0
    }

    // MARK: - 识别回调

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard isRunning else { return }

        // 兜底：请求收尾后系统迟迟不返回 final 时，强制提交当前文本并续接
        if let deadline = finalizationDeadline, Date() > deadline {
            finalizationDeadline = nil
            isFinalizing = false
            commitPendingPartial()
            restartRecognition()
        }

        if let error {
            consecutiveTaskErrors += 1
            if consecutiveTaskErrors <= 3 {
                commitPendingPartial()
                isFinalizing = false
                finalizationDeadline = nil
                restartRecognition()
            } else {
                onError?("识别中断：\(error.localizedDescription)")
                tearDown()
            }
            return
        }
        guard let result else { return }

        consecutiveTaskErrors = 0
        let transcription = result.bestTranscription
        onPartialUpdate?(transcription.formattedString)

        if result.isFinal {
            isFinalizing = false
            finalizationDeadline = nil
            pendingPartialText = ""
            let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                submitSegment(text)
            }
            // SFSpeech 单个任务在 isFinal 后即完成，续接新任务才能持续转写
            restartRecognition()
            return
        }

        let partial = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingPartialText = partial

        // 超长句子兜底切分（避免识别任务无限增长）
        if !isFinalizing, partial.count >= 60 {
            requestFinalForSilence()
        }
    }

    /// 提交当前未终态文本（兜底用）
    private func commitPendingPartial() {
        let text = pendingPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingPartialText = ""
        guard !text.isEmpty else { return }
        submitSegment(text)
    }

    /// 段落落库：使用会话内累计时间作为起点，保证时间轴连续
    private func submitSegment(_ text: String) {
        let now = Date().timeIntervalSince(sessionStartDate)
        let start = lastSegmentEnd
        lastSegmentEnd = now
        onFinalSegment?(text, start)
    }

    /// 保持麦克风 / 外部音频输入不变，仅更换识别请求与任务，实现连续识别
    private func restartRecognition() {
        guard isRunning, let recognizer else { return }
        recognitionRequest?.endAudio()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if requiresOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        isFinalizing = false
        finalizationDeadline = nil
        silenceTriggered = false
        hasSpeechInCurrentSegment = false
        lastVoiceTime = Date()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }

    private func resetSessionState() {
        consecutiveTaskErrors = 0
        isFinalizing = false
        finalizationDeadline = nil
        pendingPartialText = ""
        lastSegmentEnd = 0
        silenceTriggered = false
        hasSpeechInCurrentSegment = false
        lastVoiceTime = Date()
    }
}