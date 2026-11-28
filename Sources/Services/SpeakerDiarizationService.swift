import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

/// 本地说话人分离给出的一个时间片
struct SpeakerSpan: Identifiable {
    let id = UUID()
    let speakerID: String
    /// 该时间片首次入库时冻结的显示标签，后续性别变化不回改历史字幕
    var label: String = ""
    let start: TimeInterval
    let end: TimeInterval
}

/// 基于基频的粗略性别判断（仅用于字幕参考）
enum SpeakerGender: Equatable {
    case male
    case female
    case unknown

    var title: String {
        switch self {
        case .male: return "男声"
        case .female: return "女声"
        case .unknown: return ""
        }
    }
}

/// 一个说话人的累计信息：固定显示序号、基频样本与性别估计
private struct SpeakerProfile {
    let index: Int
    var pitchSamples: [Double] = []
    var gender: SpeakerGender = .unknown

    var displayLabel: String {
        let base = "说话人 \(index)"
        return gender == .unknown ? base : "\(base) · \(gender.title)"
    }
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
    @Published private(set) var speakerSummaryText = "—"
    @Published private(set) var thermalStateText = "正常"
    /// 模型昵称（设置页展示）
    let modelNickname = "Pyannote 3.1（流式分离）"
    /// 本地模型占用大小；未下载时显示「未下载」
    @Published private(set) var modelSizeText = "未下载"
    /// 是否正在下载模型
    @Published private(set) var isPreparingModel = false

    private var engine: SpeakerDiarizationEngine?
    private var spans: [SpeakerSpan] = []
    /// 按 FluidAudio 的 speakerId 累计说话人资料与性别
    private var profiles: [String: SpeakerProfile] = [:]
    private var nextSpeakerIndex = 1
    private var thermalTask: Task<Void, Never>?
    /// 共用的模型下载任务，避免设置页与录制启动同时写模型目录
    private var prepareTask: Task<Void, Never>?
    private var modelDownloadError: String?

    init() {
        refreshModelSize()
    }

    /// 每场录制持有独立引擎，模型加载完成时核对录制是否仍有效。
    func start(sessionStart: Date?) async {
        guard engine == nil else { return }
        let engine = SpeakerDiarizationEngine()
        self.engine = engine
        engine.onUpdate = { [weak self, weak engine] update in
            guard let self, let engine, self.engine === engine, self.isReady else { return }
            self.apply(update)
        }
        resetSessionMetrics()
        statusText = "下载/加载本地模型…"
        await prepareModel()
        guard self.engine === engine else { return }
        guard hasModelOnDisk else {
            self.engine = nil
            statusText = "模型下载失败：\(modelDownloadError ?? "网络异常")"
            return
        }
        statusText = "加载本地模型…"
        do {
            try await engine.start(sessionStart: sessionStart)
            guard self.engine === engine else {
                engine.stop()
                return
            }
            isReady = true
            statusText = "运行中（5 秒窗口）"
            startThermalPolling()
        } catch {
            guard self.engine === engine else { return }
            self.engine = nil
            statusText = "不可用：\(error.localizedDescription)"
        }
    }

    /// 设置页和录制启动共用下载任务，下载状态只由创建任务的一方更新。
    func prepareModel() async {
        if let prepareTask {
            await prepareTask.value
            return
        }
        if hasModelOnDisk {
            refreshModelSize()
            if engine == nil { statusText = "模型已就绪" }
            return
        }

        isPreparingModel = true
        modelSizeText = "下载中…"
        if engine == nil { statusText = "下载本地模型…" }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.prepareTask = nil
                self.isPreparingModel = false
                self.refreshModelSize()
            }
            do {
                _ = try await DiarizerModels.downloadIfNeeded()
                self.modelDownloadError = nil
                if self.engine == nil { self.statusText = "模型已就绪" }
            } catch {
                self.modelDownloadError = error.localizedDescription
                if self.engine == nil {
                    self.statusText = "模型下载失败：\(error.localizedDescription)"
                }
            }
        }
        prepareTask = task
        await task.value
    }

    /// 喂入 16kHz 单声道音频；其他格式由 FluidAudio 内部重采样。
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isReady else { return }
        engine?.append(buffer)
    }

    func stop() {
        engine?.stop()
        engine = nil
        thermalTask?.cancel()
        thermalTask = nil
        isReady = false
        statusText = "已停止"
        resetSessionMetrics()
    }

    private func resetSessionMetrics() {
        spans = []
        profiles = [:]
        nextSpeakerIndex = 1
        speakerSummaryText = "—"
        speakerCount = 0
        currentSpeakerLabel = nil
        lastChunkSeconds = 0
        realtimeFactor = 0
    }

    /// 按会话内时间查找说话人标签；优先使用最近窗口的结果，时间片缺失时只回退很近的片段。
    func label(for time: TimeInterval) -> String? {
        guard isReady else { return nil }
        let match: SpeakerSpan?
        if let exact = spans.last(where: { time >= $0.start && time <= $0.end }) {
            match = exact
        } else if let nearest = spans.min(by: {
            Self.distance(from: time, to: $0) < Self.distance(from: time, to: $1)
        }), Self.distance(from: time, to: nearest) <= 1.5 {
            match = nearest
        } else {
            match = nil
        }
        guard let match else { return nil }
        return match.label
    }

    /// 时间点到时间片的距离；落在片内为 0
    private static func distance(from time: TimeInterval, to span: SpeakerSpan) -> TimeInterval {
        if time < span.start { return span.start - time }
        if time > span.end { return time - span.end }
        return 0
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

    // MARK: - 分离结果

    private func apply(_ update: SpeakerDiarizationEngine.Update) {
        // 新出现的说话人先分配固定序号，保证标签顺序稳定
        for span in update.spans where profiles[span.speakerID] == nil {
            profiles[span.speakerID] = SpeakerProfile(index: nextSpeakerIndex)
            nextSpeakerIndex += 1
        }
        // 基频样本先入库，这样新时间片可以直接带上当时的性别判断
        for (speakerID, pitches) in update.pitchBySpeaker where !pitches.isEmpty {
            if profiles[speakerID] == nil {
                profiles[speakerID] = SpeakerProfile(index: nextSpeakerIndex)
                nextSpeakerIndex += 1
            }
            guard var profile = profiles[speakerID] else { continue }
            profile.pitchSamples.append(contentsOf: pitches)
            if profile.pitchSamples.count > 240 {
                profile.pitchSamples.removeFirst(profile.pitchSamples.count - 240)
            }
            profile.gender = Self.classifyGender(profile.pitchSamples)
            profiles[speakerID] = profile
        }

        // 标签在这里冻结：之后性别再变化，也不会把之前的字幕全部改掉
        var labeledSpans: [SpeakerSpan] = []
        labeledSpans.reserveCapacity(update.spans.count)
        for span in update.spans {
            var labeled = span
            labeled.label = profiles[span.speakerID]?.displayLabel ?? "说话人 ?"
            labeledSpans.append(labeled)
        }

        spans.append(contentsOf: labeledSpans)
        // 长时间录制只保留近期时间片，避免无限增长
        if spans.count > 400 {
            spans.removeFirst(spans.count - 400)
        }
        speakerCount = profiles.count
        lastChunkSeconds = update.processingSeconds
        realtimeFactor = update.realtimeFactor
        if let latestSpan = labeledSpans.max(by: { $0.end < $1.end }) {
            currentSpeakerLabel = latestSpan.label
        }
        speakerSummaryText = profiles.values
            .sorted { $0.index < $1.index }
            .map(\.displayLabel)
            .joined(separator: "、")
    }

    /// 基频中位数低于 165 Hz 判为男声，否则女声；样本不足时先不标注
    private static func classifyGender(_ samples: [Double]) -> SpeakerGender {
        guard samples.count >= 8 else { return .unknown }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2] < 165 ? .male : .female
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
