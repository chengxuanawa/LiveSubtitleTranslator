import SwiftUI

/// 历史会话列表
struct TranscriptListView: View {

    @EnvironmentObject private var store: TranscriptStore

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
            .navigationDestination(for: TranscriptSession.self) { session in
                TranscriptDetailView(session: session)
            }
        }
    }

    private func sessionRow(_ session: TranscriptSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text(detailText(for: session))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func detailText(for session: TranscriptSession) -> String {
        let source = LanguageOption.option(for: session.sourceLanguageIdentifier).displayName
        let target = LanguageOption.option(for: session.targetLanguageIdentifier).displayName
        return "\(source) → \(target) · \(session.segments.count) 条字幕"
    }
}

/// 单次会话详情（AI 摘要 + 译文润色 + 分享导出）
private struct TranscriptDetailView: View {

    @EnvironmentObject private var store: TranscriptStore
    @EnvironmentObject private var aiService: AIService

    @State private var session: TranscriptSession
    @State private var isSummarizing = false

    init(session: TranscriptSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let summary = session.summary {
                    summaryCard(summary)
                }
                ForEach(session.segments) { segment in
                    CaptionSegmentRow(
                        segment: segment,
                        onPolishRequest: aiService.isAvailable ? { polish(segment) } : nil
                    )
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("会话详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                summarizeButton
                ShareLink(item: session.exportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - AI 摘要

    private var summarizeButton: some View {
        Button {
            summarize()
        } label: {
            if isSummarizing {
                ProgressView()
            } else {
                Image(systemName: "sparkles")
            }
        }
        .disabled(!aiService.isAvailable || isSummarizing)
        .accessibilityLabel("生成 AI 摘要")
    }

    private func summarize() {
        guard !isSummarizing else { return }
        isSummarizing = true
        Task {
            let summary = await aiService.summarize(session: session)
            if let summary {
                session.summary = summary
                store.save(session)
            }
            isSummarizing = false
        }
    }

    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI 摘要", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(summary)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - 译文润色

    private func polish(_ segment: CaptionSegment) {
        Task {
            guard let polished = await aiService.polish(segment: segment) else { return }
            guard let index = session.segments.firstIndex(where: { $0.id == segment.id }) else { return }
            session.segments[index].polishedText = polished
            store.save(session)
        }
    }
}