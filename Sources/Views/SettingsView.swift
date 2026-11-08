import SwiftUI
import UIKit

/// 设置页
struct SettingsView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService

    @State private var apiKeyInput = ""
    @State private var apiKeyLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                recognitionSection
                audioSourceSection
                liveActivitySection
                aiSection
                permissionSection
                aboutSection
            }
            .navigationTitle("设置")
            .onAppear {
                if !apiKeyLoaded {
                    apiKeyInput = settings.apiKey
                    apiKeyLoaded = true
                }
            }
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
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
        } header: {
            Text("语言")
        } footer: {
            Text("语言修改将在下一次开始识别时生效。")
        }
    }

    // MARK: - 识别

    private var recognitionSection: some View {
        Section {
            Toggle("仅在本机识别（离线）", isOn: $settings.requiresOnDeviceRecognition)
            Toggle("自动滚动到最新字幕", isOn: $settings.autoScrollToLatest)
        } header: {
            Text("识别")
        } footer: {
            Text("“仅在本机识别”开启后，语音不会上传到苹果服务器。部分设备或语言可能不支持离线识别，此时请关闭该选项。")
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
            Text("麦克风：直接收音并识别；系统共享音频：通过系统的屏幕录制广播捕获设备播放的声音（可转写其他 App 的视频 / 播客），需在系统弹窗中允许广播。切换在下次开始识别时生效。")
        }
    }

    // MARK: - 后台显示

    private var liveActivitySection: some View {
        Section {
            Toggle("录制开始时自动开启灵动岛字幕", isOn: $settings.autoStartLiveActivity)
        } header: {
            Text("灵动岛 / 锁屏字幕")
        } footer: {
            Text("默认关闭。录制中可随时点击主界面麦克风旁的按钮手动开启或关闭字幕投送。若未显示，请在系统设置中允许本 App 的“实时活动”。")
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
            LabeledContent("当前引擎", value: aiService.statusText)
        } header: {
            Text("AI 功能")
        } footer: {
            Text(aiFooterText)
        }
    }

    private var aiFooterText: String {
        if AIService.appleIntelligenceAvailable {
            return "AI 功能（会话摘要、译文润色）由所选引擎提供。苹果智能在设备端运行，免费、离线、无需配置。"
        }
        let reason = AIService.appleIntelligenceUnavailableReason ?? "设备或系统不支持"
        return "此设备不可用苹果智能（\(reason)）。可配置自定义 AI API（OpenAI 兼容），或关闭 AI 功能仅使用基础字幕翻译。API Key 保存在系统钥匙串中。"
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section {
            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                Label("打开应用权限设置", systemImage: "lock.shield")
            }
        } header: {
            Text("权限")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: appVersion)
            LabeledContent("最低系统", value: "iOS 18.0")
            LabeledContent("技术栈", value: "Speech · Translation · FoundationModels · ActivityKit")
        } header: {
            Text("关于")
        } footer: {
            Text("提示：受 iOS 沙盒限制，App 无法悬浮在其他应用上显示字幕。如需系统级实时字幕，可前往 系统设置 → 辅助功能 → 实时字幕 开启。")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}