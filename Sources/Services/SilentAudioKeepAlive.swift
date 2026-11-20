import AVFoundation
import Foundation

/// 系统音频共享期间的静音播放保活：
/// 广播期间 App 若进入后台会被系统挂起，导致本地音频服务器停止、无法接收广播音频。
/// 通过循环播放 0 音量的静音音频（mixWithOthers 不打断其他声音）保持进程活跃。
@MainActor
final class SilentAudioKeepAlive {

    private var player: AVAudioPlayer?
    private var silentURL: URL?
    /// 是否处于「需要保活」状态：stop() 后不再自动恢复，避免停止识别后还被中断回调拉起
    private var isActive = false
    private var interruptionObserver: NSObjectProtocol?
    private var mediaServicesObserver: NSObjectProtocol?

    init() {
        let center = NotificationCenter.default
        // 来电、视频会议等会打断播放器；打断结束后必须重新拉起，否则 App 会在后台被挂起
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }
        mediaServicesObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeIfNeeded()
            }
        }
    }

    deinit {
        let center = NotificationCenter.default
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
        }
        if let mediaServicesObserver {
            center.removeObserver(mediaServicesObserver)
        }
    }

    func start() {
        isActive = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        if let player, player.play() {
            return
        }
        player?.stop()
        self.player = nil
        guard let url = makeSilentWAV() else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
        } catch {
            #if DEBUG
            print("[KeepAlive] 启动失败：\(error.localizedDescription)")
            #endif
        }
    }

    /// 周期性自检：播放器被系统停掉时重新拉起（仅在保活期间生效）
    func ensureRunning() {
        guard isActive else { return }
        if let player, player.isPlaying { return }
        start()
    }

    func stop() {
        isActive = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 打断或媒体服务重置后恢复播放；直接 start() 会重新激活会话并重建播放器
    private func resumeIfNeeded() {
        guard isActive else { return }
        start()
    }

    /// 只在打断结束时恢复：打断进行中强行激活会话会与来电等业务抢占音频
    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .ended {
            resumeIfNeeded()
        }
    }

    // MARK: - 静音 WAV

    private func makeSilentWAV() -> URL? {
        if let silentURL, FileManager.default.fileExists(atPath: silentURL.path) {
            return silentURL
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sublingo-silence.wav")
        let sampleRate: UInt32 = 44100
        let dataSize = sampleRate * 2 // 1 秒，16-bit 单声道
        var data = Data()

        // RIFF
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.append(UInt32(36 + dataSize).littleEndianBytes)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        // fmt
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.append(UInt32(16).littleEndianBytes)
        data.append(UInt16(1).littleEndianBytes) // PCM
        data.append(UInt16(1).littleEndianBytes) // mono
        data.append(sampleRate.littleEndianBytes)
        data.append(UInt32(sampleRate * 2).littleEndianBytes) // byte rate
        data.append(UInt16(2).littleEndianBytes) // block align
        data.append(UInt16(16).littleEndianBytes) // bits
        // data
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.append(dataSize.littleEndianBytes)
        data.append(Data(count: Int(dataSize)))

        do {
            try data.write(to: url, options: .atomic)
            silentURL = url
            return url
        } catch {
            return nil
        }
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
