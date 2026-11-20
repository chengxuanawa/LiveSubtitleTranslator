import SwiftUI

// MARK: - 悬浮控制（右下角液态玻璃）

extension LiveCaptionsView {

    var floatingControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 4)
                    .onTapGesture { viewModel.dismissError() }
            }

            if let message = viewModel.infoMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 4)
                    .onTapGesture { viewModel.dismissInfoMessage() }
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

    /// 系统共享音频主按钮：自定义蓝色玻璃外观，点击后弹出系统广播选择器
    private var systemAudioButton: some View {
        Button {
            // 广播开始后 App 可能立刻退到后台，提前启动静音保活，避免本地监听被挂起
            viewModel.prepareSystemAudioBroadcast()
            presentSystemBroadcastPanel()
        } label: {
            Group {
                if isSystemPanelRequesting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.accentColor).interactive(), in: Circle())
        .background(broadcastPickerHost)
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
            // 系统共享面板唤起可能严重延迟，不能让它决定收尾时机：
            // 先立即结束识别并保存，提示用户到控制中心结束屏幕共享
            viewModel.endSystemAudioFromButton()
        } label: {
            Group {
                if isSystemPanelRequesting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 22, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.red).interactive(), in: Circle())
        .background(broadcastPickerHost)
        .accessibilityLabel("结束共享并停止识别")
    }

    /// 唤起系统共享面板：立即给出加载反馈，并在短时间内忽略重复点击，
    /// 避免系统面板响应慢时多次点击排队、之后一起弹出
    private func presentSystemBroadcastPanel() {
        guard !isSystemPanelRequesting else { return }
        isSystemPanelRequesting = true
        systemPanelRequestTask?.cancel()
        systemPanelRequestTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            isSystemPanelRequesting = false
        }
        BroadcastPickerTrigger.shared.trigger()
    }

    /// 系统广播选择器的透明宿主，供自定义按钮程序化调起共享控件
    private var broadcastPickerHost: some View {
        BroadcastPickerView(preferredExtension: broadcastExtensionID)
            .frame(width: 56, height: 56)
            .opacity(0.001)
            .allowsHitTesting(false)
    }

    private var liveActivityButton: some View {
        glassToggleButton(
            systemImage: viewModel.isLiveActivityActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle",
            isOn: viewModel.isLiveActivityActive,
            accessibilityLabel: viewModel.isLiveActivityActive ? "关闭灵动岛字幕" : "在灵动岛显示字幕"
        ) {
            viewModel.toggleLiveActivity()
        }
    }

    private var pipButton: some View {
        glassToggleButton(
            systemImage: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter",
            isOn: viewModel.isPictureInPictureActive,
            accessibilityLabel: viewModel.isPictureInPictureActive ? "退出画中画字幕" : "在画中画显示字幕"
        ) {
            viewModel.togglePictureInPicture()
        }
    }

    /// 系统共享音频：暂停/继续识别，广播与录屏不中断
    private var pauseButton: some View {
        glassToggleButton(
            systemImage: viewModel.isRecognitionPaused ? "play.fill" : "pause.fill",
            isOn: viewModel.isRecognitionPaused,
            accessibilityLabel: viewModel.isRecognitionPaused ? "继续识别" : "暂停识别"
        ) {
            viewModel.toggleRecognitionPause()
        }
    }

    /// 56×56 液态玻璃开关按钮（灵动岛 / 画中画 / 暂停共用）
    private func glassToggleButton(
        systemImage: String,
        isOn: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 56, height: 56)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}
