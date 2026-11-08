import SwiftUI

/// 实时字幕主界面：顶部大字幕 + 分段记录 + 悬浮控制栏（麦克风 / 系统共享音频）
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService

    private let broadcastExtensionID = "com.example.sublingo.broadcast"

    var body: some View {
        VStack(spacing: 0) {
            header
            captionStage
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

    // MARK: - 顶部大字幕

    private var captionStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayOriginal)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            if let translated = displayTranslation {
                Text(translated)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.segments.count)
        .animation(.easeInOut(duration: 0.3), value: viewModel.segments.last?.translatedText)
    }

    private var displayOriginal: String {
        if !viewModel.livePartialText.isEmpty {
            return viewModel.livePartialText
        }
        if let last = viewModel.segments.last {
            return last.originalText
        }
        return ""
    }

    private var displayTranslation: String? {
        guard settings.realtimeTranslationEnabled,
              viewModel.livePartialText.isEmpty,
              let last = viewModel.segments.last else { return nil }
        return last.displayTranslatedText
    }

    // MARK: - 分段记录

    private var segmentList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.segments) { segment in
                    CaptionSegmentRow(segment: segment) {
                        polish(segment)
                    }
                }
            }
            .padding(.vertical, 12)
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

    /// 系统共享音频主按钮：自定义蓝色玻璃外观，底层用系统广播选择器接收点击
    private var systemAudioButton: some View {
        ZStack {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
            BroadcastPickerView(preferredExtension: broadcastExtensionID)
                .frame(width: 56, height: 56)
                .opacity(0.02)
        }
        .glassEffect(.regular.tint(Color.accentColor).interactive(), in: Circle())
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
        .disabled(viewModel.segments.isEmpty && viewModel.livePartialText.isEmpty)
        .accessibilityLabel("清空字幕")
    }

    /// 语言切换：源语言、目标语言各一块液态玻璃胶囊，中间箭头保持透明可点击对换
    private var languageControls: some View {
        HStack(spacing: 2) {
            sourceLanguageMenu
                .glassEffect(.regular.interactive(), in: Capsule())
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
                .glassEffect(.regular.interactive(), in: Capsule())
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
            .background(.quaternary, in: Capsule())
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: "（").first ?? name
    }
}