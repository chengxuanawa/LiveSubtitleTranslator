import Foundation
import SwiftUI

/// 应用设置（通过 UserDefaults 持久化；API Key 存系统钥匙串）
@MainActor
final class SettingsStore: ObservableObject {
    @AppStorage("sourceLanguageIdentifier") var sourceLanguageIdentifier = "zh-Hans"
    @AppStorage("targetLanguageIdentifier") var targetLanguageIdentifier = "en-US"
    @AppStorage("requiresOnDeviceRecognition") var requiresOnDeviceRecognition = true
    @AppStorage("autoScrollToLatest") var autoScrollToLatest = true
    @AppStorage("showInLiveActivity") var showInLiveActivity = true

    // AI 引擎
    @AppStorage("aiProviderModeRaw") private var aiProviderModeRaw = AIProviderMode.auto.rawValue
    @AppStorage("aiAPIEndpoint") var aiAPIEndpoint = ""
    @AppStorage("aiAPIModel") var aiAPIModel = ""
    @AppStorage("hasCompletedSetup") var hasCompletedSetup = false

    var aiProviderMode: AIProviderMode {
        get { AIProviderMode(rawValue: aiProviderModeRaw) ?? .auto }
        set { aiProviderModeRaw = newValue.rawValue }
    }

    var isAPIConfigured: Bool {
        !aiAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var apiKey: String { KeychainStore.read() ?? "" }

    func setAPIKey(_ key: String) {
        if key.isEmpty {
            KeychainStore.delete()
        } else {
            KeychainStore.save(key)
        }
    }
}