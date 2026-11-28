import AVFoundation
import SwiftUI
import UIKit

enum SystemAudioInputStage: Equatable {
    case waitingForBroadcast
    case waitingForAudio
    case waitingForSound
    case startingRecognition
    case listening

    var placeholder: String {
        switch self {
        case .waitingForBroadcast: return "等待 SubLingo 广播…"
        case .waitingForAudio: return "广播已连接，等待音频…"
        case .waitingForSound: return "已收到音频，等待有声内容…"
        case .startingRecognition: return "已收到声音，正在启动识别…"
        case .listening: return "已收到声音，等待可识别语音…"
        }
    }
}

struct SystemAudioState {
    var preparationDeadline: ContinuousClock.Instant?
    var monitorTask: Task<Void, Never>?
    var recognitionTask: Task<Void, Never>?
    var recognitionStartedAt: ContinuousClock.Instant?
    var recognitionHealthySince: ContinuousClock.Instant?
    var recognitionRetryAfter: ContinuousClock.Instant?
    var recognitionRetryDelay: TimeInterval = 0.8
    var recognitionError: String?
    var lastListenerRestart: ContinuousClock.Instant?
    var dismissedByUser = false
    var isBroadcastConnected = false
    var latestAudioPacket: ContinuousClock.Instant?
    var latestSound: ContinuousClock.Instant?
}

extension LiveSessionViewModel {
    /// 广播心跳让暂停和浮窗可提前使用，识别器等到首个有效音频包才启动。
    func handleBroadcastHeartbeat() {
        guard audioSourceMode == .systemAudio, !systemAudio.dismissedByUser else { return }
        systemAudio.isBroadcastConnected = true
        refreshSystemAudioInputStage()
        if state != .listening {
            beginSystemAudioSession()
        }
    }

    /// 重连后的音频继续写入当前会话。
    func receiveSystemAudio(_ buffer: AVAudioPCMBuffer) {
        guard audioSourceMode == .systemAudio, !systemAudio.dismissedByUser else { return }
        systemAudio.isBroadcastConnected = true
        let now = ContinuousClock().now
        systemAudio.latestAudioPacket = now
        if Self.hasAudibleSamples(buffer) {
            systemAudio.latestSound = now
        }
        refreshSystemAudioInputStage(now: now)
        if state != .listening {
            beginSystemAudioSession()
        }
        guard !isRecognitionPaused else { return }
        speakerDiarization.append(buffer)
        speechRecognizer.appendExternalBuffer(buffer)
        startExternalRecognitionIfNeeded()
    }

    func prepareSystemAudioServer() {
        _ = systemAudioServer.start()
    }

    /// 启动广播选择器前先拉起静音保活，以便切到其他 App 后也能接收 PCM。
    func prepareSystemAudioBroadcast() {
        systemAudio.dismissedByUser = false
        infoMessage = nil
        prepareSystemAudioServer()
        keepAlive.start()
        guard state != .listening else { return }

        restartSystemAudioListenerIfNeeded()
        systemAudio.preparationDeadline = ContinuousClock().now.advanced(by: .seconds(90))
        startSystemAudioMonitor()
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
        guard state == .listening || systemAudio.preparationDeadline != nil || activeScreen?.isCaptured == true else {
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
        clearSystemAudioInput()
        if state == .listening {
            stop()
        } else {
            stopSystemAudioRecovery()
        }
    }

    func handleBroadcastStalled() {
        guard audioSourceMode == .systemAudio, !systemAudio.dismissedByUser else { return }
        clearSystemAudioInput()
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
        let now = ContinuousClock().now
        if let healthySince = systemAudio.recognitionHealthySince, healthySince.duration(to: now) >= .seconds(20) {
            resetExternalRecognitionRetry()
        }
        systemAudio.recognitionHealthySince = nil
        errorMessage = message
        systemAudio.recognitionError = message
        systemAudio.recognitionRetryAfter = now.advanced(by: .seconds(systemAudio.recognitionRetryDelay))
        systemAudio.recognitionRetryDelay = min(15, systemAudio.recognitionRetryDelay * 2)
    }

    func resetExternalRecognitionRetry() {
        systemAudio.recognitionHealthySince = nil
        systemAudio.recognitionRetryAfter = nil
        systemAudio.recognitionRetryDelay = 0.8
        systemAudio.recognitionError = nil
    }

    func stopSystemAudioRecovery() {
        if systemAudio.preparationDeadline != nil {
            keepAlive.stop()
        }
        systemAudio.preparationDeadline = nil
        systemAudio.monitorTask?.cancel()
        systemAudio.monitorTask = nil
        cancelRecognitionStart()
        resetExternalRecognitionRetry()
        clearSystemAudioInput()
    }

    private func clearSystemAudioInput() {
        systemAudio.isBroadcastConnected = false
        systemAudio.latestAudioPacket = nil
        systemAudio.latestSound = nil
        updateSystemAudioInputStage(.waitingForBroadcast)
    }

    private func refreshSystemAudioInputStage(now: ContinuousClock.Instant = ContinuousClock().now) {
        switch (systemAudio.isBroadcastConnected, systemAudio.latestAudioPacket, systemAudio.latestSound) {
        case (false, _, _):
            updateSystemAudioInputStage(.waitingForBroadcast)
        case (_, let packet?, _) where packet.duration(to: now) >= .seconds(3):
            updateSystemAudioInputStage(.waitingForAudio)
        case (_, nil, _):
            updateSystemAudioInputStage(.waitingForAudio)
        case (_, _, let sound?) where sound.duration(to: now) < .seconds(2):
            let stage: SystemAudioInputStage = speechRecognizer.isExternalAudioRunning ? .listening : .startingRecognition
            updateSystemAudioInputStage(stage)
        default:
            updateSystemAudioInputStage(.waitingForSound)
        }
    }

    /// 音量仅用于区分等待播放和等待识别，不影响识别器收到的音频。
    private static func hasAudibleSamples(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channel = buffer.int16ChannelData?[0] else { return false }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        return samples.contains { $0 > 80 || $0 < -80 }
    }

    // MARK: - 共享音频会话

    private var activeScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.screen
    }

    private func beginSystemAudioSession() {
        systemAudio.preparationDeadline = nil
        errorMessage = nil
        infoMessage = nil
        resetForNewRecording()
        state = .listening
        keepAlive.start()
        autoStartVisualIfNeeded()
        startSpeakerDiarizationIfNeeded()
        startSystemAudioMonitor()
    }

    private func startExternalRecognitionIfNeeded() {
        guard state == .listening, audioSourceMode == .systemAudio, !isRecognitionPaused,
              !speechRecognizer.isExternalAudioRunning, systemAudio.recognitionTask == nil else { return }
        let now = ContinuousClock().now
        if let retryAfter = systemAudio.recognitionRetryAfter, now < retryAfter { return }

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
            let now = ContinuousClock().now
            if systemAudio.recognitionRetryAfter.map({ $0 <= now }) ?? true {
                handleExternalRecognitionError("语音识别暂未就绪，正在重试。")
            }
            return
        }

        if let previousError = systemAudio.recognitionError, errorMessage == previousError {
            errorMessage = nil
        }
        systemAudio.recognitionError = nil
        systemAudio.recognitionHealthySince = ContinuousClock().now
        refreshSystemAudioInputStage()
    }

    private func cancelRecognitionStart() {
        systemAudio.recognitionTask?.cancel()
        systemAudio.recognitionTask = nil
        systemAudio.recognitionStartedAt = nil
    }

    private func restartSystemAudioListenerIfNeeded(now: ContinuousClock.Instant = ContinuousClock().now) {
        guard !systemAudioServer.hasRecentActivity else { return }
        if let lastRestart = systemAudio.lastListenerRestart, lastRestart.duration(to: now) < .seconds(5) {
            return
        }
        systemAudio.lastListenerRestart = now
        systemAudioServer.restartListener()
        clearSystemAudioInput()
    }

    /// 广播准备和收听共用一条轮询，收到首个广播包时直接切换到收听阶段。
    private func startSystemAudioMonitor() {
        guard systemAudio.monitorTask == nil else { return }
        systemAudio.monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.checkSystemAudio()
            }
        }
    }

    private func checkSystemAudio() {
        let now = ContinuousClock().now
        if let deadline = systemAudio.preparationDeadline {
            if now >= deadline {
                stopSystemAudioRecovery()
            } else {
                keepAlive.ensureRunning()
                restartSystemAudioListenerIfNeeded(now: now)
            }
            return
        }
        guard state == .listening, audioSourceMode == .systemAudio else {
            stopSystemAudioRecovery()
            return
        }
        keepAlive.ensureRunning()
        refreshSystemAudioInputStage(now: now)
        _ = systemAudioServer.start()
        if UIApplication.shared.applicationState == .background {
            restartSystemAudioListenerIfNeeded(now: now)
        }
        if let startedAt = systemAudio.recognitionStartedAt, startedAt.duration(to: now) > .seconds(45) {
            cancelRecognitionStart()
            handleExternalRecognitionError("语音识别启动超时，正在重试。")
        }
        if systemAudioServer.isReceivingAudio {
            startExternalRecognitionIfNeeded()
        }
    }
}
