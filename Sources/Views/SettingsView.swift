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

    // MARK: - 后台显示

    private var liveActivitySection: some View {
        Section {
            Toggle("灵动岛 / 锁屏实时字幕", isOn: $settings.showInLiveActivity)
        } header: {
            Text("后台显示")
        } footer: {
            Text("开启后，识别期间的最新字幕会按句同步显示在灵动岛与锁屏；App 进入后台时继续通过麦克风聆听。若未显示，请在系统设置中允许本 App 的“实时活动”。")
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