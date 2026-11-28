import AVFoundation
import FluidAudio
import Foundation

/// 在串行队列上运行 FluidAudio 分离，避免占用主线程和音频写入线程。
final class SpeakerDiarizationEngine {
    struct Update {
        let spans: [SpeakerSpan]
        /// speakerId -> 该窗口内估计到的基频样本（Hz）
        let pitchBySpeaker: [String: [Double]]
        let processingSeconds: Double
        let realtimeFactor: Double
    }

    var onUpdate: ((Update) -> Void)?

    private let queue = DispatchQueue(label: "com.example.sublingo.diarizer", qos: .utility)
    private var manager: DiarizerManager?
    private var stream: AudioStream?

    func start(sessionStart: Date?) async throws {
        // 首次会下载模型，之后走本地缓存
        let models = try await DiarizerModels.downloadIfNeeded()
        let offset = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    // DiarizerManager 内部会把 clusteringThreshold 放大 1.2 倍
                    // 作为说话人分配距离（默认 0.84），容易把不同音色合并成同一个人；
                    // 这里显式收紧距离阈值，保证两个人能被分开。
                    var config = DiarizerConfig()
                    config.minSpeechDuration = 0.6
                    config.minEmbeddingUpdateDuration = 1.5
                    let manager = DiarizerManager(config: config)
                    manager.initialize(models: models)
                    manager.speakerManager.speakerThreshold = 0.50
                    manager.speakerManager.embeddingThreshold = 0.48
                    // 建新说话人需要更长的语音，避免噪声造出「说话人 3」
                    manager.speakerManager.minSpeechDuration = 0.9
                    let stream = try AudioStream(
                        chunkDuration: 5.0,
                        chunkSkip: 2.0,
                        streamStartTime: offset,
                        chunkingStrategy: .useMostRecent,
                        startupStrategy: .waitForFullChunk
                    )
                    stream.bind { [weak self] chunk, time in
                        self?.queue.async {
                            self?.process(chunk, at: time)
                        }
                    }
                    self.manager = manager
                    self.stream = stream
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let stream = self.stream else { return }
            try? stream.write(from: buffer)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stream?.unbind()
            self?.stream = nil
            self?.manager = nil
        }
    }

    private func process(_ chunk: [Float], at time: TimeInterval) {
        guard let manager else { return }
        let started = Date()
        do {
            let result = try manager.performCompleteDiarization(chunk, atTime: time)
            let pitchBySpeaker = SpeakerPitchEstimator.pitchBySpeaker(
                chunk: chunk,
                segments: result.segments,
                chunkStart: time
            )
            // 基频估计也计入处理耗时，指标更接近真实开销
            let processing = Date().timeIntervalSince(started)
            let audioDuration = Double(chunk.count) / 16_000.0
            let spans = result.segments
                .filter { !$0.speakerId.isEmpty }
                .map { segment in
                    SpeakerSpan(
                        speakerID: segment.speakerId,
                        start: Double(segment.startTimeSeconds),
                        end: Double(segment.endTimeSeconds)
                    )
                }
            guard !spans.isEmpty else { return }
            let update = Update(
                spans: spans,
                pitchBySpeaker: pitchBySpeaker,
                processingSeconds: processing,
                realtimeFactor: processing > 0 ? audioDuration / processing : 0
            )
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(update)
            }
        } catch {
            // 单个窗口失败不影响字幕
        }
    }
}
