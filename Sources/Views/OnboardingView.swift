import SwiftUI

/// 首次启动：选择 AI 引擎（设备支持苹果智能时优先推荐，否则引导配置自定义 API）
struct OnboardingView: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var aiService: AIService
    @Environment(\.dismiss) private var dismiss

    private enum Choice {
        case apple
        case api
        case off
    }

    @State private var choice: Choice = .off
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    choiceRow(
                        .apple,
                        title: "苹果智能（设备端）",
                        subtitle: "免费 · 离线 · 无需配置",
                        recommended: AIService.appleIntelligenceAvailable,
                        disabled: !AIService.appleIntelligenceAvailable,
                        disabledReason: AIService.appleIntelligenceUnavailableReason
                    )
                    choiceRow(.api, title: "自定义 AI API", subtitle: "使用你自己的大模型服务")
                    choiceRow(.off, title: "关闭 AI 功能", subtitle: "仅使用基础字幕与翻译")
                } header: {
                    Text("选择 AI 引擎")
                } footer: {
                    Text(choiceNote)
                }

                if choice == .api {
                    Section {
                        TextField("接口地址（如 https://api.openai.com/v1/chat/completions）", text: $endpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("模型名称（如 gpt-4o-mini）", text: $model)
                            .autocorrectionDisabled()
                        SecureField("API Key（可选）", text: $apiKey)
                    } header: {
                        Text("API 配置")
                    } footer: {
                        Text("兼容 OpenAI Chat Completions 协议的服务均可使用（OpenAI、DeepSeek、Ollama 本地服务等）。Key 将保存在系统钥匙串中。")
                    }
                }
            }
            .navigationTitle("AI 功能设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        commit()
                    }
                    .disabled(choice == .api && trimmed(endpoint).isEmpty)
                }
            }
            .onAppear {
                choice = AIService.appleIntelligenceAvailable ? .apple : .api
                endpoint = settings.aiAPIEndpoint
                model = settings.aiAPIModel
                apiKey = settings.apiKey
            }
        }
    }

    // MARK: - 选项行

    private func choiceRow(
        _ value: Choice,
        title: String,
        subtitle: String,
        recommended: Bool = false,
        disabled: Bool = false,
        disabledReason: String? = nil
    ) -> some View {
        Button {
            guard !disabled else { return }
            choice = value
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .foregroundStyle(disabled ? .secondary : .primary)
                        if recommended {
                            Text("推荐")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(disabled ? (disabledReason ?? "不可用") : subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if choice == value {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(disabled)
        .tint(.primary)
    }

    private var choiceNote: String {
        if choice == .apple, !AIService.appleIntelligenceAvailable {
            return "当前设备不可用苹果智能：\(AIService.appleIntelligenceUnavailableReason ?? "设备或系统不支持")。建议选择自定义 API 或关闭。"
        }
        return "苹果智能用于会话摘要与译文润色（iOS 26+ 且设备支持）；基础字幕与翻译始终可用。可稍后在「设置 → AI 功能」中更改。"
    }

    // MARK: - 提交

    private func commit() {
        switch choice {
        case .apple: settings.aiProviderMode = .apple
        case .api: settings.aiProviderMode = .api
        case .off: settings.aiProviderMode = .off
        }
        settings.aiAPIEndpoint = trimmed(endpoint)
        settings.aiAPIModel = trimmed(model)
        settings.setAPIKey(apiKey)
        settings.hasCompletedSetup = true
        dismiss()
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}