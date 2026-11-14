import SwiftUI
import UIKit

/// 实时字幕主界面：顶部大字幕 + 分段记录 + 悬浮控制栏（麦克风 / 系统共享音频）
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService
    /// 横屏兜底判断：部分情况下窗口尺寸更新滞后，紧凑高度也视为横屏
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// 回到前台时重新确认本地音频监听是否还在
    @Environment(\.scenePhase) private var scenePhase

    private let broadcastExtensionID = "com.example.sublingo.broadcast"
    private let bottomAnchorID = "transcript-bottom"

    /// 已经逐字吐出的实时文本
    @State private var revealedText = ""
    /// 末尾字符是否已结束渐显（没有新字后恢复完全清晰）
    @State private var tailSettled = true
    /// 逐字吐字任务
    @State private var revealTask: Task<Void, Never>?
    /// 用户滑离底部后保持固定，默认不再自动拉回
    @State private var autoScrollLocked = false
    /// 可选的自动回到实时倒计时（0 表示一直固定）
    @State private var autoScrollUnlockTask: Task<Void, Never>?
    @AppStorage("autoScrollResumeSeconds") private var autoScrollResumeSeconds: Double = 0
    /// 调整时间时显示的气泡
    @State private var showLockTimePopup = false
    @State private var lockTimePopupTask: Task<Void, Never>?
    /// 拖动波形图标设定时间的起始值
    @State private var lockTimeDragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height || verticalSizeClass == .compact
            // iPad 窗口化 / 台前调度下的窗口控制按钮会占用左上角，
            // 用系统给的容器圆角内边距把顶栏内容整体右移避让
            let windowControlsInset = proxy.containerCornerInsets.topLeading.width
            Group {
                if isLandscape {
                    // 横屏单栏铺满：实时文字本来就在列表底部更新，
                    // 不再单独分栏；系统 Tab 栏在左下，悬浮按钮让到右下
                    transcriptColumn(isLandscape: true, windowControlsInset: windowControlsInset)
                        .safeAreaPadding(.bottom, 76)
                        .overlay(alignment: .bottomTrailing) {
                            floatingControls
                                .padding(.trailing, 16)
                                .padding(.bottom, 12)
                        }
                } else {
                    transcriptColumn(isLandscape: false, windowControlsInset: windowControlsInset)
                        .safeAreaPadding(.bottom, 96)
                        .overlay(alignment: .bottomTrailing) {
                            floatingControls
                                .padding(.trailing, 20)
                                .padding(.bottom, 16)
                        }
                }
            }
            .frame(maxWidth: isLandscape ? .infinity : 900, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .translationTask(source: sourceLanguage, target: targetLanguage) { session in
                viewModel.attachTranslationSession(session)
            }
            .onAppear {
                viewModel.prepareSystemAudioServer()
                // 重新进入页面直接对齐当前文本，避免重放逐字动画
                revealedText = viewModel.liveDisplayText
                tailSettled = true
                revealTask?.cancel()
                revealTask = nil
            }
            .onChange(of: viewModel.liveDisplayText) { _, _ in
                syncRevealedText()
            }
            .onChange(of: settings.keepScreenOnWhileRecognizing) { _, _ in
                viewModel.refreshIdleTimer()
            }
            .onChange(of: scenePhase) { _, phase in
                // App 被挂起期间广播可能已开始，回到前台后重建失效的监听器
                if phase == .active {
                    viewModel.prepareSystemAudioServer()
                }
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
            }
        }
    }

    /// 字幕栏：顶栏作为滚动视图的安全区插入视图，列表会滑到顶栏与状态栏下方
    private func transcriptColumn(isLandscape: Bool, windowControlsInset: CGFloat) -> some View {
        segmentList(isLandscape: isLandscape)
            .safeAreaInset(edge: .top, spacing: 0) {
                header(isLandscape: isLandscape, windowControlsInset: windowControlsInset)
            }
            .softTopEdgeEffect()
    }

    // MARK: - 顶部标题栏

    /// 左侧清空 + 标题，右侧语言胶囊（横屏时标题居中，与系统 Tab 栏的横屏样式统一）
    private func header(isLandscape: Bool, windowControlsInset: CGFloat) -> some View {
        Group {
            if isLandscape {
                ZStack {
                    Text("实时字幕")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 12) {
                        clearButton
                        Spacer(minLength: 0)
                        languageControls
                    }
                    .padding(.leading, windowControlsInset)
                }
            } else {
                HStack(spacing: 12) {
                    clearButton
                    Text("实时字幕")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    languageControls
                }
                .padding(.leading, windowControlsInset)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isLandscape ? 2 : 6)
        .padding(.bottom, isLandscape ? 4 : 8)
    }

    // MARK: - 翻译会话（由 SwiftUI translationTask 注入）

    private var sourceLanguage: Locale.Language {
        Locale.Language(identifier: settings.sourceLanguageIdentifier)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: settings.targetLanguageIdentifier)
    }

    // MARK: - 实时字幕气泡（追加在列表底部）

    /// 正在识别中的字幕气泡（列表中使用，左右留出与气泡相同的边距）
    private var liveBubble: some View {
        liveBubbleCore
            .padding(.horizontal, 12)
    }

    /// 正在识别中的字幕气泡本体：逐字显示，最后一个词带彩虹流光
    private var liveBubbleCore: some View {
        VStack(alignment: .leading, spacing: 6) {
            if revealedText.isEmpty {
                if viewModel.liveDisplayText.isEmpty {
                    Text(viewModel.isRecognitionPaused ? "已暂停识别，录屏仍在继续" : "正在聆听…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                liveRevealText
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.realtimeTranslationEnabled, !viewModel.isRecognitionPaused {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.top, 2)
                    Text(viewModel.pendingText.isEmpty ? "断句后生成译文" : "AI 整理分段中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }

    /// 实时文字：末尾几个字符用透明度渐变淡入，其余保持正常清晰
    private var liveRevealText: Text {
        let characters = Array(revealedText)
        guard !characters.isEmpty else { return Text("") }

        let fadeCount = tailSettled ? 0 : 3
        let fadeStart = max(0, characters.count - fadeCount)
        var attributed = AttributedString()
        if fadeStart > 0 {
            var piece = AttributedString(String(characters[0..<fadeStart]))
            piece.foregroundColor = Color.primary
            attributed.append(piece)
        }
        for index in fadeStart..<characters.count {
            let step = Double(index - fadeStart + 1) / Double(max(1, characters.count - fadeStart))
            var piece = AttributedString(String(characters[index]))
            piece.foregroundColor = Color.primary.opacity(0.35 + 0.65 * step)
            attributed.append(piece)
        }
        return Text(attributed)
    }

    // MARK: - 逐字吐字

    /// 识别文本变化时同步：识别结果被修正则直接对齐，否则启动逐字吐字
    private func syncRevealedText() {
        let target = viewModel.liveDisplayText
        guard !target.isEmpty else {
            revealTask?.cancel()
            revealTask = nil
            revealedText = ""
            tailSettled = true
            return
        }
        guard target.hasPrefix(revealedText) else {
            revealedText = target
            tailSettled = true
            return
        }
        startRevealPumpIfNeeded()
    }

    /// 每 60ms 吐一个字；积压较多时一次多吐几个追上识别速度
    private func startRevealPumpIfNeeded() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            while !Task.isCancelled {
                let target = viewModel.liveDisplayText
                guard target.hasPrefix(revealedText) else {
                    revealedText = target
                    tailSettled = true
                    break
                }
                let backlog = target.count - revealedText.count
                guard backlog > 0 else { break }
                let step = backlog > 12 ? 3 : (backlog > 5 ? 2 : 1)
                let end = target.index(target.startIndex, offsetBy: revealedText.count + step)
                revealedText = String(target[..<end])
                tailSettled = false
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            revealTask = nil
            // 退出瞬间目标又变长时补一次，避免漏字
            if viewModel.liveDisplayText.count > revealedText.count {
                startRevealPumpIfNeeded()
                return
            }
            // 没有新字后稍等片刻，再让末尾字符恢复完全清晰
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, revealTask == nil else { return }
            tailSettled = true
        }
    }

    // MARK: - 分段记录

    private func segmentList(isLandscape: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.segments) { segment in
                        CaptionSegmentRow(
                            segment: segment,
                            showTranslationFailure: settings.realtimeTranslationEnabled
                                && viewModel.failedTranslationIDs.contains(segment.id),
                            onRetryTranslation: { viewModel.retryTranslation(for: segment) },
                            onPolishRequest: { polish(segment) },
                            onReveal: { viewModel.markSegmentAnimated(segment.id) }
                        )
                        .id(segment.id)
                    }

                    if !viewModel.liveDisplayText.isEmpty || viewModel.state == .listening {
                        liveBubble
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        // 仅上下拖动时固定列表；用户自己滑回底部后自动解除
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        lockAutoScroll(proxy)
                    }
            )
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { _, distanceToBottom in
                guard autoScrollLocked, distanceToBottom < 16 else { return }
                autoScrollUnlockTask?.cancel()
                autoScrollLocked = false
            }
            .onAppear {
                scrollToBottom(proxy, animated: false, force: true)
            }
            // 系统锚点在横屏/文字高频增长时不可靠，改为显式跟随：
            // 实时文字每吐一个字、新字幕落库时都平滑贴底
            .onChange(of: revealedText) { _, _ in
                scrollToBottom(proxy, animated: true, duration: 0.12)
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                scrollToBottom(proxy, animated: true, duration: 0.22)
            }
            .onChange(of: viewModel.state) { _, state in
                if state == .listening {
                    scrollToBottom(proxy, animated: true)
                } else {
                    autoScrollUnlockTask?.cancel()
                    autoScrollLocked = false
                }
            }
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    if autoScrollLocked, viewModel.state == .listening {
                        autoScrollLockControl(proxy)
                            .padding(.bottom, isLandscape ? 24 : 120)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: autoScrollLocked)
            }
        }
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        force: Bool = false,
        duration: Double = 0.25
    ) {
        guard force || !autoScrollLocked else { return }
        Task { @MainActor in
            // 等这一轮文字布局完成再滚，否则会滚到增长前的位置
            await Task.yield()
            guard force || !autoScrollLocked else { return }
            if animated {
                withAnimation(.easeInOut(duration: duration)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// 开始或重置回到实时的倒计时；时间为 0 时保持固定，不自动返回
    private func lockAutoScroll(_ proxy: ScrollViewProxy) {
        guard viewModel.state == .listening else { return }
        autoScrollLocked = true
        autoScrollUnlockTask?.cancel()
        let seconds = autoScrollResumeSeconds
        guard seconds >= 1 else { return }
        autoScrollUnlockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            autoScrollLocked = false
            // 倒计时结束平滑滑回最新位置，而不是等下一段文字突然拉过去
            scrollToBottom(proxy, animated: true, force: true, duration: 0.5)
        }
    }

    private func resumeAutoScroll(_ proxy: ScrollViewProxy) {
        autoScrollUnlockTask?.cancel()
        autoScrollLocked = false
        scrollToBottom(proxy, animated: true, force: true)
    }

    /// 右侧悬浮控制：上方波形图标拖动设定自动返回秒数，下方突起箭头一键回到最新
    private func autoScrollLockControl(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            waveTimeHandle(proxy)
            returnToLatestTab(proxy)
        }
    }

    private var lockTimeText: String {
        autoScrollResumeSeconds >= 1 ? "\(Int(autoScrollResumeSeconds)) 秒" : "一直固定"
    }

    /// 波形图标：上下拖动调时间，点按给出触感反馈并弹出当前时间
    private func waveTimeHandle(_ proxy: ScrollViewProxy) -> some View {
        Image(systemName: "waveform")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 44)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 17,
                    bottomLeadingRadius: 17,
                    style: .continuous
                )
                .fill(.ultraThinMaterial)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showLockTimePopupBriefly()
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if lockTimeDragStart == nil {
                            lockTimeDragStart = autoScrollResumeSeconds
                            showLockTimePopupBriefly(hold: true)
                        }
                        let start = lockTimeDragStart ?? 0
                        let seconds = (start - value.translation.height / 3).rounded()
                        let clamped = min(30, max(0, seconds))
                        guard clamped != autoScrollResumeSeconds else { return }
                        autoScrollResumeSeconds = clamped
                        UISelectionFeedbackGenerator().selectionChanged()
                        lockAutoScroll(proxy)
                    }
                    .onEnded { _ in
                        lockTimeDragStart = nil
                        showLockTimePopupBriefly()
                    }
            )
            .overlay(alignment: .leading) {
                if showLockTimePopup {
                    Text(lockTimeText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: Capsule())
                        .fixedSize()
                        .offset(x: -58)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .accessibilityLabel("自动回到实时时间：\(lockTimeText)")
    }

    /// 从右边缘突起的箭头：点击回到最新字幕并解除固定
    private func returnToLatestTab(_ proxy: ScrollViewProxy) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            resumeAutoScroll(proxy)
        } label: {
            Image(systemName: "chevron.left")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 40)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        style: .continuous
                    )
                    .fill(.ultraThinMaterial)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到最新")
    }

    /// 弹出时间气泡并自动收起；拖动期间保持显示
    private func showLockTimePopupBriefly(hold: Bool = false) {
        lockTimePopupTask?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            showLockTimePopup = true
        }
        guard !hold else { return }
        lockTimePopupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showLockTimePopup = false
            }
        }
    }

    /// 长按字幕行触发 AI 润色
    private func polish(_ segment: CaptionSegment) {
        Task {
            guard let polished = await aiService.polish(segment: segment) else { return }
            viewModel.applyPolishedText(polished, to: segment.id)
        }
    }

    // MARK: - 悬浮控制（右下角液态玻璃）

    private var floatingControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 4)
                    .onTapGesture { viewModel.dismissError() }
            }

            HStack(spacing: 10) {
                if viewModel.state == .listening {
                    // 液态玻璃容器：每个按钮独立响应按压形变，相邻玻璃自动融合成胶囊
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            liveActivityButton
                            pipButton
                            if viewModel.audioSourceMode == .systemAudio {
                                pauseButton
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }

                    translateToggle
                        .transition(
                            .move(edge: .trailing).combined(with: .opacity)
                        )
                } else {
                    audioModeButton
                        .transition(.scale.combined(with: .opacity))
                }

                primaryControl
                    .id(viewModel.audioSourceMode)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.state)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.audioSourceMode)
        }
    }

    /// 音频来源切换：麦克风模式下显示红色圆点，系统共享音频模式下显示麦克风图标
    private var audioModeButton: some View {
        Button {
            switchAudioSource()
        } label: {
            Image(systemName: settings.audioSourceMode == .microphone ? "circle.fill" : "mic.fill")
                .font(.system(size: settings.audioSourceMode == .microphone ? 20 : 22, weight: .bold))
                .foregroundStyle(settings.audioSourceMode == .microphone ? Color.red : Color.accentColor)
                .frame(width: 56, height: 56)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(settings.audioSourceMode == .microphone ? "切换到系统共享音频" : "切换到麦克风")
    }

    /// 切换音频来源；切换后主按钮会以原生弹簧动画替换为广播按钮/麦克风按钮
    private func switchAudioSource() {
        if viewModel.state == .listening {
            viewModel.stop()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            settings.audioSourceMode = settings.audioSourceMode == .microphone ? .systemAudio : .microphone
            settings.objectWillChange.send()
        }
        if settings.audioSourceMode == .systemAudio {
            viewModel.prepareSystemAudioServer()
        }
    }

    /// 实时翻译开关：录音开始后从主按钮左侧弹出
    private var translateToggle: some View {
        Button {
            settings.realtimeTranslationEnabled.toggle()
            settings.objectWillChange.send()
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(settings.realtimeTranslationEnabled ? Color.accentColor : .secondary)
                .frame(width: 56, height: 56)
                .symbolEffect(.bounce, value: settings.realtimeTranslationEnabled)
                .animation(.easeInOut(duration: 0.2), value: settings.realtimeTranslationEnabled)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(settings.realtimeTranslationEnabled ? "关闭实时翻译" : "开启实时翻译")
    }

    /// 主按钮：麦克风开始/停止；系统共享音频时为广播按钮
    @ViewBuilder
    private var primaryControl: some View {
        switch viewModel.audioSourceMode {
        case .microphone:
            recordButton
        case .systemAudio:
            if viewModel.state == .listening {
                stopButton
            } else {
                systemAudioButton
            }
        }
    }

    /// 系统共享音频主按钮：自定义蓝色玻璃外观，点击后程序化弹出系统广播选择器
    private var systemAudioButton: some View {
        Button {
            BroadcastPickerTrigger.shared.trigger()
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.accentColor).interactive(), in: Circle())
        .background(
            BroadcastPickerView(preferredExtension: broadcastExtensionID)
                .frame(width: 56, height: 56)
                .opacity(0.001)
                .allowsHitTesting(false)
        )
        .accessibilityLabel("开始系统广播")
    }

    private var recordButton: some View {
        Button {
            viewModel.toggle()
        } label: {
            Image(systemName: viewModel.state == .listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, isActive: viewModel.state == .listening)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular
                .tint(viewModel.state == .listening ? Color.red : Color.accentColor)
                .interactive(),
            in: Circle()
        )
        .accessibilityLabel(viewModel.state == .listening ? "停止识别" : "开始识别")
    }

    private var stopButton: some View {
        Button {
            // 录屏模式无法由 App 直接停止系统广播：先弹出系统共享控件，
            // 用户在控件里结束共享后，检测到音频流断开会自动收尾
            BroadcastPickerTrigger.shared.trigger()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.red).interactive(), in: Circle())
        .background(
            BroadcastPickerView(preferredExtension: broadcastExtensionID)
                .frame(width: 56, height: 56)
                .opacity(0.001)
                .allowsHitTesting(false)
        )
        .accessibilityLabel("结束共享并停止识别")
    }

    private var liveActivityButton: some View {
        Button {
            viewModel.toggleLiveActivity()
        } label: {
            Image(systemName: viewModel.isLiveActivityActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(viewModel.isLiveActivityActive ? Color.accentColor : .secondary)
                .frame(width: 56, height: 56)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(viewModel.isLiveActivityActive ? "关闭灵动岛字幕" : "在灵动岛显示字幕")
    }

    private var pipButton: some View {
        Button {
            viewModel.togglePictureInPicture()
        } label: {
            Image(systemName: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(viewModel.isPictureInPictureActive ? Color.accentColor : .secondary)
                .frame(width: 56, height: 56)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(viewModel.isPictureInPictureActive ? "退出画中画字幕" : "在画中画显示字幕")
    }

    /// 系统共享音频：暂停/继续识别，广播与录屏不中断
    private var pauseButton: some View {
        Button {
            viewModel.toggleRecognitionPause()
        } label: {
            Image(systemName: viewModel.isRecognitionPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(viewModel.isRecognitionPaused ? Color.accentColor : .secondary)
                .frame(width: 56, height: 56)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(viewModel.isRecognitionPaused ? "继续识别" : "暂停识别")
    }

    // MARK: - 工具栏

    private var clearButton: some View {
        Button {
            viewModel.clearSegments()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(viewModel.segments.isEmpty && viewModel.liveDisplayText.isEmpty)
        .accessibilityLabel("清空字幕")
    }

    /// 语言切换：源语言、目标语言各一块液态玻璃胶囊，中间箭头保持透明可点击对换
    private var languageControls: some View {
        HStack(spacing: 2) {
            sourceLanguageMenu
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture { swapLanguages() }
                .accessibilityLabel("对换语言")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { swapLanguages() }
            targetLanguageMenu
        }
    }

    /// 对换识别语言与翻译语言
    private func swapLanguages() {
        let source = settings.sourceLanguageIdentifier
        settings.sourceLanguageIdentifier = settings.targetLanguageIdentifier
        settings.targetLanguageIdentifier = source
        settings.objectWillChange.send()
    }

    private var sourceLanguageMenu: some View {
        Menu {
            Picker("识别语言", selection: $settings.sourceLanguageIdentifier) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
        } label: {
            languageChip(LanguageOption.option(for: settings.sourceLanguageIdentifier).displayName)
        }
    }

    private var targetLanguageMenu: some View {
        Menu {
            Picker("翻译为", selection: $settings.targetLanguageIdentifier) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
        } label: {
            languageChip(LanguageOption.option(for: settings.targetLanguageIdentifier).displayName)
        }
    }

    private func languageChip(_ name: String) -> some View {
        Text(shortName(name))
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: "（").first ?? name
    }
}