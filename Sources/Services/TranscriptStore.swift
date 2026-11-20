import Foundation

/// 字幕会话持久化存储（JSON 文件，位于 Documents/Transcripts）
@MainActor
final class TranscriptStore: ObservableObject {

    @Published private(set) var sessions: [TranscriptSession] = []

    private let directoryURL: URL
    private let decoder: JSONDecoder

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directoryURL = documents.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        reload()
    }

    func save(_ session: TranscriptSession) {
        // 内存列表先即时更新，磁盘编码/写入放到后台，避免结束共享时卡住主线程
        upsert(session)
        let url = fileURL(for: session)
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(session)
                try data.write(to: url, options: .atomic)
            } catch {
                #if DEBUG
                print("[TranscriptStore] 保存失败：\(error.localizedDescription)")
                #endif
            }
        }
    }

    /// 按 id 覆盖或插入，并维持按开始时间倒序
    private func upsert(_ session: TranscriptSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
    }

    func delete(_ session: TranscriptSession) {
        try? FileManager.default.removeItem(at: fileURL(for: session))
        reload()
    }

    func reload() {
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