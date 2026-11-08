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

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var segments: [CaptionSegment] = []
    @Published var livePartialText = ""
    @Published var errorMessage: String?
    /// 灵动岛字幕是否已开启（由用户手动触发或按设置自动开启）
    @Published private(set) var isLiveActivityActive = false
    /// 系统音频模式下是否正在等待广播连接
    @Published private(set) var isWaitingForBroadcast = false
    /// 画中画字幕是否已激活
    @Published private(set) var isPictureInPictureActive = false

    // MARK: - 依赖

    private let speechRecognizer: any SpeechRecognizing
    private let translationService: any TextTranslating
    private let settings: SettingsStore
    private let transcriptStore: TranscriptStore
    private let liveActivity: LiveActivityService
    private let systemAudioServer: SystemAudioStreamServer
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
    /// 本次录制的地点名（定位完成后写入，用于「位置」标题）
    private var sessionLocationName: String?
    private var locationTask: Task<Void, Never>?

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
        pipController.onStateChange = { [weak self] active in
            self?.isPictureInPictureActive = active
        }
        wireCallbacks()
    }

    private func wireCallbacks() {
        speechRecognizer.onPartialUpdate = { [weak self] text in
            guard let self else { return }
            self.livePartialText = text
            self.pushPartialUpdate(text)
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

    // MARK: - 麦克风模式

    private func startMicrophone() async {
        guard state != .listening else { return }
        errorMessage = nil
        segments = []
        livePartialText = ""
        startNewSessionContext()

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
        isWaitingForBroadcast = false
        guard state != .listening else { return }

        errorMessage = nil
        segments = []
        livePartialText = ""
        startNewSessionContext()

        speechRecognizer.locale = Locale(identifier: sourceIdentifier)
        state = .listening
        // 广播期间保持后台运行，确保本地音频服务器不被挂起
        keepAlive.start()
        autoStartVisualIfNeeded()

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
        keepAlive.stop()
        pipController.stop()
        isLiveActivityActive = false
        isPictureInPictureActive = false
        sessionEnd = Date()
        state = .ended
        saveCurrentSession()
    }

    func clearSegments() {
        segments = []
        livePartialText = ""
        sessionStart = Date()
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
    func attachTranslationSession(_ session: TranslationSession) {
        translationService.attach(session: session)
    }

    // MARK: - 会话上下文 / 浮窗自动选择

    /// 每次开始录制时重置会话标识、计时与地点
    private func startNewSessionContext() {
        sessionID = UUID()
        sessionStart = Date()
        sessionEnd = nil
        sourceIdentifier = settings.sourceLanguageIdentifier
        targetIdentifier = settings.targetLanguageIdentifier
        sessionLocationName = nil
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
            pipController.shape = settings.pipShape
            _ = pipController.start()
            pipController.update(original: "正在聆听…", translated: nil)
        case .auto:
            break
        }
    }

    // MARK: - 私有

    private func handleError(_ message: String) {
        errorMessage = message
        state = .ended
        liveActivity.end()
        keepAlive.stop()
        pipController.stop()
        isLiveActivityActive = false
        isPictureInPictureActive = false
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
        // 一句结束：清空实时预览，顶部切换到该句的原文并等待译文回填
        livePartialText = ""
        let segment = CaptionSegment(originalText: text, startTime: startTime)
        segments.append(segment)
        let segmentID = segment.id
        updateVisuals(original: text, translated: nil)

        // 异步翻译，完成后回填对应片段
        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translationService.translate(text)
            guard let translated,
                  let index = self.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            self.segments[index].translatedText = translated
            self.updateVisuals(original: text, translated: translated)
            // 会话结束后仍有译文回填时，刷新已保存的记录
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
            locationName: sessionLocationName
        )
        transcriptStore.save(session)
    }
}