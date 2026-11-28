import Foundation
import OSLog

/// 字幕会话持久化存储（JSON 文件，位于 Documents/Transcripts）
@MainActor
final class TranscriptStore: ObservableObject {

    @Published private(set) var sessions: [TranscriptSession] = []

    private let directoryURL: URL
    private let diskQueue = DispatchQueue(label: "com.example.sublingo.transcripts", qos: .utility)
    private let logger = Logger(subsystem: "com.example.sublingo", category: "TranscriptStore")

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directoryURL = documents.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        loadSessions()
    }

    func save(_ session: TranscriptSession) {
        upsert(session)
        let url = fileURL(for: session)
        diskQueue.async { [logger] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(session)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("保存记录失败：\(error.localizedDescription)")
            }
        }
    }

    /// 只更新尚在历史中的记录。异步字幕结果不能重建已删除的会话。
    func update(_ id: UUID, _ change: (inout TranscriptSession) -> Void) {
        guard let original = sessions.first(where: { $0.id == id }) else { return }
        var updated = original
        change(&updated)
        guard updated != original else { return }
        save(updated)
    }

    func updateSegment(_ segmentID: UUID, in sessionID: UUID, _ change: (inout CaptionSegment) -> Void) {
        update(sessionID) { session in
            guard let index = session.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            change(&session.segments[index])
        }
    }

    /// 按 id 覆盖或插入，并维持按开始时间倒序
    private func upsert(_ session: TranscriptSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
            return
        }
        let index = sessions.firstIndex(where: { $0.startedAt < session.startedAt }) ?? sessions.endIndex
        sessions.insert(session, at: index)
    }

    func delete(_ session: TranscriptSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let removed = sessions.remove(at: index)
        let url = fileURL(for: removed)
        // 删除与写盘按同样的提交顺序执行，避免在途写入重新创建文件。
        diskQueue.async { [weak self, logger] in
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                logger.error("删除记录失败：\(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.upsert(removed)
                }
            }
        }
    }

    private func loadSessions() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        sessions = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TranscriptSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func fileURL(for session: TranscriptSession) -> URL {
        directoryURL.appendingPathComponent("\(session.id.uuidString).json")
    }
}