import Foundation
import UIKit

extension LiveSessionViewModel {
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

    func resetAutomaticVisuals() {
        didAttemptAutoStartVisual = false
        pendingAutoPiPStart = false
        pendingAutoPiPTask?.cancel()
        pendingAutoPiPTask = nil
    }

    func teardownOutputs() {
        resetAutomaticVisuals()
        speakerDiarization.stop()
        liveActivity.end()
        keepAlive.stop()
        pipController.stop()
        isLiveActivityActive = false
        isPictureInPictureActive = false
    }

    /// 每次开始录制时重置会话标识、计时与地点
    func startNewSessionContext() {
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

    /// 实验性说话人分离：设置开启后随录制启动，模型下载/初始化在后台进行
    func startSpeakerDiarizationIfNeeded() {
        guard settings.speakerDiarizationExperiment else { return }
        let start = sessionStart
        Task { await speakerDiarization.start(sessionStart: start) }
    }

    func autoStartVisualIfNeeded() {
        guard settings.autoStartLiveActivity, !didAttemptAutoStartVisual else { return }
        switch effectiveVisualMode {
        case .liveActivity:
            guard !isLiveActivityActive else { return }
            isLiveActivityActive = liveActivity.start(languagePair: "\(sourceIdentifier) → \(targetIdentifier)")
            if isLiveActivityActive {
                didAttemptAutoStartVisual = true
                liveActivity.update(originalText: "正在聆听…", translatedText: nil)
            }
        case .pictureInPicture:
            guard CaptionPictureInPictureController.isSupported else { return }
            guard !isPictureInPictureActive else { return }
            // 画中画只允许在前台启动；广播开始时 App 通常已在后台，
            // 强行启动可能被系统拒绝甚至闪退，改为回到前台后补启动
            guard UIApplication.shared.applicationState == .active else {
                pendingAutoPiPStart = true
                schedulePendingAutoPiPStart()
                return
            }
            pendingAutoPiPStart = false
            pendingAutoPiPTask?.cancel()
            pendingAutoPiPTask = nil
            didAttemptAutoStartVisual = true
            pipController.shape = settings.pipShape
            _ = pipController.start()
            pipController.update(original: "正在聆听…", translated: nil)
        case .auto:
            break
        }
    }

    /// 系统面板可能吞掉 scenePhase 回调：轮询等待 App 回到前台后补启动画中画
    private func schedulePendingAutoPiPStart() {
        guard pendingAutoPiPTask == nil else { return }
        pendingAutoPiPTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.pendingAutoPiPStart else { return }
                guard self.state == .listening else { continue }
                guard UIApplication.shared.applicationState == .active else { continue }
                self.pendingAutoPiPStart = false
                self.pendingAutoPiPTask = nil
                self.autoStartVisualIfNeeded()
                return
            }
            self?.pendingAutoPiPTask = nil
        }
    }

    /// 部分识别结果节流同步到灵动岛 / 画中画（约 1 秒一次）
    func pushPartialUpdate(_ text: String) {
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

    func updateVisuals(original: String, translated: String?) {
        if isLiveActivityActive {
            liveActivity.update(originalText: original, translatedText: translated)
        }
        if isPictureInPictureActive {
            pipController.update(original: original, translated: translated)
        }
    }

    func saveCurrentSession() {
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
    func generateAutoTitleIfNeeded() {
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
