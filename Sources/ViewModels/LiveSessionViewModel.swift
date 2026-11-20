import Foundation
import SwiftUI
import Translation
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

    @Published private(set) var state: SessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            refreshIdleTimer()
        }
    }
    @Published private(set) var segments: [CaptionSegment] = []
    /// 译文生成失败的片段（用于显示提示与重试按钮）
    @Published private(set) var failedTranslationIDs: Set<UUID> = []
    @Published var livePartialText = ""
    /// 等待 AI 整理分段的已识别文本（实时气泡会继续展示）
    @Published private(set) var pendingText = ""
    @Published var errorMessage: String?
    /// 中性提示（例如已停止识别但系统共享仍在录制）
    @Published private(set) var infoMessage: String?

    /// 实时气泡展示的完整文本：待整理片段 + 当前实时部分
    var liveDisplayText: String {
        pendingText + livePartialText
    }
    /// 实时气泡占位文案：区分暂停、等待共享音频与正常聆听，便于确认通道是否接上
    var livePlaceholderText: String {
        if isRecognitionPaused {
            return "已暂停识别，录屏仍在继续"
        }
        if audioSourceMode == .systemAudio, state != .listening {
            return "等待系统共享音频…"
        }
        return "正在聆听…"
    }
    /// 灵动岛字幕是否已开启（由用户手动触发或按设置自动开启）
    @Published private(set) var isLiveActivityActive = false
    /// 系统音频模式下是否正在等待广播连接
    @Published private(set) var isWaitingForBroadcast = false
    /// 系统音频识别是否已暂停（录屏广播保持不断开，只是不再喂入识别）
    @Published private(set) var isRecognitionPaused = false
    /// 画中画字幕是否已激活
    @Published private(set) var isPictureInPictureActive = false

    // MARK: - 依赖

    private let speechRecognizer: any SpeechRecognizing
    private let translationService: any TextTranslating
    private let settings: SettingsStore
    private let transcriptStore: TranscriptStore
    private let liveActivity: LiveActivityService
    private let systemAudioServer: SystemAudioStreamServer
    private let aiService: AIService
    private let locationService = LocationService()
    private let keepAlive = SilentAudioKeepAlive()
    private let pipController = CaptionPictureInPictureController()

    // MARK: - 会话上下文

    private var sessionID = UUID()
    private var sessionStart = Date()
    private var sessionEnd: Date?
    private var sourceIdentifier = ""
    private var targetIdentifier = ""
    private var lastVisualUpdate = Date.distantPast
    /// 实时预览节流：最近一次已发布的部分识别结果与发布时间
    private var latestPartialText = ""
    private var lastPartialPublish = Date.distantPast
    private var partialThrottleTask: Task<Void, Never>?
    /// 本次录制的地点名（定位完成后写入，用于「位置」标题）
    private var sessionLocationName: String?
    /// 本次录制自动生成的 AI 摘要（用于「AI 标题」）
    private var sessionSummary: String?
    private var locationTask: Task<Void, Never>?
    /// 打开系统广播选择器后的保活超时：用户取消选择时回收静音播放器
    private var broadcastPreparationTask: Task<Void, Never>?
    /// 识别会话启动中：避免同一广播被连接回调和首帧回调重复启动
    private var isStartingExternalRecognition = false
    /// 外部识别是否已成功启动；连接保持但会话失效时需要重新启动
    private var isExternalRecognitionRunning = false
    /// 外部识别启动代际：停止/重启后，旧的异步启动结果不能再改回运行状态
    private var externalRecognitionGeneration = 0
    /// 广播开始时 App 在后台，画中画自动启动被推迟到回到前台
    private var pendingAutoPiPStart = false
    /// 识别启动时刻：用于判断启动是否卡死（例如后台模型准备迟迟不返回）
    private var externalRecognitionStartAt: Date?
    /// 最近一次识别错误文案：恢复成功后自动清除对应提示
    private var lastRecognitionError: String?
    /// 识别异常自动重启的次数与时间窗，避免错误持续时无限重试
    private var recognitionRetryCount = 0
    private var lastRecognitionRetryAt = Date.distantPast
    private var recognitionRestartTask: Task<Void, Never>?
    /// 系统共享音频期间的自愈看门狗：保持监听、恢复保活、重启失效的识别
    private var systemAudioWatchdogTask: Task<Void, Never>?
    /// 点击广播按钮后的连接看门狗：扩展启动慢或监听器在后台失效时自动重建
    private var broadcastStartupWatchdogTask: Task<Void, Never>?
    /// 系统录屏/共享状态监听：开启即进入识别，停止即收尾
    private var screenCaptureObserver: NSObjectProtocol?
    /// 用户已在 App 内结束识别：等到系统共享真正停止前，忽略仍然到来的音频/连接
    private var isBroadcastDismissedByUser = false

    // MARK: - AI 分段缓冲

    private struct PendingSpeechChunk {
        let text: String
        let startTime: TimeInterval
    }

    private var pendingChunks: [PendingSpeechChunk] = []
    private var segmentationTask: Task<Void, Never>?
    private var segmentationRequestID = 0
    private var segmentationGeneration = UUID()
    private var isSegmentingPending = false
    /// 已落库的最近几段字幕，作为 AI 分段的上下文
    private var recentSegmentContext: [String] = []

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
        // 系统录屏开始/结束时立即响应，不依赖广播扩展的首次连接是否成功
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
        speechRecognizer.onFinalSegment = { [weak self] text, startTime in
            self?.handleFinalSegment(text, startTime: startTime)
        }
        speechRecognizer.onError = { [weak self] message in
            self?.handleError(message)
        }

        systemAudioServer.onAudioBuffer = { [weak self] buffer in
            guard let self, !self.isBroadcastDismissedByUser else { return }
            // 兜底检测：只要真的有共享音频进来，就视为广播已开始，
            // 避免连接就绪回调遗漏导致界面一直停在未开始状态
            if self.state != .listening {
                self.handleBroadcastStarted()
            }
            // 暂停时直接丢弃音频，广播与录屏不受影响
            guard !self.isRecognitionPaused else { return }
            self.speechRecognizer.appendExternalBuffer(buffer)
        }
        systemAudioServer.onStreamStarted = { [weak self] in
            guard let self, !self.isBroadcastDismissedByUser else { return }
            self.handleBroadcastStarted()
        }
        systemAudioServer.onStreamEnded = { [weak self] in
            self?.handleBroadcastEnded()
        }
        systemAudioServer.onStreamStalled = { [weak self] in
            self?.handleBroadcastStalled()
        }
    }

    var audioSourceMode: AudioSourceMode {
        settings.audioSourceMode
    }

    /// 识别期间按设置阻止屏幕自动熄灭；停止后立刻恢复系统自动息屏
    func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = state == .listening && settings.keepScreenOnWhileRecognizing
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
        systemAudioServer.start()
        isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
        if !isWaitingForBroadcast && !systemAudioServer.isReceivingAudio {
            errorMessage = "无法启动系统音频通道（本地端口被占用），请稍后重试。"
        }
    }

    /// 从后台回到前台时调用：广播可能仍在录屏，但主 App 的监听/识别已被系统暂停。
    /// 先检查广播是否真的还有心跳，再决定是否重建通道并重启识别会话。
    func recoverSystemAudioIfNeeded() {
        guard settings.audioSourceMode == .systemAudio else {
            prepareSystemAudioServer()
            return
        }
        if state == .listening {
            if !systemAudioServer.hasRecentActivity {
                // 连接看似还在但已收不到心跳：整体重建监听器，保留当前会话等待扩展重连
                systemAudioServer.restartListener()
                isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
                isExternalRecognitionRunning = false
                return
            }
            prepareSystemAudioServer()
            if !isExternalRecognitionRunning {
                startExternalRecognitionIfNeeded()
            }
            return
        }
        // 还没进入收听状态：系统共享可能已经开始，但监听器在后台被挂起后表面仍是 ready，
        // 实际不再接受连接。重建后等广播扩展自动重连（扩展会补发断线期间的音频）。
        systemAudioServer.restartListener()
        isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
    }

    /// 系统开始/停止录屏（含本 App 的广播共享）时立即响应：
    /// 开始就直接进入识别，停止就立刻收尾；不再依赖扩展首次连接是否成功。
    private func handleScreenCaptureChange() {
        guard settings.audioSourceMode == .systemAudio else { return }
        guard let screen = activeScreen else { return }
        if screen.isCaptured {
            // 用户已经在 App 内结束识别，只是系统共享还没停：不再自动恢复
            guard !isBroadcastDismissedByUser else { return }
            keepAlive.start()
            if state == .listening {
                // 已在收听：通道有活动就不打断，没有活动则重建监听等待扩展重连
                if !systemAudioServer.hasRecentActivity {
                    systemAudioServer.restartListener()
                    isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
                    isExternalRecognitionRunning = false
                }
                return
            }
            // 录屏刚开始：直接建立会话并启动识别，音频到达后会立即喂入
            handleBroadcastStarted()
        } else {
            // 系统共享真正停止：解除忽略标记，本次会话若仍在收听则立即收尾
            isBroadcastDismissedByUser = false
            infoMessage = nil
            if state == .listening {
                handleBroadcastEnded()
            }
        }
    }

    /// 当前场景所在的屏幕（窗口化 / 多窗口下取活跃场景）
    private var activeScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.screen
    }

    /// App 进入后台：只标记状态，不结束会话；后台收不到心跳属于正常现象。
    /// 注意 iPad 分屏时 App 可能只是 .inactive（仍可见、仍在工作），不能当成后台。
    func handleScenePhase(_ phase: ScenePhase) {
        systemAudioServer.setAppActive(phase != .background)
        if phase == .active {
            recoverSystemAudioIfNeeded()
            // 后台期间可能错过录屏状态通知，前台补一次
            handleScreenCaptureChange()
            if pendingAutoPiPStart, state == .listening {
                pendingAutoPiPStart = false
                autoStartVisualIfNeeded()
            }
        } else if phase == .background {
            // 系统广播扩展仍在采集，但主 App 可能随时被挂起；静音保活必须保持
            keepAlive.start()
        }
    }

    /// 用户在 App 内点击结束共享：立即结束识别并保存记录，系统共享由用户在控制中心停止。
    /// 系统广播面板可能迟迟不出现，不能让它决定收尾时机。
    func endSystemAudioFromButton() {
        isBroadcastDismissedByUser = true
        if state == .listening {
            stop()
        }
        infoMessage = "已停止识别；如果系统仍在共享屏幕，请在控制中心结束共享。"
    }

    func dismissInfoMessage() {
        infoMessage = nil
    }

    /// 打开系统广播选择器前调用：先启动本地监听和静音保活。
    /// App 在系统选择器出现后会立即进入后台，等到广播连上再启动保活可能已经被挂起。
    func prepareSystemAudioBroadcast() {
        isBroadcastDismissedByUser = false
        infoMessage = nil
        prepareSystemAudioServer()
        keepAlive.start()
        guard state != .listening else {
            // 结束共享时也要保持音频会话，直到系统控件真正停止广播
            return
        }
        // 开始共享：确保监听器在系统选择器期间保持可用
        startBroadcastStartupWatchdog()
        broadcastPreparationTask?.cancel()
        broadcastPreparationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, self.state != .listening else { return }
            self.keepAlive.stop()
            self.broadcastPreparationTask = nil
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
            let preview = livePartialText.isEmpty ? "正在聆听…" : livePartialText
            liveActivity.update(originalText: preview, translatedText: nil)
        }
    }

    /// 手动开启 / 关闭画中画字幕
    func togglePictureInPicture() {
        guard CaptionPictureInPictureController.isSupported else {
            errorMessage = "当前设备不支持画中画。"
            return
        }
        if isPictureInPictureActive {
            pipController.stop()
            return
        }
        pipController.shape = settings.pipShape
        _ = pipController.start()
        let preview = livePartialText.isEmpty ? "正在聆听…" : livePartialText
        pipController.update(original: preview, translated: nil)
    }

    /// 画中画字号设置变化后立即按当前字幕重绘
    func refreshPictureInPicture() {
        pipController.refresh()
    }

    /// 暂停 / 继续系统共享音频的识别；广播与录屏保持运行，不中断采集
    func toggleRecognitionPause() {
        guard state == .listening, audioSourceMode == .systemAudio else { return }
        isRecognitionPaused.toggle()
        if isRecognitionPaused {
            // 暂停视为当前句子结束：已识别内容先落库，实时预览清空
            flushPendingBuffer()
            resetPartialPreview()
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

        speechRecognizer.locale = Locale(identifier: sourceIdentifier)
        await speechRecognizer.start()

        if errorMessage == nil {
            state = .listening
            autoStartVisualIfNeeded()
        }
    }

    // MARK: - 系统音频模式

    private func handleBroadcastStarted() {
        broadcastStartupWatchdogTask?.cancel()
        broadcastStartupWatchdogTask = nil
        isBroadcastDismissedByUser = false
        infoMessage = nil
        isWaitingForBroadcast = false
        // 广播已经重新连接：即使界面还停在 listening，也要确认识别会话仍在运行，
        // 否则旧会话已失效时新的音频会全部被丢弃。
        if state == .listening, isExternalRecognitionRunning {
            keepAlive.start()
            startSystemAudioWatchdog()
            return
        }

        broadcastPreparationTask?.cancel()
        broadcastPreparationTask = nil

        let isResumingExistingSession = state == .listening
        errorMessage = nil
        if !isResumingExistingSession {
            resetForNewRecording()
        }

        speechRecognizer.locale = Locale(identifier: sourceIdentifier)
        state = .listening
        // 广播期间保持后台运行，确保本地音频服务器不被挂起
        keepAlive.start()
        autoStartVisualIfNeeded()
        startSystemAudioWatchdog()

        startExternalRecognitionIfNeeded()
    }

    private func startExternalRecognitionIfNeeded() {
        guard !isExternalRecognitionRunning, !isStartingExternalRecognition else { return }
        isStartingExternalRecognition = true
        isExternalRecognitionRunning = false
        externalRecognitionGeneration += 1
        let generation = externalRecognitionGeneration
        externalRecognitionStartAt = Date()
        // 上一次识别已失效时，残留的实时预览不再可信
        resetPartialPreview()

        Task { [weak self] in
            guard let self else { return }
            await self.translationService.setLanguagePair(
                source: Locale.Language(identifier: self.sourceIdentifier),
                target: Locale.Language(identifier: self.targetIdentifier)
            )
            await self.speechRecognizer.startExternalAudio()
            guard generation == self.externalRecognitionGeneration else { return }
            self.isStartingExternalRecognition = false
            self.externalRecognitionStartAt = nil
            guard self.speechRecognizer.isExternalAudioRunning else {
                // 启动失败不结束整场共享会话：错误已由 handleError 记录，看门狗限次重试
                return
            }
            self.isExternalRecognitionRunning = true
            self.recognitionRetryCount = 0
            // 识别恢复后自动清掉之前的识别错误提示，但保留通道类提示
            if let lastError = self.lastRecognitionError, self.errorMessage == lastError {
                self.errorMessage = nil
            }
            self.lastRecognitionError = nil
        }
    }

    private func handleBroadcastEnded() {
        isWaitingForBroadcast = systemAudioServer.isWaitingForBroadcast
        if state == .listening {
            stop()
        }
    }

    /// 连接已建立但持续收不到音频/心跳：多数是主 App 在后台被挂起。
    /// 保持会话与字幕，只重建通道并提示；扩展会自动重连。
    private func handleBroadcastStalled() {
        isWaitingForBroadcast = true
        isExternalRecognitionRunning = false
        guard state == .listening else { return }
        errorMessage = "系统音频通道已中断，正在重连；若仍未恢复，请结束共享后重新开始。"
    }

    // MARK: - 系统音频自愈

    /// 点击广播按钮后启动：扩展冷启动较慢，或主 App 的监听器在后台失效时，
    /// 周期性重建监听器，直到收到广播连接（最多约 90 秒）。
    private func startBroadcastStartupWatchdog() {
        broadcastStartupWatchdogTask?.cancel()
        broadcastStartupWatchdogTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(90)
            // 首次点击后立刻重建一次，排除监听器在后台挂起后“假 ready”的情况
            var lastRestartAt = Date.distantPast
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.state != .listening else {
                    self.broadcastStartupWatchdogTask = nil
                    return
                }
                // 每 9 秒重建一次，给广播扩展留出重连窗口
                guard Date().timeIntervalSince(lastRestartAt) >= 9 else { continue }
                lastRestartAt = Date()
                self.systemAudioServer.restartListener()
                self.isWaitingForBroadcast = self.systemAudioServer.isWaitingForBroadcast
            }
            guard let self else { return }
            self.broadcastStartupWatchdogTask = nil
        }
    }

    /// 共享期间每 3 秒自检：恢复被系统打断的保活、重建失效的监听器、
    /// 重启启动失败或卡死的识别会话，避免出现「广播在跑但一直没字幕」。
    private func startSystemAudioWatchdog() {
        guard systemAudioWatchdogTask == nil else { return }
        systemAudioWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.runSystemAudioWatchdogTick()
            }
        }
    }

    private func runSystemAudioWatchdogTick() {
        guard state == .listening, audioSourceMode == .systemAudio else { return }
        // 保活播放器可能被来电或媒体服务重置打断，未在播放时重新拉起
        keepAlive.ensureRunning()
        // 监听器被系统取消或端口丢失时自动重建（start 内部会判断状态）
        systemAudioServer.start()

        guard systemAudioServer.isReceivingAudio else { return }
        // 启动卡死超过 20 秒：作废本次启动，允许重新开始
        if isStartingExternalRecognition {
            if let startedAt = externalRecognitionStartAt,
               Date().timeIntervalSince(startedAt) > 20 {
                externalRecognitionGeneration += 1
                isStartingExternalRecognition = false
                externalRecognitionStartAt = nil
            } else {
                return
            }
        }
        guard !isExternalRecognitionRunning, !isRecognitionPaused else { return }
        startExternalRecognitionIfNeeded()
    }

    /// 记录一次识别重启；60 秒内最多 3 次，避免不可恢复的错误无限循环
    private func registerRecognitionRetry() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastRecognitionRetryAt) > 60 {
            recognitionRetryCount = 0
        }
        lastRecognitionRetryAt = now
        recognitionRetryCount += 1
        return recognitionRetryCount <= 3
    }

    private func scheduleRecognitionRestart() {
        recognitionRestartTask?.cancel()
        recognitionRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.state == .listening else { return }
            self.startExternalRecognitionIfNeeded()
        }
    }

    // MARK: - 收尾

    func stop() {
        isRecognitionPaused = false
        pendingAutoPiPStart = false
        externalRecognitionGeneration += 1
        isStartingExternalRecognition = false
        externalRecognitionStartAt = nil
        isExternalRecognitionRunning = false
        cancelBroadcastPreparation()
        speechRecognizer.stop()
        // 结束前把还没被 AI 整理的片段直接落库，避免丢失
        flushPendingBuffer()
        resetPartialPreview()
        teardownOutputs()
        sessionEnd = Date()
        state = .ended
        saveCurrentSession()
        generateAutoTitleIfNeeded()
    }

    func clearSegments() {
        resetPendingBuffer()
        segments = []
        failedTranslationIDs.removeAll()
        resetPartialPreview()
        sessionStart = Date()
    }

    /// 字幕气泡入场动画已播放，写回标记避免列表复用或滚动复现时重播
    func markSegmentAnimated(_ segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }),
              !segments[index].hasAnimated else { return }
        segments[index].hasAnimated = true
    }

    /// AI 润色结果回填到对应字幕片段
    func applyPolishedText(_ text: String, to segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].polishedText = text
        if state == .ended {
            saveCurrentSession()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    /// 接入 SwiftUI translationTask 提供的系统翻译会话
    /// 保持 translationTask 的 action 存活：TranslationSession 只在 action 执行期间有效，
    /// 提前返回后再用旧 session 翻译属于未定义行为，可能出现闪退。
    func keepTranslationSessionAlive(_ session: TranslationSession) async {
        let token = translationService.attach(session: session)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        translationService.detach(token: token)
    }

    // MARK: - 会话上下文 / 浮窗自动选择

    /// 新录制开始前重置会话数据与所有缓冲区
    private func resetForNewRecording() {
        isRecognitionPaused = false
        recognitionRetryCount = 0
        lastRecognitionRetryAt = .distantPast
        lastRecognitionError = nil
        recognitionRestartTask?.cancel()
        recognitionRestartTask = nil
        segments = []
        failedTranslationIDs.removeAll()
        resetPartialPreview()
        resetPendingBuffer()
        startNewSessionContext()
    }

    /// 统一关闭灵动岛 / 画中画并停止静音保活
    private func teardownOutputs() {
        broadcastStartupWatchdogTask?.cancel()
        broadcastStartupWatchdogTask = nil
        systemAudioWatchdogTask?.cancel()
        systemAudioWatchdogTask = nil
        recognitionRestartTask?.cancel()
        recognitionRestartTask = nil
        liveActivity.end()
        keepAlive.stop()
        pipController.stop()
        isLiveActivityActive = false
        isPictureInPictureActive = false
    }

    private func cancelBroadcastPreparation() {
        broadcastPreparationTask?.cancel()
        broadcastPreparationTask = nil
    }

    /// 每次开始录制时重置会话标识、计时与地点
    private func startNewSessionContext() {
        sessionID = UUID()
        sessionStart = Date()
        sessionEnd = nil
        sourceIdentifier = settings.sourceLanguageIdentifier
        targetIdentifier = settings.targetLanguageIdentifier
        sessionLocationName = nil
        sessionSummary = nil
        startLocationCapture()
    }

    /// 定位仅用于「位置」标题；未选择该标题时不请求权限
    private func startLocationCapture() {
        locationTask?.cancel()
        guard settings.recordTitleStyle == .snippet else { return }
        let currentSessionID = sessionID
        locationTask = Task { [weak self] in
            guard let self else { return }
            let placeName = await self.locationService.currentPlaceName()
            guard !Task.isCancelled, self.sessionID == currentSessionID else { return }
            guard let placeName, !placeName.isEmpty else { return }
            self.sessionLocationName = placeName
            // 定位结果晚于停止时，补写已保存的记录
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }

    /// 自动模式：有灵动岛的 iPhone 用灵动岛；iPad 等默认用画中画
    private var effectiveVisualMode: VisualMode {
        switch settings.visualMode {
        case .auto:
            return UIDevice.current.userInterfaceIdiom == .pad ? .pictureInPicture : .liveActivity
        case .liveActivity, .pictureInPicture:
            return settings.visualMode
        }
    }

    private func autoStartVisualIfNeeded() {
        guard settings.autoStartLiveActivity else { return }
        switch effectiveVisualMode {
        case .liveActivity:
            isLiveActivityActive = liveActivity.start(languagePair: "\(sourceIdentifier) → \(targetIdentifier)")
            if isLiveActivityActive {
                liveActivity.update(originalText: "正在聆听…", translatedText: nil)
            }
        case .pictureInPicture:
            guard CaptionPictureInPictureController.isSupported else { return }
            // 画中画只允许在前台启动；广播开始时 App 通常已在后台，
            // 强行启动可能被系统拒绝甚至闪退，改为回到前台后补启动
            guard UIApplication.shared.applicationState == .active else {
                pendingAutoPiPStart = true
                return
            }
            pendingAutoPiPStart = false
            pipController.shape = settings.pipShape
            _ = pipController.start()
            pipController.update(original: "正在聆听…", translated: nil)
        case .auto:
            break
        }
    }

    // MARK: - 私有

    private func handleError(_ message: String) {
        cancelBroadcastPreparation()
        errorMessage = message
        lastRecognitionError = message
        isRecognitionPaused = false
        // 作废在途的识别启动，避免旧任务稍后把状态改回去
        externalRecognitionGeneration += 1
        isStartingExternalRecognition = false
        externalRecognitionStartAt = nil
        isExternalRecognitionRunning = false

        // 广播仍在继续时只重启识别，不结束整场共享会话；
        // 否则一次偶发的识别中断就会让后面的音频全部没人接收
        if state == .listening,
           audioSourceMode == .systemAudio,
           systemAudioServer.isReceivingAudio,
           registerRecognitionRetry() {
            scheduleRecognitionRestart()
            return
        }

        flushPendingBuffer()
        state = .ended
        teardownOutputs()
    }

    /// 以约 12Hz 的频率发布部分识别结果，避免高频刷新造成文字抖动；尾部补发保证文本不丢失
    private func publishPartialText(_ text: String) {
        latestPartialText = text
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPartialPublish)
        if elapsed >= 0.08 {
            lastPartialPublish = now
            livePartialText = text
            pushPartialUpdate(text)
            return
        }
        partialThrottleTask?.cancel()
        let delay = UInt64((0.08 - elapsed) * 1_000_000_000)
        partialThrottleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, !self.latestPartialText.isEmpty else { return }
            self.lastPartialPublish = Date()
            self.livePartialText = self.latestPartialText
            self.pushPartialUpdate(self.latestPartialText)
        }
    }

    /// 清空实时预览并取消未执行的节流补发
    private func resetPartialPreview() {
        partialThrottleTask?.cancel()
        partialThrottleTask = nil
        latestPartialText = ""
        livePartialText = ""
    }

    /// 部分识别结果节流同步到灵动岛 / 画中画（约 1 秒一次）
    private func pushPartialUpdate(_ text: String) {
        guard !text.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastVisualUpdate) > 1.0 else { return }
        lastVisualUpdate = now
        if isLiveActivityActive {
            liveActivity.update(originalText: text, translatedText: nil)
        }
        if isPictureInPictureActive {
            pipController.update(original: text, translated: nil)
        }
    }

    private func handleFinalSegment(_ text: String, startTime: TimeInterval) {
        // 一句结束：先清空实时预览；有 AI 时先进入缓冲，停顿后整理成完整句子
        resetPartialPreview()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // AI 不可用时保持原来的即时落库
        guard aiService.isAvailable else {
            appendCommittedSegment(trimmed, startTime: startTime)
            return
        }

        pendingChunks.append(PendingSpeechChunk(text: trimmed, startTime: startTime))
        pendingText = pendingChunks.map(\.text).joined()
        updateVisuals(original: trimmed, translated: nil)
        schedulePendingSegmentation()
    }

    /// 把最终确定的句子落库，并异步回填译文
    private func appendCommittedSegment(_ text: String, startTime: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let segment = CaptionSegment(originalText: trimmed, startTime: startTime)
        segments.append(segment)
        recentSegmentContext.append(trimmed)
        if recentSegmentContext.count > 3 {
            recentSegmentContext.removeFirst(recentSegmentContext.count - 3)
        }
        let segmentID = segment.id
        updateVisuals(original: trimmed, translated: nil)

        guard settings.realtimeTranslationEnabled else { return }

        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translationService.translate(trimmed)
            guard let translated, !translated.isEmpty else {
                self.failedTranslationIDs.insert(segmentID)
                return
            }
            guard let index = self.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            self.segments[index].translatedText = translated
            self.failedTranslationIDs.remove(segmentID)
            self.updateVisuals(original: trimmed, translated: translated)
            // 会话结束后仍有译文回填时，刷新已保存的记录
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }

    // MARK: - AI 分段

    /// 停顿约 0.3 秒后交给 AI 合并/切分；缓冲过长时立即整理
    private func schedulePendingSegmentation() {
        guard !pendingChunks.isEmpty else { return }
        guard aiService.isAvailable else {
            flushPendingBuffer()
            return
        }

        segmentationRequestID += 1
        let requestID = segmentationRequestID
        let force = pendingText.count >= 120 || pendingChunks.count >= 4
        // 已经以句末标点结束时立即整理；否则多等一会儿，
        // 让后续碎片并进来，避免每句话都单独成段
        let endsWithSentenceMark = pendingText.last.map { "。！？!?…".contains($0) } ?? false
        let delay: UInt64 = endsWithSentenceMark ? 300_000_000 : 800_000_000
        segmentationTask = Task { [weak self] in
            if !force {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self,
                  !Task.isCancelled,
                  self.segmentationRequestID == requestID else { return }
            await self.segmentAndCommitPending()
        }
    }

    private func segmentAndCommitPending() async {
        guard !isSegmentingPending, !pendingChunks.isEmpty else { return }
        isSegmentingPending = true
        defer { isSegmentingPending = false }

        let generation = segmentationGeneration
        let chunks = pendingChunks
        let original = chunks.map(\.text).joined()
        guard !original.isEmpty else {
            pendingChunks.removeAll()
            pendingText = ""
            return
        }

        let sentences = await aiService.segmentSentences(
            original,
            context: recentSegmentContext.isEmpty ? nil : recentSegmentContext.joined(separator: "\n")
        )
        guard generation == segmentationGeneration else {
            if !pendingChunks.isEmpty {
                schedulePendingSegmentation()
            }
            return
        }

        // 只移除本次已处理的片段；AI 处理期间新到的片段继续保留
        let processedCount = min(chunks.count, pendingChunks.count)
        pendingChunks.removeFirst(processedCount)
        pendingText = pendingChunks.map(\.text).joined()

        let finalSentences = sentences ?? Self.fallbackSegments(for: original)
        let times = startTimes(for: finalSentences, chunks: chunks)
        for (index, sentence) in finalSentences.enumerated() {
            let time = times.indices.contains(index) ? times[index] : (chunks.first?.startTime ?? 0)
            appendCommittedSegment(sentence, startTime: time)
        }

        if !pendingChunks.isEmpty {
            schedulePendingSegmentation()
        }
    }

    /// 结束或清空时直接按标点兜底落库，避免 AI 未返回导致字幕丢失
    private func flushPendingBuffer() {
        segmentationRequestID += 1
        segmentationGeneration = UUID()
        let chunks = pendingChunks
        pendingChunks.removeAll()
        pendingText = ""
        guard !chunks.isEmpty else { return }

        let original = chunks.map(\.text).joined()
        let sentences = Self.fallbackSegments(for: original)
        let times = startTimes(for: sentences, chunks: chunks)
        for (index, sentence) in sentences.enumerated() {
            let time = times.indices.contains(index) ? times[index] : (chunks.first?.startTime ?? 0)
            appendCommittedSegment(sentence, startTime: time)
        }
    }

    private func resetPendingBuffer() {
        segmentationRequestID += 1
        segmentationGeneration = UUID()
        pendingChunks.removeAll()
        pendingText = ""
        recentSegmentContext.removeAll()
    }

    /// AI 不可用或返回无效内容时，用本地标点做兜底切分
    private static func fallbackSegments(for text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?\n".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }

    /// 根据句子在原文中的位置，映射到所属识别片段的起始时间
    private func startTimes(for sentences: [String], chunks: [PendingSpeechChunk]) -> [TimeInterval] {
        let original = chunks.map(\.text).joined()
        var searchStart = original.startIndex
        var times: [TimeInterval] = []
        for sentence in sentences {
            if searchStart < original.endIndex,
               let range = original.range(of: sentence, range: searchStart..<original.endIndex) {
                let offset = original.distance(from: original.startIndex, to: range.lowerBound)
                times.append(startTime(at: offset, in: chunks))
                searchStart = range.upperBound
            } else {
                times.append(chunks.first?.startTime ?? 0)
            }
        }
        return times
    }

    private func startTime(at offset: Int, in chunks: [PendingSpeechChunk]) -> TimeInterval {
        var cumulative = 0
        for chunk in chunks {
            let length = chunk.text.count
            if offset < cumulative + length {
                return chunk.startTime
            }
            cumulative += length
        }
        return chunks.last?.startTime ?? 0
    }

    /// 手动重试某一条未生成译文的字幕
    func retryTranslation(for segment: CaptionSegment) {
        guard settings.realtimeTranslationEnabled else { return }
        let segmentID = segment.id
        failedTranslationIDs.remove(segmentID)

        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translationService.translate(segment.originalText)
            guard let translated, !translated.isEmpty,
                  let index = self.segments.firstIndex(where: { $0.id == segmentID }) else {
                self.failedTranslationIDs.insert(segmentID)
                return
            }
            self.segments[index].translatedText = translated
            self.failedTranslationIDs.remove(segmentID)
            // 只有最新一条需要同步到灵动岛 / 画中画
            if self.segments.last?.id == segmentID {
                self.updateVisuals(original: segment.originalText, translated: translated)
            }
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }

    private func updateVisuals(original: String, translated: String?) {
        if isLiveActivityActive {
            liveActivity.update(originalText: original, translatedText: translated)
        }
        if isPictureInPictureActive {
            pipController.update(original: original, translated: translated)
        }
    }

    private func saveCurrentSession() {
        guard !segments.isEmpty else { return }
        let session = TranscriptSession(
            id: sessionID,
            startedAt: sessionStart,
            endedAt: sessionEnd ?? Date(),
            sourceLanguageIdentifier: sourceIdentifier,
            targetLanguageIdentifier: targetIdentifier,
            segments: segments,
            summary: sessionSummary,
            locationName: sessionLocationName
        )
        transcriptStore.save(session)
    }

    /// 「AI 标题」模式下，录制结束后自动生成摘要，标题取摘要首行
    private func generateAutoTitleIfNeeded() {
        guard settings.recordTitleStyle == .aiTitle,
              sessionSummary == nil,
              !segments.isEmpty,
              aiService.isAvailable else { return }

        let targetSessionID = sessionID
        let snapshot = TranscriptSession(
            id: targetSessionID,
            startedAt: sessionStart,
            endedAt: sessionEnd ?? Date(),
            sourceLanguageIdentifier: sourceIdentifier,
            targetLanguageIdentifier: targetIdentifier,
            segments: segments,
            locationName: sessionLocationName
        )

        Task { [weak self] in
            guard let self,
                  let summary = await self.aiService.summarize(session: snapshot) else { return }
            guard self.sessionID == targetSessionID else { return }
            self.sessionSummary = summary
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }
}
