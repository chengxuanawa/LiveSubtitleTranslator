import AVFoundation
import Foundation

/// App 的音频会话由麦克风和静音保活共用。切换来源时依次配置，防止旧任务关闭新会话。
enum AppAudioSession {
    static let queue = DispatchQueue(label: "com.example.sublingo.audio.session")

    @MainActor
    static func activateMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(
                        .playAndRecord,
                        mode: .measurement,
                        options: [.mixWithOthers, .defaultToSpeaker]
                    )
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
