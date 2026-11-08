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
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .softTopEdgeEffect()
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
            // 优先显示录制地点；无定位权限或定位失败时回退首句字幕
            if let location = session.locationName, !location.isEmpty {
                return location
            }
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
            // 尚无摘要时暂显示时间；在会话详情生成 AI 摘要后即生效
            return session.startedAt.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private func detailText(for session: TranscriptSession) -> String {
        let source = LanguageOption.option(for: session.sourceLanguageIdentifier).displayName
        let target = LanguageOption.option(for: session.targetLanguageIdentifier).displayName
        return "\(source) → \(target) · \(session.segments.count) 条字幕"
    }
}

/// 单次会话详情（AI 摘要 + 分段查看 + 分享导出）
private struct TranscriptDetailView: View {

    @EnvironmentObject private var store: TranscriptStore
    @EnvironmentObject private var aiService: AIService
    /// 订阅设置变化，AI 引擎切换后摘要按钮状态即时刷新
    @EnvironmentObject private var settings: SettingsStore

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
                    CaptionSegmentRow(segment: segment) {
                        polish(segment)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("会话详情")
        .navigationBarTitleDisplayMode(.inline)
        .softTopEdgeEffect()
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

    /// 长按字幕行触发 AI 润色，并把结果写回当前会话
    private func polish(_ segment: CaptionSegment) {
        guard let index = session.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        Task {
            guard let polished = await aiService.polish(segment: segment) else { return }
            session.segments[index].polishedText = polished
            store.save(session)
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
}