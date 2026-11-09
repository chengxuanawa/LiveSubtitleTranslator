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
    /// glimm 扫光：开始时间 / 本次色相偏移 / 是否正在播放
    @State private var sweepStart = Date()
    @State private var sweepHue: Float = 0
    @State private var sweepActive = false
    @State private var sweepTask: Task<Void, Never>?

    /// glimm 扫光总时长（1100ms 扫过 + 240ms 淡出）
    private static let sweepDuration: Double = 1.1
    private static let sweepOutro: Double = 0.24
    /// 光脊越过屏幕中点、揭晓新内容的时刻（对应 glimm 的 midpoint 0.56）
    private static let sweepMidpointDelay: Double = 0.36

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
                GlimmSweepOverlay(start: sweepStart, hueShift: sweepHue)
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
        // 点击即播放扫光：光脊到达中点时揭晓新摘要
        startSummarySweep()
        Task {
            defer { isSummarizing = false }
            guard let summary = await aiService.summarize(session: session) else { return }
            session.summary = summary
            store.save(session)
            // AI 若在光脊到达中点前返回，等扫光到中点再揭晓，避免抢在光带前面
            if sweepActive {
                let elapsed = Date().timeIntervalSince(sweepStart)
                if elapsed < Self.sweepMidpointDelay {
                    try? await Task.sleep(
                        nanoseconds: UInt64((Self.sweepMidpointDelay - elapsed) * 1_000_000_000)
                    )
                }
            }
            withAnimation(.easeOut(duration: 0.34)) {
                showSummary = true
            }
        }
    }

    /// 开始一次 glimm 扫光：光脊横穿屏幕，扫过中点时新内容在光带下出现
    private func startSummarySweep() {
        sweepTask?.cancel()
        sweepStart = Date()
        sweepHue = Float.random(in: 0...0.4)
        sweepActive = true
        sweepTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64((Self.sweepDuration + Self.sweepOutro + 0.02) * 1_000_000_000)
            )
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

/// glimm 扫光：Metal 着色器逐像素绘制一条窄而亮的彩虹光脊，横穿屏幕
private struct GlimmSweepOverlay: View {
    /// 扫光开始时间
    let start: Date
    /// 本次扫光的色相偏移，让每次效果略有不同
    let hueShift: Float

    private static let duration: Double = 1.1
    private static let outro: Double = 0.24
    private static let peakAlpha: Float = 0.75

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            GeometryReader { geometry in
                Rectangle()
                    // 着色器会完全接管像素颜色；这里用近乎透明的填充，
                    // 万一着色器未加载也不会挡住内容
                    .fill(Color.black.opacity(0.001))
                    .colorEffect(
                        ShaderLibrary.glimmSweep(
                            .float(Float(geometry.size.width)),
                            .float(Float(geometry.size.height)),
                            .float(Self.easedProgress(elapsed)),
                            .float(Float(elapsed)),
                            .float(Self.alpha(elapsed)),
                            .float(hueShift)
                        )
                    )
            }
        }
    }

    /// glimm 默认缓动 cubic-bezier(0.25, 0.1, 0.25, 1)
    private static func easedProgress(_ elapsed: Double) -> Float {
        let x = min(max(elapsed / duration, 0), 1)
        return Float(bezierY(x: x, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0))
    }

    /// 扫过后 240ms 内淡出；再往后光脊已在屏幕外，无可见影响
    private static func alpha(_ elapsed: Double) -> Float {
        guard elapsed > duration else { return peakAlpha }
        let t = min(max((elapsed - duration) / outro, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return peakAlpha * Float(1 - eased)
    }

    /// 由 x 反解三次贝塞尔曲线的 y，用作缓动曲线
    private static func bezierY(
        x: Double,
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double
    ) -> Double {
        func curve(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if curve(mid, x1, x2) < x {
                low = mid
            } else {
                high = mid
            }
        }
        return curve((low + high) / 2, y1, y2)
    }
}