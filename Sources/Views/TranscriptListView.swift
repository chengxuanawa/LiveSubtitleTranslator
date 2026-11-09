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
    /// 摘要卡片是否已展示（新摘要生成后由扫光到中点时揭开）
    @State private var showSummary: Bool
    /// glimm 风格扫光：0 → 1 为光带横穿屏幕的进度
    @State private var sweepProgress: CGFloat = 0
    @State private var sweepOpacity: Double = 1
    @State private var sweepActive = false
    @State private var sweepTask: Task<Void, Never>?

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
        .overlay {
            if sweepActive {
                GlimmSweepOverlay(progress: sweepProgress)
                    .opacity(sweepOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
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
            // 摘要就绪后播放 glimm 扫光，光带越过中点时揭开摘要卡片
            playSummarySweep()
        }
    }

    /// glimm 风格状态切换：彩色光带扫过屏幕，新摘要在中途出现
    private func playSummarySweep() {
        sweepTask?.cancel()
        sweepOpacity = 1
        sweepProgress = 0
        sweepActive = true
        sweepTask = Task { @MainActor in
            // 等一帧让光带先以起点姿态进入视图，再开始扫动
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.1)) {
                sweepProgress = 1
            }

            // 约在扫过中点（0.56）时揭开摘要卡片
            try? await Task.sleep(nanoseconds: 590_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.32)) {
                showSummary = true
            }

            // 光带走完屏幕后淡出
            try? await Task.sleep(nanoseconds: 510_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                sweepOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 230_000_000)
            guard !Task.isCancelled else { return }
            sweepActive = false
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

/// glimm 风格扫光：单条彩色光带横穿屏幕，边缘高斯柔化，用于强调一次状态切换
private struct GlimmSweepOverlay: View {
    /// 0 → 1 为光带从屏幕左外侧移动到右外侧
    var progress: CGFloat

    /// prism 配色：沿光带方向由冷到暖流动
    private let palette: [Color] = [.cyan, .blue, .purple, .pink, .orange]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let bandWidth = width * 0.52
            let offsetX = -bandWidth + (width + bandWidth) * progress

            ZStack(alignment: .leading) {
                band(width: bandWidth, height: height)
                    .blur(radius: 30)
                    .opacity(0.82)
                band(width: bandWidth * 0.36, height: height)
                    .frame(width: bandWidth, height: height)
                    .blur(radius: 8)
                    .opacity(0.9)
            }
            .frame(width: bandWidth, height: height)
            .offset(x: offsetX)
            .frame(width: width, height: height, alignment: .leading)
        }
    }

    /// 光带本体：颜色沿纵向渐变，横向用柔和的透明度衰减做出高斯式边缘
    private func band(width: CGFloat, height: CGFloat) -> some View {
        LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom)
            .frame(width: width, height: height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.28), location: 0.2),
                        .init(color: .white, location: 0.5),
                        .init(color: .white.opacity(0.28), location: 0.8),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}