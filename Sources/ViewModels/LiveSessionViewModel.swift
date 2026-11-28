import Foundation
import SwiftUI
import UIKit

/// 编排一次实时字幕会话：语音识别 → 追加片段 → 异步翻译回填 → 字幕浮窗同步 → 结束保存。
/// 支持两种音频来源：麦克风直录 / 系统共享音频（ReplayKit 广播扩展）。
@MainActor
final class LiveSessionViewModel: ObservableObject {

    enum SessionState: Equatable {
        case idle
        case listening
        case ended
    }

    // MARK: - 对外状态

    @Published var state: SessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            refreshIdleTimer()
        }
    }
    @Published var segments: [CaptionSegment] = []
    /// 译文生成失败的片段（用于显示提示与重试按钮）
    @Published var failedTranslationIDs: Set<UUID> = []
    @Published var livePartialText = ""
    /// 等待 AI 整理分段的已识别文本（实时气泡会继续展示）
    @Published var pendingText = ""
    @Published var errorMessage: String?
    /// 中性提示（例如已停止识别但系统共享仍在录制）
    @Published var infoMessage: String?

    /// 实时气泡展示的完整文本：待整理片段 + 当前实时部分
    var liveDisplayText: String {
        pendingText + livePartialText
    }
    /// 实时气泡占位文案：区分暂停、等待共享音频与正常聆听，便于确认通道是否接上
    var livePlaceholderText: String {
        if isRecognitionPaused {
            return "已暂停识别，录屏仍在继续"
        }
        if audioSourceMode == .systemAudio, isWaitingForBroadcast {
            return "等待系统共享音频…"
        }
        return "正在聆听…"
    }
    /// 灵动岛字幕是否已开启（由用户手动触发或按设置自动开启）
    @Published var isLiveActivityActive = false
    /// 系统音频模式下是否正在等待广播连接
    @Published var isWaitingForBroadcast = false
    /// 系统音频识别是否已暂停（录屏广播保持不断开，只是不再喂入识别）
    @Published var isRecognitionPaused = false
    /// 画中画字幕是否已激活
    @Published var isPictureInPictureActive = false


    // MARK: - 依赖

    let speechRecognizer: any SpeechRecognizing
    let translationService: any TextTranslating
    let settings: SettingsStore
    let transcriptStore: TranscriptStore
    let liveActivity: LiveActivityService
    let systemAudioServer: SystemAudioStreamServer
    let aiService: AIService
    let locationService = LocationService()
    let keepAlive = SilentAudioKeepAlive()
    let pipController = CaptionPictureInPictureController()
    /// 实验性说话人分离（设置中开启后生效）
    let speakerDiarization = SpeakerDiarizationService()

    // MARK: - 会话上下文

    var sessionID = UUID()
    var sessionStart = Date()
    var sessionEnd: Date?
    var sourceIdentifier = ""
    var targetIdentifier = ""
    var lastVisualUpdate = Date.distantPast
    /// 实时预览节流：最近一次已发布的部分识别结果与发布时间
    var latestPartialText = ""
    var lastPartialPublish = Date.distantPast
    var partialThrottleTask: Task<Void, Never>?
    /// 本次录制的地点名（定位完成后写入，用于「位置」标题）
    var sessionLocationName: String?
    /// 本次录制自动生成的 AI 摘要（用于「AI 标题」）
    var sessionSummary: String?
    var locationTask: Task<Void, Never>?

    /// 广播开始时 App 在后台，画中画自动启动被推迟到回到前台
    var pendingAutoPiPStart = false
    /// 等待回到前台的自动启动轮询（scenePhase 回调可能被系统面板吞掉）
    var pendingAutoPiPTask: Task<Void, Never>?
    /// 本次录制是否已经尝试过自动开启浮窗，避免用户手动关闭后被反复拉起
    var didAttemptAutoStartVisual = false

    private var microphoneStartTask: Task<Void, Never>?
    var systemAudio = SystemAudioState()
    private var screenCaptureObserver: NSObjectProtocol?

    // MARK: - AI 分段缓冲

    struct PendingSpeechChunk {
        let text: String
        let startTime: TimeInterval
    }

    var pendingChunks: [PendingSpeechChunk] = []
    var segmentationTask: Task<Void, Never>?
    var segmentationRequestID = 0
    var segmentationGeneration = UUID()
    var isSegmentingPending = false
    /// 已落库的最近几段字幕，作为 AI 分段的上下文
    var recentSegmentContext: [String] = []

    init(
        speechRecognizer: any SpeechRecognizing,
        translationService: any TextTranslating,
        settings: SettingsStore,
        transcriptStore: TranscriptStore,
        liveActivity: LiveActivityService,
        systemAudioServer: SystemAudioStreamServer,
        aiService: AIService
    ) {
        self.speechRecognizer = speechRecognizer
        self.translationService = translationService
        self.settings = settings
        self.transcriptStore = transcriptStore
        self.liveActivity = liveActivity
        self.systemAudioServer = systemAudioServer
        self.aiService = aiService
        pipController.onStateChange = { [weak self] active in
            self?.isPictureInPictureActive = active
        }
        // 字号在设置里可分别调节原文与译文，渲染时实时读取
        pipController.fontScaleProvider = { [weak settings] in
            (
                original: CGFloat(settings?.pipOriginalFontScale ?? 1),
                translated: CGFloat(settings?.pipTranslatedFontScale ?? 1)
            )
        }
        // 录屏状态辅助恢复监听，识别由广播扩展送来的音频启动
        screenCaptureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenCaptureChange()
            }
        }
        wireCallbacks()
        // App 启动即开始监听系统音频端口：即使用户在其他页签或从控制中心
        // 直接开始共享，广播扩展也能连上，不会因为页面未出现而检测不到
        _ = systemAudioServer.start()
    }

    deinit {
        if let screenCaptureObserver {
            NotificationCenter.default.removeObserver(screenCaptureObserver)
        }
    }


    private func wireCallbacks() {
        speechRecognizer.onPartialUpdate = { [weak self] text in
            self?.publishPartialText(text)
        }
        speechRecognizer.onMicrophoneBuffer = { [weak self] buffer in
            Task { @MainActor in
                self?.speakerDiarization.append(buffer)
            }
        }
        speechRecognizer.onFinalSegment = { [weak self] text, startTime in
            self?.handleFinalSegment(text, startTime: startTime)
        }
        speechRecognizer.onError = { [weak self] message in
            self?.handleError(message)
        }

        systemAudioServer.onAudioBuffer = { [weak self] buffer in
            self?.receiveSystemAudio(buffer)
        }
        systemAudioServer.onBroadcastHeartbeat = { [weak self] in
            self?.handleBroadcastHeartbeat()
        }
        systemAudioServer.onStreamEnded = { [weak self] in
            self?.handleBroadcastEnded()
        }
        systemAudioServer.onStreamStalled = { [weak self] in
            self?.handleBroadcastStalled()
        }
        systemAudioServer.onReconnectTimedOut = { [weak self] in
            self?.handleBroadcastReconnectTimeout()
        }
    }

    var audioSourceMode: AudioSourceMode {
        settings.audioSourceMode
    }

    /// 识别期间按设置阻止屏幕自动熄灭；停止后立刻恢复系统自动息屏
    func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = state == .listening && settings.keepScreenOnWhileRecognizing
    }

    func setAudioSourceMode(_ mode: AudioSourceMode) {
        guard mode != audioSourceMode else { return }
        if state == .listening || microphoneStartTask != nil {
            stop()
        } else {
            stopSystemAudioRecovery()
        }
        settings.audioSourceMode = mode
        settings.objectWillChange.send()
        if mode == .systemAudio {
            prepareSystemAudioServer()
        }
    }

    func toggle() {
        if state == .listening {
            if audioSourceMode == .systemAudio {
                endSystemAudioFromButton()
            } else {
                stop()
            }
            return
        }
        switch audioSourceMode {
        case .microphone:
            guard microphoneStartTask == nil else { return }
            microphoneStartTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.startMicrophone()
                guard !Task.isCancelled else { return }
                self.microphoneStartTask = nil
            }
        case .systemAudio:
            prepareSystemAudioServer()
        }
    }

    // MARK: - 麦克风模式

    private func startMicrophone() async {
        guard state != .listening else { return }
        errorMessage = nil
        resetForNewRecording()

        await translationService.setLanguagePair(
            source: Locale.Language(identifier: sourceIdentifier),
            target: Locale.Language(identifier: targetIdentifier)
        )

        guard !Task.isCancelled, audioSourceMode == .microphone else { return }
        speechRecognizer.locale = Locale(identifier: sourceIdentifier)
        await speechRecognizer.start()
        guard !Task.isCancelled, audioSourceMode == .microphone else { return }

        if errorMessage == nil {
            state = .listening
            startSpeakerDiarizationIfNeeded()
            autoStartVisualIfNeeded()
        }
    }

    func stop() {
        microphoneStartTask?.cancel()
        microphoneStartTask = nil
        isRecognitionPaused = false
        stopSystemAudioRecovery()
        speechRecognizer.stop()
        // 结束前先保存尚未经过 AI 分段的内容。
        flushPendingBuffer()
        resetPartialPreview()
        teardownOutputs()
        sessionEnd = Date()
        state = .ended
        saveCurrentSession()
        generateAutoTitleIfNeeded()
    }

    func dismissError() {
        errorMessage = nil
    }

    func resetForNewRecording() {
        speakerDiarization.stop()
        isRecognitionPaused = false
        resetExternalRecognitionRetry()
        resetAutomaticVisuals()
        segments = []
        failedTranslationIDs.removeAll()
        resetPartialPreview()
        resetPendingBuffer()
        startNewSessionContext()
    }

    private func handleError(_ message: String) {
        if state == .listening, audioSourceMode == .systemAudio {
            handleExternalRecognitionError(message)
            return
        }
        errorMessage = message
        flushPendingBuffer()
        state = .ended
        teardownOutputs()
    }
}
