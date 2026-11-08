import AVFoundation
import Foundation

/// 系统音频共享期间的静音播放保活：
/// 广播期间 App 若进入后台会被系统挂起，导致本地音频服务器停止、无法接收广播音频。
/// 通过循环播放 0 音量的静音音频（mixWithOthers 不打断其他声音）保持进程活跃。
@MainActor
final class SilentAudioKeepAlive {

    private var player: AVAudioPlayer?
    private var silentURL: URL?

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
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

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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