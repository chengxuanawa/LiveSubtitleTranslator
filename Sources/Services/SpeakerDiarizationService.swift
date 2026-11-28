import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

/// 本地说话人分离给出的一个时间片
struct SpeakerSpan: Identifiable {
    let id = UUID()
    let speakerID: String
    let label: String
    let start: TimeInterval
    let end: TimeInterval
}

/// 实验性本地说话人分离：FluidAudio（Core ML / ANE）流式分析，给字幕提供说话人参考标签。
@MainActor
final class SpeakerDiarizationService: ObservableObject {
    @Published private(set) var statusText = "未启用"
    @Published private(set) var isReady = false
    @Published private(set) var speakerCount = 0
    @Published private(set) var lastChunkSeconds: Double = 0
    @Published private(set) var realtimeFactor: Double = 0
    @Published private(set) var currentSpeakerLabel: String?
    @Published private(set) var thermalStateText = "正常"
    /// 模型昵称（设置页展示）
    let modelNickname = "Pyannote 3.1（流式分离）"
    /// 本地模型占用大小；未下载时显示「未下载」
    @Published private(set) var modelSizeText = "未下载"
    /// 是否正在下载模型
    @Published private(set) var isPreparingModel = false

    private let engine = SpeakerDiarizationEngine()
    private var spans: [SpeakerSpan] = []
    private var thermalTask: Task<Void, Never>?
    private var isStarting = false
    /// 共用的模型下载任务，避免设置页与录制启动同时写模型目录
    private var prepareTask: Task<Bool, Never>?
    private var modelDownloadError: String?

    init() {
        engine.onUpdate = { [weak self] update in
            Task { @MainActor in
                self?.apply(update)
            }
        }
        refreshModelSize()
    }

    /// 开始新的分离会话；模型已缓存时启动较快。
    func start(sessionStart: Date?) async {
        guard !isStarting, !isReady else { return }
        isStarting = true
        spans = []
        speakerCount = 0
        currentSpeakerLabel = nil
        statusText = "下载/加载本地模型…"
        // 首次使用或模型被系统清理时先下载，并复用设置页可能正在进行的下载
        await prepareModel()
        guard hasModelOnDisk else {
            isStarting = false
            statusText = "模型下载失败：\(modelDownloadError ?? "网络异常")"
            return
        }
        statusText = "加载本地模型…"
        do {
            try await engine.start(sessionStart: sessionStart)
            isStarting = false
            isReady = true
            refreshModelSize()
            statusText = "运行中（5 秒窗口）"
            startThermalPolling()
        } catch {
            isStarting = false
            isReady = false
            statusText = "不可用：\(error.localizedDescription)"
        }
    }

    /// 下载模型：设置页开关打开时立即调用，无需先开始识别。
    /// 已下载时只刷新大小；重复调用共用同一个下载任务。
    func prepareModel() async {
        if hasModelOnDisk {
            refreshModelSize()
            if !isReady, !isStarting {
                statusText = "模型已就绪"
            }
            return
        }
        isPreparingModel = true
        modelSizeText = "下载中…"
        if !isReady, !isStarting {
            statusText = "下载本地模型…"
        }
        let task: Task<Bool, Never>
        if let existing = prepareTask {
            task = existing
        } else {
            task = Task { [weak self] in
                guard let self else { return false }
                do {
                    _ = try await DiarizerModels.downloadIfNeeded()
                    return true
                } catch {
                    self.modelDownloadError = error.localizedDescription
                    return false
                }
            }
            prepareTask = task
        }
        let success = await task.value
        prepareTask = nil
        isPreparingModel = false
        refreshModelSize()
        if success {
            modelDownloadError = nil
            if !isReady, !isStarting {
                statusText = "模型已就绪"
            }
        } else if !isReady, !isStarting {
            statusText = "模型下载失败：\(modelDownloadError ?? "网络异常")"
        }
    }

    /// 喂入 16kHz 单声道音频；其他格式由 FluidAudio 内部重采样。
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isReady else { return }
        engine.append(buffer)
    }

    func stop() {
        engine.stop()
        thermalTask?.cancel()
        thermalTask = nil
        isReady = false
        isStarting = false
        statusText = "已停止"
        spans = []
        speakerCount = 0
        currentSpeakerLabel = nil
        lastChunkSeconds = 0
        realtimeFactor = 0
    }

    /// 按会话内时间查找说话人标签；优先使用最近窗口的结果，时间片缺失时回退到最近片段。
    func label(for time: TimeInterval) -> String? {
        guard isReady else { return nil }
        if let exact = spans.last(where: { time >= $0.start && time <= $0.end }) {
            return exact.label
        }
        guard let nearest = spans.min(by: { abs($0.start - time) < abs($1.start - time) }) else {
            return nil
        }
        return abs(nearest.start - time) <= 4 ? nearest.label : nil
    }

    // MARK: - 模型文件

    /// 两个必需的 Core ML 模型是否都已在本地
    private var hasModelOnDisk: Bool {
        let directory = DiarizerModels.defaultModelsDirectory()
        return DiarizerModels.requiredModelNames.allSatisfy { name in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path
            )
        }
    }

    /// 刷新模型占用大小；目录缺失或只有空壳时显示「未下载」
    private func refreshModelSize() {
        guard hasModelOnDisk else {
            modelSizeText = "未下载"
            return
        }
        let bytes = Self.directorySize(at: DiarizerModels.defaultModelsDirectory())
        if bytes > 0 {
            modelSizeText = String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else {
            modelSizeText = "已下载"
        }
    }

    /// 递归统计目录占用（模型目录文件很少，同步统计开销可忽略）
    private nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ),
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    private func apply(_ update: SpeakerDiarizationEngine.Update) {
        spans.append(contentsOf: update.spans)
        // 长时间录制只保留近期时间片，避免无限增长
        if spans.count > 400 {
            spans.removeFirst(spans.count - 400)
        }
        speakerCount = Set(spans.map(\.speakerID)).count
        lastChunkSeconds = update.processingSeconds
        realtimeFactor = update.realtimeFactor
        if let latest = update.spans.max(by: { $0.end < $1.end })?.label {
            currentSpeakerLabel = latest
        }
    }

    private func startThermalPolling() {
        thermalTask?.cancel()
        thermalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updateThermalState()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func updateThermalState() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalStateText = "正常"
        case .fair: thermalStateText = "偏热"
        case .serious: thermalStateText = "较热"
        case .critical: thermalStateText = "过热"
        @unknown default: thermalStateText = "未知"
        }
    }
}

// MARK: - 后台推理

/// 在串行队列上运行 FluidAudio 分离，避免占用主线程和音频写入线程。
final class SpeakerDiarizationEngine {
    struct Update {
        let spans: [SpeakerSpan]
        let processingSeconds: Double
        let realtimeFactor: Double
    }

    var onUpdate: ((Update) -> Void)?

    private let queue = DispatchQueue(label: "com.example.sublingo.diarizer", qos: .utility)
    private var manager: DiarizerManager?
    private var stream: AudioStream?
    private var labelMap: [String: String] = [:]

    func start(sessionStart: Date?) async throws {
        // 首次会下载模型，之后走本地缓存
        let models = try await DiarizerModels.downloadIfNeeded()
        let offset = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let manager = DiarizerManager()
                    manager.initialize(models: models)
                    let stream = try AudioStream(
                        chunkDuration: 5.0,
                        chunkSkip: 3.0,
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
                    self.labelMap = [:]
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
            self?.labelMap = [:]
        }
    }

    private func process(_ chunk: [Float], at time: TimeInterval) {
        guard let manager else { return }
        let started = Date()
        do {
            let result = try manager.performCompleteDiarization(chunk, atTime: time)
            let processing = Date().timeIntervalSince(started)
            let audioDuration = Double(chunk.count) / 16_000.0
            var spans: [SpeakerSpan] = []
            for segment in result.segments {
                let label: String
                if let existing = labelMap[segment.speakerId] {
                    label = existing
                } else {
                    label = "说话人 \(labelMap.count + 1)"
                    labelMap[segment.speakerId] = label
                }
                spans.append(
                    SpeakerSpan(
                        speakerID: segment.speakerId,
                        label: label,
                        start: Double(segment.startTimeSeconds),
                        end: Double(segment.endTimeSeconds)
                    )
                )
            }
            guard !spans.isEmpty else { return }
            let update = Update(
                spans: spans,
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
