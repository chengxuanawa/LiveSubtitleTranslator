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

    /// 实时气泡展示的完整文本：待整理片段 + 当前实时部分
    var liveDisplayText: String {
        pendingText + livePartialText
    }
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
        wireCallbacks()
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
        failedTranslationIDs.removeAll()
        resetPartialPreview()
        resetPendingBuffer()
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
        failedTranslationIDs.removeAll()
        resetPartialPreview()
        resetPendingBuffer()
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
        // 结束前把还没被 AI 整理的片段直接落库，避免丢失
        flushPendingBuffer()
        resetPartialPreview()
        liveActivity.end()
        keepAlive.stop()
        pipController.stop()
        isLiveActivityActive = false
        isPictureInPictureActive = false
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
        flushPendingBuffer()
        state = .ended
        liveActivity.end()
        keepAlive.stop()
        pipController.stop()
        isLiveActivityActive = false
        isPictureInPictureActive = false
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
        segmentationTask = Task { [weak self] in
            if !force {
                try? await Task.sleep(nanoseconds: 300_000_000)
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

        let sentences = await aiService.segmentSentences(original)
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