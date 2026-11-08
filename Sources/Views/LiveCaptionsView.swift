import SwiftUI

/// 实时字幕主界面：顶部大字幕 + 分段记录 + 悬浮控制栏（麦克风 / 系统共享音频）
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService

    private let broadcastExtensionID = "com.example.sublingo.broadcast"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                captionStage
                segmentList
            }
            .overlay(alignment: .bottomTrailing) {
                floatingControls
            }
            .safeAreaPadding(.bottom, 140)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .navigationTitle("实时字幕")
            .navigationBarTitleDisplayMode(.inline)
            .softTopEdgeEffect()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    clearButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    languageControls
                }
            }
            .translationTask(source: sourceLanguage, target: targetLanguage) { session in
                viewModel.attachTranslationSession(session)
            }
            .onAppear {
                viewModel.prepareSystemAudioServer()
            }
        }
    }

    // MARK: - 翻译会话（由 SwiftUI translationTask 注入）

    private var sourceLanguage: Locale.Language {
        Locale.Language(identifier: settings.sourceLanguageIdentifier)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: settings.targetLanguageIdentifier)
    }

    // MARK: - 顶部大字幕（柔和材质，无分隔线）

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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(.ultraThinMaterial)
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
        guard viewModel.livePartialText.isEmpty, let last = viewModel.segments.last else { return nil }
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

    // MARK: - 悬浮控制栏（按钮悬浮在材质底栏之上）

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

            HStack(spacing: 16) {
                audioSourceButton

                if viewModel.audioSourceMode == .microphone {
                    recordButton
                } else {
                    BroadcastPickerView(preferredExtension: broadcastExtensionID)
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("开始系统广播")
                    if viewModel.state == .listening {
                        stopButton
                    }
                }

                if viewModel.state == .listening {
                    liveActivityButton
                    pipButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 4)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    /// 音频来源切换：麦克风 ↔ 系统共享音频
    private var audioSourceButton: some View {
        Button {
            if viewModel.state == .listening {
                viewModel.stop()
            }
            settings.audioSourceMode = settings.audioSourceMode == .microphone ? .systemAudio : .microphone
            settings.objectWillChange.send()
            if settings.audioSourceMode == .systemAudio {
                viewModel.prepareSystemAudioServer()
            }
        } label: {
            Image(systemName: settings.audioSourceMode == .microphone ? "mic" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.audioSourceMode == .microphone ? "切换到系统共享音频" : "切换到麦克风")
    }

    private var recordButton: some View {
        Button {
            viewModel.toggle()
        } label: {
            Image(systemName: viewModel.state == .listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(
                    (viewModel.state == .listening ? Color.red : Color.accentColor),
                    in: Circle()
                )
                .symbolEffect(.variableColor.iterative, isActive: viewModel.state == .listening)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.state == .listening ? "停止识别" : "开始识别")
    }

    private var stopButton: some View {
        Button {
            viewModel.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.red, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("停止识别")
    }

    private var liveActivityButton: some View {
        Button {
            viewModel.toggleLiveActivity()
        } label: {
            Image(systemName: viewModel.isLiveActivityActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(viewModel.isLiveActivityActive ? Color.accentColor : .secondary)
                .frame(width: 52, height: 52)
                .background(Color(.secondarySystemBackground), in: Circle())
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
                .frame(width: 52, height: 52)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isPictureInPictureActive ? "退出画中画字幕" : "在画中画显示字幕")
    }

    private var statusText: String {
        if viewModel.audioSourceMode == .systemAudio {
            switch viewModel.state {
            case .idle, .ended:
                return "点击广播按钮，在系统弹窗中选择「译幕」后开始共享；停止共享请在控制中心或状态栏点击红点"
            case .listening:
                if viewModel.isWaitingForBroadcast {
                    return "正在等待系统广播连接…请在系统弹窗中选择本 App"
                }
                return viewModel.isLiveActivityActive
                    ? "正在转写系统音频 · 设备端识别 · 灵动岛字幕已开启"
                    : "正在转写系统音频 · 设备端识别"
            }
        }

        switch viewModel.state {
        case .listening:
            return viewModel.isLiveActivityActive
                ? "正在聆听 · 设备端识别 · 灵动岛字幕已开启"
                : "正在聆听 · 设备端识别"
        case .idle:
            return "点击开始，麦克风将实时生成字幕"
        case .ended:
            return "已停止 · 记录已保存"
        }
    }

    // MARK: - 工具栏

    private var clearButton: some View {
        Button {
            viewModel.clearSegments()
        } label: {
            Image(systemName: "trash")
        }
        .disabled(viewModel.segments.isEmpty && viewModel.livePartialText.isEmpty)
        .accessibilityLabel("清空字幕")
    }

    /// 语言切换：源语言、目标语言各一个独立模块，中间箭头可点击对换
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
            .background(.quaternary, in: Capsule())
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: "（").first ?? name
    }
}