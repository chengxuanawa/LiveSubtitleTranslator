import SwiftUI

/// 历史会话列表
struct TranscriptListView: View {

    @EnvironmentObject private var store: TranscriptStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "暂无记录",
                        systemImage: "tray",
                        description: Text("完成一次实时字幕后，会话记录会显示在这里。")
                    )
                } else {
                    List {
                        ForEach(store.sessions) { session in
                            NavigationLink(value: session) {
                                sessionRow(session)
                            }
                        }
                        .onDelete { indexSet in
                            let sessionsToDelete = indexSet.map { store.sessions[$0] }
                            sessionsToDelete.forEach { store.delete($0) }
                        }
                    }
                }
            }
            .navigationTitle("字幕记录")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: TranscriptSession.self) { session in
                TranscriptDetailView(session: session)
            }
        }
    }

    private func sessionRow(_ session: TranscriptSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleText(for: session))
                .font(.headline)
            Text(detailText(for: session))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func titleText(for session: TranscriptSession) -> String {
        switch settings.recordTitleStyle {
        case .time:
            return session.startedAt.formatted(date: .abbreviated, time: .shortened)
        case .snippet:
            if let first = session.segments.first?.originalText, !first.isEmpty {
                return String(first.prefix(24))
            }
            return "未命名记录"
        case .aiTitle:
            if let firstLine = session.summary?
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return String(firstLine.prefix(30))
            }
            return session.startedAt.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private func detailText(for session: TranscriptSession) -> String {
        let source = LanguageOption.option(for: session.sourceLanguageIdentifier).displayName
        let target = LanguageOption.option(for: session.targetLanguageIdentifier).displayName
        return "\(source) → \(target) · \(session.segments.count) 条字幕"
    }
}

/// 单次会话详情（分段查看 + 分享导出）
private struct TranscriptDetailView: View {

    let session: TranscriptSession

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(session.segments) { segment in
                    CaptionSegmentRow(segment: segment)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("会话详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: session.exportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}