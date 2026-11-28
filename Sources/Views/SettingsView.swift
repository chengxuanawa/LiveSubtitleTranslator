import SwiftUI

/// 设置页：实时字幕、字幕浮窗、记录与 AI
struct SettingsView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var speakerDiarization: SpeakerDiarizationService

    @State private var apiKeyInput = ""
    @State private var apiKeyLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                captionSection
                floatingCaptionSection
                historyAndAISection
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

    private var captionSection: some View {
        Section {
            Picker("音频来源", selection: Binding(
                get: { settings.audioSourceMode.rawValue },
                set: { viewModel.setAudioSourceMode(AudioSourceMode(rawValue: $0) ?? .microphone) }
            )) {
                ForEach(AudioSourceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Toggle("识别时保持屏幕常亮", isOn: Binding(
                get: { settings.keepScreenOnWhileRecognizing },
                set: { settings.keepScreenOnWhileRecognizing = $0 }
            ))
            Toggle("标注说话人（实验）", isOn: speakerExperimentBinding)
            if settings.speakerDiarizationExperiment {
                speakerDetails
            }
        } header: {
            Text("实时字幕")
        } footer: {
            Text("语音识别在设备端运行。")
        }
    }

    private var speakerDetails: some View {
        DisclosureGroup {
            LabeledContent("模型", value: speakerDiarization.modelNickname)
            LabeledContent("模型大小", value: speakerDiarization.modelSizeText)
            LabeledContent("已识别人数", value: speakerCountText)
            LabeledContent("说话人", value: speakerDiarization.speakerSummaryText)
            LabeledContent("最近窗口耗时", value: lastChunkText)
            LabeledContent("处理速度", value: realtimeFactorText)
            LabeledContent("设备热状态", value: speakerDiarization.thermalStateText)
            Text("模型下载完成后可离线使用。更改开关后，下次开始识别时生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } label: {
            LabeledContent("说话人详情") {
                HStack(spacing: 6) {
                    if speakerDiarization.isPreparingModel {
                        ProgressView().controlSize(.mini)
                    }
                    Text(speakerDiarization.statusText)
                }
                .foregroundStyle(.secondary)
            }
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

    private var floatingCaptionSection: some View {
        Section {
            Picker("显示方式", selection: Binding(
                get: { settings.visualMode.rawValue },
                set: { settings.visualMode = VisualMode(rawValue: $0) ?? .auto }
            )) {
                ForEach(VisualMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Toggle("录制时自动开启浮窗", isOn: $settings.autoStartLiveActivity)
            DisclosureGroup("画中画设置") {
                pictureInPictureSettings
            }
        } header: {
            Text("字幕浮窗")
        }
    }

    @ViewBuilder
    private var pictureInPictureSettings: some View {
        Picker("形状", selection: Binding(
            get: { settings.pipShape.rawValue },
            set: { settings.pipShape = PiPShape(rawValue: $0) ?? .standard }
        )) {
            ForEach(PiPShape.allCases) { shape in
                Text(shape.displayName).tag(shape.rawValue)
            }
        }
        pipFontScaleRow(
            title: "原文字号",
            value: Binding(
                get: { settings.pipOriginalFontScale },
                set: { settings.pipOriginalFontScale = $0 }
            )
        )
        pipFontScaleRow(
            title: "译文字号",
            value: Binding(
                get: { settings.pipTranslatedFontScale },
                set: { settings.pipTranslatedFontScale = $0 }
            )
        )
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

    private var historyAndAISection: some View {
        Section {
            Picker("记录标题", selection: Binding(
                get: { settings.recordTitleStyle.rawValue },
                set: { settings.recordTitleStyle = RecordTitleStyle(rawValue: $0) ?? .time }
            )) {
                ForEach(RecordTitleStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            Picker("AI 引擎", selection: Binding(
                get: { settings.aiProviderMode.rawValue },
                set: { settings.aiProviderMode = AIProviderMode(rawValue: $0) ?? .auto }
            )) {
                ForEach(AIProviderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            LabeledContent("AI 状态", value: aiService.statusText)
            if settings.aiProviderMode == .api {
                apiSettings
            } else if settings.aiProviderMode == .auto {
                DisclosureGroup("自定义 AI API") {
                    apiSettings
                }
            }
        } header: {
            Text("记录与 AI")
        } footer: {
            Text("AI 用于字幕分段、摘要和译文润色。")
        }
    }

    @ViewBuilder
    private var apiSettings: some View {
        TextField("API 地址（OpenAI 兼容）", text: $settings.aiAPIEndpoint)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        TextField("模型名称", text: $settings.aiAPIModel)
            .autocorrectionDisabled()
        SecureField("API Key（可选）", text: $apiKeyInput)
            .onChange(of: apiKeyInput) { _, newValue in
                settings.setAPIKey(newValue)
            }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}