import SwiftUI

/// 实时字幕主界面：字幕列表 + 实时预览 + 音频来源控制（麦克风 / 系统共享音频）
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore

    private let broadcastExtensionID = "com.example.sublingo.broadcast"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentList

                if !viewModel.livePartialText.isEmpty {
                    livePreviewBanner
                }

                Divider()
                controlBar
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .navigationTitle("实时字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    clearButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    settingsMenu
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

    // MARK: - 翻译会话（SwiftUI 注入，兼容 iOS 18+）

    private var sourceLanguage: Locale.Language {
        Locale.Language(identifier: settings.sourceLanguageIdentifier)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: settings.targetLanguageIdentifier)
    }

    // MARK: - 字幕列表（按时间从上到下逐行排列，不自动滚动）

    private var segmentList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if viewModel.segments.isEmpty {
                    ContentUnavailableView(
                        "点击下方按钮开始",
                        systemImage: "captions.bubble",
                        description: Text(emptyStateDescription)
                    )
                    .padding(.top, 100)
                } else {
                    ForEach(viewModel.segments) { segment in
                        CaptionSegmentRow(segment: segment)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var emptyStateDescription: String {
        viewModel.audioSourceMode == .microphone
            ? "本机识别语音并实时生成双语字幕"
            : "先点击下方广播按钮，在系统弹窗中选择本 App，再播放需要字幕的音频"
    }

    // MARK: - 实时预览

    private var livePreviewBanner: some View {
        Text(viewModel.livePartialText)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .transition(.opacity)
    }

    // MARK: - 控制区

    private var controlBar: some View {
        VStack(spacing: 8) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .onTapGesture { viewModel.dismissError() }
            }

            HStack(spacing: 20) {
                if viewModel.audioSourceMode == .microphone {
                    recordButton
                } else {
                    // 系统共享音频：广播按钮常驻，点击直接弹出系统共享界面
                    BroadcastPickerView(preferredExtension: broadcastExtensionID)
                        .frame(width: 56, height: 56)
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

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
                let mode = settings.requiresOnDeviceRecognition ? "设备端识别" : "在线识别"
                return viewModel.isLiveActivityActive
                    ? "正在转写系统音频 · \(mode) · 灵动岛字幕已开启"
                    : "正在转写系统音频 · \(mode)"
            }
        }

        switch viewModel.state {
        case .listening:
            let mode = settings.requiresOnDeviceRecognition ? "设备端识别" : "在线识别"
            return viewModel.isLiveActivityActive
                ? "正在聆听 · \(mode) · 灵动岛字幕已开启"
                : "正在聆听 · \(mode)"
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

    private var settingsMenu: some View {
        Menu {
            Picker("音频来源", selection: Binding(
                get: { settings.audioSourceMode.rawValue },
                set: { settings.audioSourceMode = AudioSourceMode(rawValue: $0) ?? .microphone }
            )) {
                ForEach(AudioSourceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Divider()
            Picker("识别语言", selection: $settings.sourceLanguageIdentifier) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
            Picker("翻译为", selection: $settings.targetLanguageIdentifier) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
        } label: {
            Text(settingsLabel)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
    }

    private var settingsLabel: String {
        let source = LanguageOption.option(for: settings.sourceLanguageIdentifier).displayName
        let target = LanguageOption.option(for: settings.targetLanguageIdentifier).displayName
        return "\(shortName(source)) → \(shortName(target))"
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: "（").first ?? name
    }
}