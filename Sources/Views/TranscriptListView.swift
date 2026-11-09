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
    /// 摘要卡片是否已展示（新摘要生成后淡入揭开）
    @State private var showSummary: Bool

    init(session: TranscriptSession) {
        _session = State(initialValue: session)
        _showSummary = State(initialValue: session.summary != nil)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if showSummary, let summary = session.summary {
                    summaryCard(summary)
                        .transition(.blurReplace)
                }
                ForEach(session.segments) { segment in
                    CaptionSegmentRow(
                        segment: segment,
                        showsPolishedHighlight: true,
                        onPolishRequest: { polish(segment) }
                    )
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
            defer { isSummarizing = false }
            guard let summary = await aiService.summarize(session: session) else { return }
            session.summary = summary
            store.save(session)
            withAnimation(.easeOut(duration: 0.34)) {
                showSummary = true
            }
        }
    }

    /// 长按字幕行触发 AI 润色，并把结果写回当前会话
    private func polish(_ segment: CaptionSegment) {
        guard let index = session.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        Task {
            guard let polished = await aiService.polish(
                segment: segment,
                targetLanguage: session.targetLanguageIdentifier
            ) else { return }
            session.segments[index].polishedText = polished
            store.save(session)
        }
    }

    /// AI 摘要卡片：与对话气泡区分开——更大圆角、玻璃底、彩色描边与周围氛围光
    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("AI 摘要")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Spacer(minLength: 0)
            }

            Text(summary)
                .font(.subheadline)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.16),
                                Color.blue.opacity(0.10),
                                Color.purple.opacity(0.16),
                                Color.pink.opacity(0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            // 彩色描边实时流动：角向渐变缓慢旋转，形成沿边框游走的光
            TimelineView(.animation(minimumInterval: 0.06)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 6) / 6
                let angle = Angle.degrees(phase * 360)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color.cyan.opacity(0.85),
                                Color.blue.opacity(0.45),
                                Color.purple.opacity(0.75),
                                Color.pink.opacity(0.85),
                                Color.cyan.opacity(0.85),
                            ],
                            center: .center,
                            startAngle: angle,
                            endAngle: angle + .degrees(360)
                        ),
                        lineWidth: 1.2
                    )
            }
        }
        // 氛围光：与描边同步旋转的彩色光晕，让卡片整体“活”起来
        .background {
            TimelineView(.animation(minimumInterval: 0.06)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 6) / 6
                let angle = Angle.degrees(phase * 360)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        AngularGradient(
                            colors: [
                                Color.cyan.opacity(0.45),
                                Color.blue.opacity(0.30),
                                Color.purple.opacity(0.42),
                                Color.pink.opacity(0.38),
                                Color.cyan.opacity(0.45),
                            ],
                            center: .center,
                            startAngle: angle,
                            endAngle: angle + .degrees(360)
                        )
                    )
                    .blur(radius: 26)
                    .opacity(0.55)
                    .padding(-8)
            }
        }
        .shadow(color: Color.purple.opacity(0.18), radius: 16, x: 0, y: 8)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}