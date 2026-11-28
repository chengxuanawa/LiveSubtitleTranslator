import AVFoundation
import Foundation

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
    /// 麦克风原始缓冲（供说话人分离等旁路分析）
    var onMicrophoneBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// 发生错误（权限被拒、语言不支持等）
    var onError: ((_ message: String) -> Void)? { get set }

    func start() async
    func stop()

    /// 以外部音频流启动识别（系统共享音频，不启动麦克风引擎）
    func startExternalAudio(sessionStartedAt: Date) async
    /// 向识别请求喂入外部音频缓冲
    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer)
    /// 外部音频识别是否已成功启动并在运行（用于判断启动是否失败）
    var isExternalAudioRunning: Bool { get }
}

/// 默认实现：非 Speech 引擎（如 WhisperKit）可按需覆盖
extension SpeechRecognizing {
    func startExternalAudio(sessionStartedAt: Date) async {}
    func appendExternalBuffer(_ buffer: AVAudioPCMBuffer) {}
    var isExternalAudioRunning: Bool { true }
}
