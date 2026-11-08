import Foundation
import SwiftUI
import Translation

/// 编排一次实时字幕会话：语音识别 → 追加片段 → 异步翻译回填 → 灵动岛同步 → 结束保存。
/// 支持两种音频来源：麦克风直录 / 系统共享音频（ReplayKit 广播扩展）。
@MainActor
final class LiveSessionViewModel: ObservableObject {

    enum SessionState: Equatable {
        case idle
        case listening
        case ended
    }

    // MARK: - 对外状态

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var segments: [CaptionSegment] = []
    @Published var livePartialText = ""
    @Published var errorMessage: String?
    /// 灵动岛字幕是否已开启（由用户手动触发）
    @Published private(set) var isLiveActivityActive = false
    /// 系统音频模式下是否正在等待广播连接
    @Published private(set) var isWaitingForBroadcast = false

    // MARK: - 依赖（协议抽象，便于二次开发替换引擎）

    private let speechRecognizer: any SpeechRecognizing
    private let translationService: any TextTranslating
    private let settings: SettingsStore
    private let transcriptStore: TranscriptStore
    private let liveActivity: LiveActivityService
    private let systemAudioServer: SystemAudioStreamServer

    // MARK: - 会话上下文

    private var sessionStart = Date()
    private var sourceIdentifier = ""
    private var targetIdentifier = ""

    init(
        speechRecognizer: any SpeechRecognizing,
        translationService: any TextTranslating,
        settings: SettingsStore,
        transcriptStore: TranscriptStore,
        liveActivity: LiveActivityService,
        systemAudioServer: SystemAudioStreamServer
    ) {
        self.speechRecognizer = speechRecognizer
        self.translationService = translationService
        self.settings = settings
        self.transcriptStore = transcriptStore
        self.liveActivity = liveActivity
        self.systemAudioServer = systemAudioServer
        wireCallbacks()
    }

    private func wireCallbacks() {
        speechRecognizer.onPartialUpdate = { [weak self] text in
            self?.livePartialText = text
        }
        speechRecognizer.onFinalSegment = { [weak self] text, startTime in
            self?.handleFinalSegment(text, startTime: startTime)
        }
        speechRecognizer.onError = { [weak self] message in
            self?.handleError(message)
        }

        systemAudioServer.onAudioBuffer = { [weak self] buffer in
            self?.speechRecognizer.appendExternalBuffer(buffer)
        }
        systemAudioServer.onStreamStarted = { [weak self] in
            self?.handleBroadcastStarted()
        }
        systemAudioServer.onStreamEnded = { [weak self] in
            self?.handleBroadcastEnded()
        }
    }

    var audioSourceMode: AudioSourceMode {
        settings.audioSourceMode
    }

    // MARK: - 控制

    func toggle() {
        if state == .listening {
            stop()
            return
        }
        switch settings.audioSourceMode {
        case .microphone:
            Task { await startMicrophone() }
        case .systemAudio:
            prepareSystemAudioServer()
        }
    }

    /// 系统音频模式进入页面时调用：保证广播扩展能连上本地端口
    func prepareSystemAudioServer() {
        if !systemAudioServer.isWaitingForBroadcast {
            _ = systemAudioServer.start()
        }
        isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
        if !isWaitingForBroadcast {
            errorMessage = "无法启动系统音频通道（本地端口被占用），请稍后重试。"
        }
    }

    /// 手动开启 / 关闭灵动岛字幕
    func toggleLiveActivity() {
        guard LiveActivityService.isSupported else {
            errorMessage = "系统未允许实时活动：请在系统设置 → App → 实时活动 中开启。"
            return
        }
        if isLiveActivityActive {
            liveActivity.end()
            isLiveActivityActive = false
        } else {
            isLiveActivityActive = liveActivity.start(languagePair: "\(sourceIdentifier) → \(targetIdentifier)")
        }
    }

    // MARK: - 麦克风模式

    private func startMicrophone() async {
        guard state != .listening else { return }
        errorMessage = nil
        segments = []
        livePartialText = ""
        sessionStart = Date()
        sourceIdentifier = settings.sourceLanguageIdentifier
        targetIdentifier = settings.targetLanguageIdentifier

        await translationService.setLanguagePair(
            source: Locale.Language(identifier: sourceIdentifier),
            target: Locale.Language(identifier: targetIdentifier)
        )

        speechRecognizer.locale = Locale(identifier: sourceIdentifier)
        speechRecognizer.requiresOnDeviceRecognition = settings.requiresOnDeviceRecognition
        await speechRecognizer.start()

        if errorMessage == nil {
            state = .listening
            if settings.autoStartLiveActivity {
                isLiveActivityActive = liveActivity.start(languagePair: "\(sourceIdentifier) → \(targetIdentifier)")
            }
        }
    }

    // MARK: - 系统音频模式

    private func handleBroadcastStarted() {
        isWaitingForBroadcast = false
        guard state != .listening else { return }

        errorMessage = nil
        segments = []
        livePartialText = ""
        sessionStart = Date()
        sourceIdentifier = settings.sourceLanguageIdentifier
        targetIdentifier = settings.targetLanguageIdentifier

        speechRecognizer.locale = Locale(identifier: sourceIdentifier)
        speechRecognizer.requiresOnDeviceRecognition = settings.requiresOnDeviceRecognition
        state = .listening
        if settings.autoStartLiveActivity {
            isLiveActivityActive = liveActivity.start(languagePair: "\(sourceIdentifier) → \(targetIdentifier)")
        }

        Task { [weak self] in
            guard let self else { return }
            await self.translationService.setLanguagePair(
                source: Locale.Language(identifier: self.sourceIdentifier),
                target: Locale.Language(identifier: self.targetIdentifier)
            )
            await self.speechRecognizer.startExternalAudio()
            if self.errorMessage != nil {
                self.stop()
            }
        }
    }

    private func handleBroadcastEnded() {
        isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
        if state == .listening {
            stop()
        }
    }

    // MARK: - 收尾

    func stop() {
        speechRecognizer.stop()
        livePartialText = ""
        liveActivity.end()
        isLiveActivityActive = false
        state = .ended
        saveCurrentSession()
    }

    func clearSegments() {
        segments = []
        livePartialText = ""
        sessionStart = Date()
    }

    func dismissError() {
        errorMessage = nil
    }

    /// 接入 SwiftUI translationTask 提供的系统翻译会话（iOS 18+ 兼容路径）
    func attachTranslationSession(_ session: TranslationSession) {
        translationService.attach(session: session)
    }

    // MARK: - 私有

    private func handleError(_ message: String) {
        errorMessage = message
        state = .ended
        liveActivity.end()
        isLiveActivityActive = false
    }

    private func handleFinalSegment(_ text: String, startTime: TimeInterval) {
        let segment = CaptionSegment(originalText: text, startTime: startTime)
        segments.append(segment)
        let segmentID = segment.id
        updateLiveActivity(originalText: text, translatedText: nil)

        // 异步翻译，完成后回填对应片段
        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translationService.translate(text)
            guard let translated,
                  let index = self.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            self.segments[index].translatedText = translated
            self.updateLiveActivity(originalText: text, translatedText: translated)
            // 会话结束后仍有译文回填时，刷新已保存的记录
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }

    private func updateLiveActivity(originalText: String, translatedText: String?) {
        guard isLiveActivityActive else { return }
        liveActivity.update(originalText: originalText, translatedText: translatedText)
    }

    private func saveCurrentSession() {
        guard !segments.isEmpty else { return }
        let session = TranscriptSession(
            startedAt: sessionStart,
            endedAt: Date(),
            sourceLanguageIdentifier: sourceIdentifier,
            targetLanguageIdentifier: targetIdentifier,
            segments: segments
        )
        transcriptStore.save(session)
    }
}