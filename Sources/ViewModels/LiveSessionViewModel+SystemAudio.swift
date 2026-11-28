import AVFoundation
import SwiftUI
import UIKit

struct SystemAudioState {
    var preparationTask: Task<Void, Never>?
    var startupWatchdog: Task<Void, Never>?
    var streamWatchdog: Task<Void, Never>?
    var recognitionTask: Task<Void, Never>?
    var recognitionStartedAt: Date?
    var recognitionHealthySince: Date?
    var recognitionRetryAfter = Date.distantPast
    var recognitionRetryDelay: TimeInterval = 0.8
    var recognitionError: String?
    var lastListenerRestart = Date.distantPast
    var dismissedByUser = false
}

extension LiveSessionViewModel {
    /// 广播心跳让暂停和浮窗可提前使用，识别器等到首个有效音频包才启动。
    func handleBroadcastHeartbeat() {
        guard audioSourceMode == .systemAudio, state != .listening, !systemAudio.dismissedByUser else { return }
        beginSystemAudioSession()
    }

    /// 重连后的音频继续写入当前会话。
    func receiveSystemAudio(_ buffer: AVAudioPCMBuffer) {
        guard audioSourceMode == .systemAudio, !systemAudio.dismissedByUser else { return }
        if state != .listening {
            beginSystemAudioSession()
        }
        if isWaitingForBroadcast {
            isWaitingForBroadcast = false
        }
        guard !isRecognitionPaused else { return }
        speakerDiarization.append(buffer)
        speechRecognizer.appendExternalBuffer(buffer)
        startExternalRecognitionIfNeeded()
    }

    func prepareSystemAudioServer() {
        _ = systemAudioServer.start()
        isWaitingForBroadcast = !systemAudioServer.isReceivingAudio
    }

    /// 启动广播选择器前先拉起静音保活，以便切到其他 App 后也能接收 PCM。
    func prepareSystemAudioBroadcast() {
        systemAudio.dismissedByUser = false
        infoMessage = nil
        prepareSystemAudioServer()
        keepAlive.start()
        guard state != .listening else { return }

        if !systemAudioServer.hasRecentActivity {
            restartSystemAudioListenerIfNeeded()
        }
        systemAudio.preparationTask?.cancel()
        systemAudio.preparationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cancelBroadcastPreparation()
            self.keepAlive.stop()
        }
        startBroadcastStartupWatchdog()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        systemAudioServer.setAppActive(phase == .active)
        guard audioSourceMode == .systemAudio else { return }
        if phase == .active {
            handleScreenCaptureChange()
            if pendingAutoPiPStart, state == .listening {
                pendingAutoPiPStart = false
                autoStartVisualIfNeeded()
            }
        } else if phase == .background {
            keepAlive.ensureRunning()
        }
    }

    /// 屏幕采集状态只用于辅助保活和恢复监听。实际音频和扩展的 STOP 决定会话起止。
    func handleScreenCaptureChange() {
        guard audioSourceMode == .systemAudio else { return }
        prepareSystemAudioServer()
        guard !systemAudioServer.hasRecentActivity else { return }
        guard state == .listening || systemAudio.preparationTask != nil || activeScreen?.isCaptured == true else {
            systemAudio.dismissedByUser = false
            infoMessage = nil
            return
        }
        guard !systemAudio.dismissedByUser else { return }
        keepAlive.start()
        restartSystemAudioListenerIfNeeded()
    }

    func toggleRecognitionPause() {
        guard state == .listening, audioSourceMode == .systemAudio else { return }
        isRecognitionPaused.toggle()
        if isRecognitionPaused {
            flushPendingBuffer()
            resetPartialPreview()
        } else if systemAudioServer.isReceivingAudio {
            startExternalRecognitionIfNeeded()
        }
    }

    func endSystemAudioFromButton() {
        systemAudio.dismissedByUser = true
        if state == .listening {
            stop()
        }
        infoMessage = "已停止识别；如果系统仍在共享屏幕，请在控制中心结束共享。"
    }

    func dismissInfoMessage() {
        infoMessage = nil
    }

    func handleBroadcastEnded() {
        systemAudio.dismissedByUser = false
        guard audioSourceMode == .systemAudio else { return }
        infoMessage = nil
        isWaitingForBroadcast = true
        if state == .listening {
            stop()
        } else if systemAudio.preparationTask != nil {
            cancelBroadcastPreparation()
            keepAlive.stop()
        }
    }

    func handleBroadcastStalled() {
        guard audioSourceMode == .systemAudio, !systemAudio.dismissedByUser else { return }
        isWaitingForBroadcast = true
    }

    func handleBroadcastReconnectTimeout() {
        guard audioSourceMode == .systemAudio else { return }
        if activeScreen?.isCaptured == true {
            if state == .listening, !systemAudio.dismissedByUser {
                restartSystemAudioListenerIfNeeded()
            }
            return
        }
        if state == .listening || systemAudio.dismissedByUser {
            handleBroadcastEnded()
        }
    }

    func handleExternalRecognitionError(_ message: String) {
        let now = Date()
        if let healthySince = systemAudio.recognitionHealthySince, now.timeIntervalSince(healthySince) >= 20 {
            resetExternalRecognitionRetry()
        }
        systemAudio.recognitionHealthySince = nil
        errorMessage = message
        systemAudio.recognitionError = message
        systemAudio.recognitionRetryAfter = now.addingTimeInterval(systemAudio.recognitionRetryDelay)
        systemAudio.recognitionRetryDelay = min(15, systemAudio.recognitionRetryDelay * 2)
    }

    func resetExternalRecognitionRetry() {
        systemAudio.recognitionHealthySince = nil
        systemAudio.recognitionRetryAfter = .distantPast
        systemAudio.recognitionRetryDelay = 0.8
        systemAudio.recognitionError = nil
    }

    func stopSystemAudioRecovery() {
        if systemAudio.preparationTask != nil {
            keepAlive.stop()
        }
        cancelBroadcastPreparation()
        systemAudio.streamWatchdog?.cancel()
        systemAudio.streamWatchdog = nil
        cancelRecognitionStart()
        resetExternalRecognitionRetry()
    }

    // MARK: - 共享音频会话

    private var activeScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.screen
    }

    private func beginSystemAudioSession() {
        cancelBroadcastPreparation()
        errorMessage = nil
        infoMessage = nil
        isWaitingForBroadcast = !systemAudioServer.isReceivingAudio
        resetForNewRecording()
        state = .listening
        keepAlive.start()
        autoStartVisualIfNeeded()
        startSpeakerDiarizationIfNeeded()
        startSystemAudioWatchdog()
    }

    private func startExternalRecognitionIfNeeded() {
        guard state == .listening, audioSourceMode == .systemAudio, !isRecognitionPaused,
              !speechRecognizer.isExternalAudioRunning, systemAudio.recognitionTask == nil else { return }
        let now = Date()
        guard now >= systemAudio.recognitionRetryAfter else { return }

        systemAudio.recognitionStartedAt = now
        resetPartialPreview()
        systemAudio.recognitionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.translationService.setLanguagePair(
                source: Locale.Language(identifier: self.sourceIdentifier),
                target: Locale.Language(identifier: self.targetIdentifier)
            )
            guard !Task.isCancelled else { return }
            self.speechRecognizer.locale = Locale(identifier: self.sourceIdentifier)
            await self.speechRecognizer.startExternalAudio(sessionStartedAt: self.sessionStart)
            guard !Task.isCancelled else { return }
            self.finishExternalRecognitionStart()
        }
    }

    private func finishExternalRecognitionStart() {
        systemAudio.recognitionTask = nil
        systemAudio.recognitionStartedAt = nil
        guard speechRecognizer.isExternalAudioRunning else {
            if Date() >= systemAudio.recognitionRetryAfter {
                handleExternalRecognitionError("语音识别暂未就绪，正在重试。")
            }
            return
        }

        if let previousError = systemAudio.recognitionError, errorMessage == previousError {
            errorMessage = nil
        }
        systemAudio.recognitionError = nil
        systemAudio.recognitionHealthySince = Date()
    }

    private func cancelRecognitionStart() {
        systemAudio.recognitionTask?.cancel()
        systemAudio.recognitionTask = nil
        systemAudio.recognitionStartedAt = nil
    }

    private func cancelBroadcastPreparation() {
        systemAudio.preparationTask?.cancel()
        systemAudio.preparationTask = nil
        systemAudio.startupWatchdog?.cancel()
        systemAudio.startupWatchdog = nil
    }

    private func restartSystemAudioListenerIfNeeded() {
        let now = Date()
        guard !systemAudioServer.hasRecentActivity,
              now.timeIntervalSince(systemAudio.lastListenerRestart) >= 5 else { return }
        systemAudio.lastListenerRestart = now
        systemAudioServer.restartListener()
        isWaitingForBroadcast = true
    }

    private func startBroadcastStartupWatchdog() {
        guard systemAudio.startupWatchdog == nil else { return }
        systemAudio.startupWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.keepAlive.ensureRunning()
                self.restartSystemAudioListenerIfNeeded()
            }
        }
    }

    private func startSystemAudioWatchdog() {
        guard systemAudio.streamWatchdog == nil else { return }
        systemAudio.streamWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkSystemAudio()
            }
        }
    }

    private func checkSystemAudio() {
        keepAlive.ensureRunning()
        _ = systemAudioServer.start()
        if UIApplication.shared.applicationState == .background {
            restartSystemAudioListenerIfNeeded()
        }
        if let startedAt = systemAudio.recognitionStartedAt, Date().timeIntervalSince(startedAt) > 45 {
            cancelRecognitionStart()
            handleExternalRecognitionError("语音识别启动超时，正在重试。")
        }
        if systemAudioServer.isReceivingAudio {
            startExternalRecognitionIfNeeded()
        }
    }
}
