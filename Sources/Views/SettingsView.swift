import SwiftUI

/// 设置页：识别、音频来源、字幕浮窗、AI 引擎、记录标题
struct SettingsView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService

    @State private var apiKeyInput = ""
    @State private var apiKeyLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    recognitionSection
                    audioSourceSection
                    liveActivitySection
                    aiSection
                    recordSection
                }
                .softTopEdgeEffect()

                Text("版本 \(appVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !apiKeyLoaded {
                    apiKeyInput = settings.apiKey
                    apiKeyLoaded = true
                }
            }
        }
    }

    // MARK: - 识别

    private var recognitionSection: some View {
        Section {
            LabeledContent("识别引擎", value: "Apple SpeechAnalyzer")
            LabeledContent("运行方式", value: "本机识别（音频不上传）")
        } header: {
            Text("识别")
        } footer: {
            Text("iOS 26 起使用苹果新一代本机语音模型，自动断句、标点与上下文纠错；首次使用某语言时会自动下载对应模型。")
        }
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
        } header: {
            Text("灵动岛与小窗口")
        } footer: {
            Text("自动模式：有灵动岛的 iPhone 使用灵动岛，iPad 等机型默认使用画中画小窗口。「长条」画中画更适合单行字幕。")
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

    // MARK: - 字幕记录

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
            Text("字幕记录")
        } footer: {
            Text("「位置」显示录制地点（需定位权限），无法定位时显示首句字幕；「AI 标题」使用已有摘要首行，无摘要时显示时间。")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}