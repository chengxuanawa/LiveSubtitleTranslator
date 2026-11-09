import SwiftUI

/// 实时字幕主界面：顶部大字幕 + 分段记录 + 悬浮控制栏（麦克风 / 系统共享音频）
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService

    private let broadcastExtensionID = "com.example.sublingo.broadcast"
    private let bottomAnchorID = "transcript-bottom"

    /// 文字更新时的模糊过渡强度
    @State private var textBlurRadius: CGFloat = 0
    /// 已稳定文字（正常显示）
    @State private var stableText = ""
    /// 最新新增文字（彩色 + 模糊）
    @State private var newText = ""
    /// 上一次完整实时文本，用于计算新增部分
    @State private var previousPartial = ""
    /// 控制新增文字的模糊过渡动画
    @State private var appearanceTask: Task<Void, Never>?
    /// 上一次模糊过渡的触发时间（限制触发频率，避免文字持续发虚）
    @State private var lastAppearancePulse = Date.distantPast
    /// 彩色流光相位（用 GPU 动画驱动，避免逐帧重排文字）
    @State private var gradientHue: Double = 0
    /// 用户滑动列表时临时暂停自动滚动
    @State private var autoScrollLocked = false
    @State private var autoScrollUnlockTask: Task<Void, Never>?
    @AppStorage("autoScrollLockSeconds") private var autoScrollLockSeconds: Double = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentList
        }
        .safeAreaPadding(.bottom, 96)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            floatingControls
        }
        .translationTask(source: sourceLanguage, target: targetLanguage) { session in
            viewModel.attachTranslationSession(session)
        }
        .onAppear {
            viewModel.prepareSystemAudioServer()
            // 重新进入页面时把已有实时文字当作普通文字，避免残留旧高亮
            stableText = viewModel.liveDisplayText
            newText = ""
            previousPartial = viewModel.liveDisplayText
            textBlurRadius = 0
            // 彩色流光只启动一次，气泡内容切换时不会重置
            gradientHue = 0
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                gradientHue = 360
            }
        }
        .onChange(of: viewModel.liveDisplayText) { _, newValue in
            updateHighlightedText(newValue)
        }
    }

    // MARK: - 顶部标题栏

    /// 左侧清空 + 标题，右侧语言胶囊（参考设计稿）
    private var header: some View {
        HStack(spacing: 12) {
            clearButton
            Text("实时字幕")
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            languageControls
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - 翻译会话（由 SwiftUI translationTask 注入）

    private var sourceLanguage: Locale.Language {
        Locale.Language(identifier: settings.sourceLanguageIdentifier)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: settings.targetLanguageIdentifier)
    }

    // MARK: - 实时字幕气泡（追加在列表底部）

    /// 正在识别中的字幕气泡：与已生成气泡同样式，自动换行
    private var liveBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if stableText.isEmpty && newText.isEmpty {
                Text("正在聆听…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack(alignment: .topLeading) {
                    // 底层：已稳定文字正常显示，新增文字透明占位以保持排版
                    liveTextLayer(hidingStable: false, hidingNew: true)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // 顶层：仅新增文字彩色显示，色相随时间流动，旧文字透明占位
                    liveTextLayer(hidingStable: true, hidingNew: false)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hueRotation(.degrees(gradientHue))
                        .blur(radius: textBlurRadius)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    /// 只让最新新增的文字带彩色渐变和模糊，旧文字保持普通样式
    private func updateHighlightedText(_ text: String) {
        guard !text.isEmpty else {
            stableText = ""
            newText = ""
            previousPartial = ""
            textBlurRadius = 0
            appearanceTask?.cancel()
            appearanceTask = nil
            return
        }

        let common = commonPrefixLength(previousPartial, text)
        stableText = String(text.prefix(common))
        newText = String(text.dropFirst(common))
        previousPartial = text

        animateNewTextAppearance()
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
    }

    /// 新文字先带模糊出现，再用一帧后的动画快速变清晰；连续到达的文字共用一次过渡
    private func animateNewTextAppearance() {
        guard appearanceTask == nil,
              Date().timeIntervalSince(lastAppearancePulse) > 0.6 else { return }
        lastAppearancePulse = Date()
        textBlurRadius = 5
        appearanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                textBlurRadius = 0
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            appearanceTask = nil
        }
    }

    /// 两层文字使用完全相同的字符结构，保证叠加时排版一致；
    /// 只给最后少量新增字符上色，控制每次刷新的字符串构建开销
    private func liveTextLayer(hidingStable: Bool, hidingNew: Bool) -> Text {
        var attributed = AttributedString()
        if !stableText.isEmpty {
            var piece = AttributedString(stableText)
            piece.foregroundColor = hidingStable ? Color.clear : Color.primary
            attributed.append(piece)
        }

        let newCharacters = Array(newText)
        guard !newCharacters.isEmpty else { return Text(attributed) }

        if hidingNew {
            var piece = AttributedString(newText)
            piece.foregroundColor = Color.clear
            attributed.append(piece)
            return Text(attributed)
        }

        // 超出彩色尾巴的字符由底层普通样式显示，顶层留空占位
        let coloredTail = 24
        let leading = max(0, newCharacters.count - coloredTail)
        if leading > 0 {
            var piece = AttributedString(String(newCharacters[0..<leading]))
            piece.foregroundColor = Color.clear
            attributed.append(piece)
        }

        let tail = newCharacters[leading...]
        for (index, character) in tail.enumerated() {
            var piece = AttributedString(String(character))
            let progress = tail.count > 1
                ? Double(index) / Double(tail.count - 1)
                : 0
            piece.foregroundColor = Color(
                hue: 0.5 + 0.45 * progress,
                saturation: 0.85,
                brightness: 0.95
            )
            attributed.append(piece)
        }
        return Text(attributed)
    }

    // MARK: - 分段记录

    private var segmentList: some View {
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        // 用户手动滑动时暂停自动跟随，避免被新文字拉回底部
                        lockAutoScroll()
                    }
            )
            .onAppear {
                scrollToBottom(proxy, animated: false, force: true)
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                // 全部使用无动画滚动，避免与高频实时文字滚动互相打断
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.liveDisplayText) { _, text in
                guard !text.isEmpty else { return }
                // 实时文字变化很频繁，不做滚动动画，减轻卡顿
                scrollToBottom(proxy, animated: false)
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
                if autoScrollLocked, viewModel.state == .listening {
                    autoScrollLockControl(proxy)
                        .padding(.trailing, 8)
                        .padding(.bottom, 120)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: autoScrollLocked)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard force || !autoScrollLocked else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    /// 开始或重置自动滚动锁定倒计时（仅在识别期间生效）
    private func lockAutoScroll() {
        guard viewModel.state == .listening else { return }
        autoScrollLocked = true
        autoScrollUnlockTask?.cancel()
        let seconds = max(1, autoScrollLockSeconds)
        autoScrollUnlockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            autoScrollLocked = false
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

            verticalLockSlider
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

    private var verticalLockSlider: some View {
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
                        lockAutoScroll()
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
        .padding(.trailing, 20)
        .padding(.bottom, 16)
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