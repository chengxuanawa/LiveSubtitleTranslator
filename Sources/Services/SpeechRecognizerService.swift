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
}

/// 基于系统 Speech 框架 + AVAudioEngine 的实时语音识别实现。
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.recognizer = recognizer
        self.recognitionRequest = request

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            sessionStartDate = Date()

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.handleRecognitionResult(result, error: error)
                }
            }
        } catch {
            onError?("音频启动失败：\(error.localizedDescription)")
            tearDown()
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        tearDown()
    }

    private func tearDown() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
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