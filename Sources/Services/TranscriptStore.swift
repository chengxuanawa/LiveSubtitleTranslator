import Foundation

/// 字幕会话持久化存储（JSON 文件，位于 Documents/Transcripts）
@MainActor
final class TranscriptStore: ObservableObject {

    @Published private(set) var sessions: [TranscriptSession] = []

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directoryURL = documents.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        reload()
    }

    func save(_ session: TranscriptSession) {
        do {
            let url = fileURL(for: session)
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[TranscriptStore] 保存失败：\(error.localizedDescription)")
            #endif
        }
        reload()
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