import SwiftUI

/// 设置页：识别、音频来源、字幕浮窗、AI 引擎、记录标题
struct SettingsView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var speakerDiarization: SpeakerDiarizationService

    @State private var apiKeyInput = ""
    @State private var apiKeyLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                recognitionSection
                speakerDiarizationSection
                audioSourceSection
                liveActivitySection
                aiSection
                recordSection
                // 版本号随页面滚动，放在内容末尾，不单独占一个列表行
                Text("版本 \(appVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .softTopEdgeEffect()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !apiKeyLoaded {
                    apiKeyInput = settings.apiKey
                    apiKeyLoaded = true
                }
                // 已开启实验但模型缺失（首装/被系统清理）时自动补下载
                if settings.speakerDiarizationExperiment {
                    Task { await speakerDiarization.prepareModel() }
                }
            }
        }
    }

    // MARK: - 识别

    private var recognitionSection: some View {
        Section {
            LabeledContent("识别引擎", value: "Apple SpeechAnalyzer（设备端）")
            LabeledContent("运行方式", value: "仅本机（不可切换）")
            Toggle("识别时保持屏幕常亮", isOn: Binding(
                get: { settings.keepScreenOnWhileRecognizing },
                set: { settings.keepScreenOnWhileRecognizing = $0 }
            ))
        } header: {
            Text("识别")
        } footer: {
            Text("开启后，在实时字幕识别期间不会自动锁屏；停止识别立即恢复正常息屏。iOS 26 的 SpeechAnalyzer 只提供设备端识别，苹果已不提供第三方云端语音识别路径；云端模型仅用于「AI 功能」中的自定义 AI API。")
        }
    }

    // MARK: - 说话人分离（实验）

    private var speakerDiarizationSection: some View {
        Section {
            Toggle("字幕标注说话人（实验）", isOn: speakerExperimentBinding)
            if settings.speakerDiarizationExperiment {
                LabeledContent("模型昵称", value: speakerDiarization.modelNickname)
                LabeledContent("模型大小") {
                    HStack(spacing: 6) {
                        if speakerDiarization.isPreparingModel {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(speakerDiarization.modelSizeText)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("模型状态", value: speakerDiarization.statusText)
                LabeledContent("已识别人数", value: speakerCountText)
                LabeledContent("说话人", value: speakerDiarization.speakerSummaryText)
                LabeledContent("最近窗口耗时", value: lastChunkText)
                LabeledContent("处理速度", value: realtimeFactorText)
                LabeledContent("设备热状态", value: speakerDiarization.thermalStateText)
            }
        } header: {
            Text("说话人分离（实验）")
        } footer: {
            Text("开启后自动在设备本机下载并运行 FluidAudio 说话人分离模型，之后完全离线，音频不出本机。给每条字幕标注「说话人 N」；男声/女声由基频粗略估计，两人对话时标签可能滞后或误判，仅供参考。开启后需重新开始识别才生效。")
        }
    }

    /// 开关打开时立即预下载模型，不必先开始识别
    private var speakerExperimentBinding: Binding<Bool> {
        Binding(
            get: { settings.speakerDiarizationExperiment },
            set: { enabled in
                settings.speakerDiarizationExperiment = enabled
                guard enabled else { return }
                Task { await speakerDiarization.prepareModel() }
            }
        )
    }

    private var speakerCountText: String {
        speakerDiarization.speakerCount > 0 ? "\(speakerDiarization.speakerCount) 人" : "—"
    }

    private var lastChunkText: String {
        guard speakerDiarization.lastChunkSeconds > 0 else { return "—" }
        return String(format: "%.2f 秒 / 5 秒音频", speakerDiarization.lastChunkSeconds)
    }

    private var realtimeFactorText: String {
        guard speakerDiarization.realtimeFactor > 0 else { return "—" }
        return String(format: "%.1f 倍实时", speakerDiarization.realtimeFactor)
    }

    // MARK: - 音频来源

    private var audioSourceSection: some View {
        Section {
            Picker("音频来源", selection: Binding(
                get: { settings.audioSourceMode.rawValue },
                set: { settings.audioSourceMode = AudioSourceMode(rawValue: $0) ?? .microphone }
            )) {
                ForEach(AudioSourceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        } header: {
            Text("音频来源")
        } footer: {
            Text("系统共享音频可转写设备播放的声音。")
        }
    }

    // MARK: - 灵动岛与小窗口

    private var liveActivitySection: some View {
        Section {
            Picker("显示方式", selection: Binding(
                get: { settings.visualMode.rawValue },
                set: { settings.visualMode = VisualMode(rawValue: $0) ?? .auto }
            )) {
                ForEach(VisualMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Toggle("录制开始时自动开启字幕浮窗", isOn: $settings.autoStartLiveActivity)
            Picker("画中画形状", selection: Binding(
                get: { settings.pipShape.rawValue },
                set: { settings.pipShape = PiPShape(rawValue: $0) ?? .standard }
            )) {
                ForEach(PiPShape.allCases) { shape in
                    Text(shape.displayName).tag(shape.rawValue)
                }
            }
            pipFontScaleRow(
                title: "画中画原文字号",
                value: Binding(
                    get: { settings.pipOriginalFontScale },
                    set: { settings.pipOriginalFontScale = $0 }
                )
            )
            pipFontScaleRow(
                title: "画中画译文字号",
                value: Binding(
                    get: { settings.pipTranslatedFontScale },
                    set: { settings.pipTranslatedFontScale = $0 }
                )
            )
        } header: {
            Text("灵动岛与小窗口")
        } footer: {
            Text("自动模式：有灵动岛的 iPhone 使用灵动岛，iPad 等机型默认使用画中画小窗口。「长条」画中画更适合单行字幕；识别中切换形状会自动按新比例重开小窗。字号仅影响画中画字幕，原文与译文可分别调节。")
        }
    }

    /// 画中画字号滑块：标题 + 百分比，范围 60%–160%
    private func pipFontScaleRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0.6...1.6, step: 0.05)
                .accessibilityLabel(title)
        }
    }

    // MARK: - AI 功能

    private var aiSection: some View {
        Section {
            Picker("AI 引擎", selection: Binding(
                get: { settings.aiProviderMode.rawValue },
                set: { settings.aiProviderMode = AIProviderMode(rawValue: $0) ?? .auto }
            )) {
                ForEach(AIProviderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            LabeledContent("当前状态", value: aiService.statusText)
            if settings.aiProviderMode == .api || settings.aiProviderMode == .auto {
                TextField("API 地址（OpenAI 兼容 /chat/completions）", text: $settings.aiAPIEndpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型名称（如 gpt-4o-mini）", text: $settings.aiAPIModel)
                    .autocorrectionDisabled()
                SecureField("API Key（可选，本地服务可留空）", text: $apiKeyInput)
                    .onChange(of: apiKeyInput) { _, newValue in
                        settings.setAPIKey(newValue)
                    }
            }
        } header: {
            Text("AI 功能")
        } footer: {
            Text(aiFooterText)
        }
    }

    private var aiFooterText: String {
        if AIService.appleIntelligenceAvailable {
            return "AI 摘要与译文润色由所选引擎提供。苹果智能在设备端运行，免费、离线、无需配置；也可切换到自定义 OpenAI 兼容 API。"
        }
        let reason = AIService.appleIntelligenceUnavailableReason ?? "设备或系统不支持"
        return "此设备不可用苹果智能（\(reason)）。可配置自定义 AI API，或关闭 AI 功能仅使用基础字幕与翻译。API Key 保存在系统钥匙串中。"
    }

    // MARK: - 历史

    private var recordSection: some View {
        Section {
            Picker("记录标题", selection: Binding(
                get: { settings.recordTitleStyle.rawValue },
                set: { settings.recordTitleStyle = RecordTitleStyle(rawValue: $0) ?? .time }
            )) {
                ForEach(RecordTitleStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
        } header: {
            Text("历史")
        } footer: {
            Text("「位置」显示录制地点（需定位权限），无法定位时显示首句字幕；「AI 标题」会在录制结束后自动生成摘要并显示首行，AI 引擎不可用时显示时间。")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}