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
/// 启动流程按“权限 → 音频会话 → 格式校验 → 安装 Tap → 启动引擎 → 识别任务”的顺序执行，
/// 并对麦克风格式、音频会话异常做防御，避免 installTap 使用非法格式导致崩溃。
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

        // 1. 音频会话：录音模式（不附加 duckOthers，避免与 .record 组合产生会话错误）
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

        // 4. 安装音频 Tap
        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
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
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }

    func stop() {
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
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }

    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    private func tearDown() {
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

    // MARK: - 识别回调

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            onError?("识别中断：\(error.localizedDescription)")
            tearDown()
            return
        }
        guard let result else {
            onError?("未能获取识别结果。")
            return
        }

        let transcription = result.bestTranscription
        onPartialUpdate?(transcription.formattedString)

        if result.isFinal {
            let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let startTime: TimeInterval
            if let lastSegment = transcription.segments.last {
                startTime = lastSegment.timestamp
            } else {
                startTime = Date().timeIntervalSince(sessionStartDate)
            }
            onFinalSegment?(text, startTime)
        }
    }
}