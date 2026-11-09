import SwiftUI

/// 实时字幕主界面：顶部大字幕 + 分段记录 + 悬浮控制栏（麦克风 / 系统共享音频）
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService
    /// 横屏兜底判断：部分情况下窗口尺寸更新滞后，紧凑高度也视为横屏
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let broadcastExtensionID = "com.example.sublingo.broadcast"
    private let bottomAnchorID = "transcript-bottom"

    /// 已经逐字吐出的实时文本
    @State private var revealedText = ""
    /// 逐字吐字任务
    @State private var revealTask: Task<Void, Never>?
    /// 用户滑动列表时临时暂停自动滚动
    @State private var autoScrollLocked = false
    @State private var autoScrollUnlockTask: Task<Void, Never>?
    @AppStorage("autoScrollLockSeconds") private var autoScrollLockSeconds: Double = 6

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height || verticalSizeClass == .compact
            Group {
                if isLandscape {
                    // 横屏单栏铺满：实时文字本来就在列表底部更新，
                    // 不再单独分栏；系统 Tab 栏在左下，悬浮按钮让到右下
                    transcriptColumn(isLandscape: true)
                        .safeAreaPadding(.bottom, 76)
                        .overlay(alignment: .bottomTrailing) {
                            floatingControls
                                .padding(.trailing, 16)
                                .padding(.bottom, 12)
                        }
                } else {
                    transcriptColumn(isLandscape: false)
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
                revealTask?.cancel()
                revealTask = nil
            }
            .onChange(of: viewModel.liveDisplayText) { _, _ in
                syncRevealedText()
            }
            .onChange(of: settings.keepScreenOnWhileRecognizing) { _, _ in
                viewModel.refreshIdleTimer()
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
            }
        }
    }

    /// 字幕栏：顶栏作为滚动视图的安全区插入视图，列表会滑到顶栏与状态栏下方
    private func transcriptColumn(isLandscape: Bool) -> some View {
        segmentList(isLandscape: isLandscape)
            .safeAreaInset(edge: .top, spacing: 0) {
                header(isLandscape: isLandscape)
            }
            .softTopEdgeEffect()
    }

    // MARK: - 顶部标题栏

    /// 左侧清空 + 标题，右侧语言胶囊（横屏时标题居中，与系统 Tab 栏的横屏样式统一）
    private func header(isLandscape: Bool) -> some View {
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
                    Text("正在聆听…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                rainbowLiveText
            }

            if settings.realtimeTranslationEnabled {
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 实时文字：普通文字 + 末词彩虹流光（Color 相位随时钟推进，形成真正的流动）
    private var rainbowLiveText: some View {
        let parts = rainbowParts(from: revealedText)
        return TimelineView(.animation(minimumInterval: 0.14, paused: autoScrollLocked)) { context in
            let cycle: Double = 2
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle
            rainbowText(prefix: parts.prefix, tail: parts.tail, phase: phase)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 拆分出“最后一个词”：有空格按空格切词，中日韩等无空格语言取最后几个字
    private func rainbowParts(from text: String) -> (prefix: String, tail: String) {
        guard !text.isEmpty else { return ("", "") }
        if let spaceIndex = text.lastIndex(of: " ") {
            let cut = text.index(after: spaceIndex)
            if cut < text.endIndex {
                return (String(text[..<cut]), String(text[cut...]))
            }
        }
        let tailCount = min(4, text.count)
        let cut = text.index(text.endIndex, offsetBy: -tailCount)
        return (String(text[..<cut]), String(text[cut...]))
    }

    private func rainbowText(prefix: String, tail: String, phase: Double) -> Text {
        var attributed = AttributedString()
        if !prefix.isEmpty {
            var piece = AttributedString(prefix)
            piece.foregroundColor = Color.primary
            attributed.append(piece)
        }
        let characters = Array(tail)
        for (index, character) in characters.enumerated() {
            var piece = AttributedString(String(character))
            let progress = characters.count > 1
                ? Double(index) / Double(characters.count - 1)
                : 1
            let hue = (0.5 + 0.42 * progress + phase).truncatingRemainder(dividingBy: 1)
            piece.foregroundColor = Color(hue: hue, saturation: 0.88, brightness: 0.98)
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
            return
        }
        guard target.hasPrefix(revealedText) else {
            revealedText = target
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
                    break
                }
                let backlog = target.count - revealedText.count
                guard backlog > 0 else { break }
                let step = backlog > 12 ? 3 : (backlog > 5 ? 2 : 1)
                let end = target.index(target.startIndex, offsetBy: revealedText.count + step)
                revealedText = String(target[..<end])
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            revealTask = nil
            // 退出瞬间目标又变长时补一次，避免漏字
            if viewModel.liveDisplayText.count > revealedText.count {
                startRevealPumpIfNeeded()
            }
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
            // 内容变高时由系统保持底部锚点：文字连续增长时偏移同步跟随，
            // 不会像手动 scrollTo 那样一截一截地跳
            .defaultScrollAnchor(autoScrollLocked ? nil : .bottom, for: .sizeChanges)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        // 用户手动滑动时暂停自动跟随，避免被新文字拉回底部
                        lockAutoScroll(proxy)
                    }
            )
            .onAppear {
                scrollToBottom(proxy, animated: false, force: true)
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
                            .padding(.trailing, 8)
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
        if animated {
            withAnimation(.easeInOut(duration: duration)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    /// 开始或重置自动滚动锁定倒计时（仅在识别期间生效）
    private func lockAutoScroll(_ proxy: ScrollViewProxy) {
        guard viewModel.state == .listening else { return }
        autoScrollLocked = true
        autoScrollUnlockTask?.cancel()
        let seconds = max(1, autoScrollLockSeconds)
        autoScrollUnlockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            autoScrollLocked = false
            // 锁定结束平滑滑回最新位置，而不是等下一段文字突然拉过去
            scrollToBottom(proxy, animated: true, force: true, duration: 0.5)
        }
    }

    private func resumeAutoScroll(_ proxy: ScrollViewProxy) {
        autoScrollUnlockTask?.cancel()
        autoScrollLocked = false
        scrollToBottom(proxy, animated: true, force: true)
    }

    /// 右侧弹出的锁定时间调节条：上下滑动设置暂停自动跟随的秒数
    private func autoScrollLockControl(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            verticalLockSlider(proxy)
                .frame(width: 28, height: 110)

            Text("\(Int(autoScrollLockSeconds))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                resumeAutoScroll(proxy)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到最新")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
    }

    private func verticalLockSlider(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fraction = CGFloat((autoScrollLockSeconds - 1) / 29)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: max(4, height * fraction))
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.18), radius: 2)
                    .offset(y: -(height - 14) * fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newFraction = 1 - value.location.y / height
                        let seconds = 1 + Double(round(Double(newFraction) * 29))
                        autoScrollLockSeconds = min(30, max(1, seconds))
                        lockAutoScroll(proxy)
                    }
            )
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
                    HStack(spacing: 8) {
                        liveActivityButton
                        pipButton
                    }
                    .padding(.horizontal, 8)
                    .glassEffect(.regular, in: Capsule())

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
            viewModel.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.red).interactive(), in: Circle())
        .accessibilityLabel("停止识别")
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
        .accessibilityLabel(viewModel.isPictureInPictureActive ? "退出画中画字幕" : "在画中画显示字幕")
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