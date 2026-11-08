import Foundation
import SwiftUI

/// 应用设置（通过 UserDefaults 持久化；API Key 存系统钥匙串）
@MainActor
final class SettingsStore: ObservableObject {
    @AppStorage("sourceLanguageIdentifier") var sourceLanguageIdentifier = "zh-Hans"
    @AppStorage("targetLanguageIdentifier") var targetLanguageIdentifier = "en-US"
    /// 录制开始时自动开启字幕浮窗（灵动岛或画中画，按机型自动选择）
    @AppStorage("autoStartLiveActivity") var autoStartLiveActivity = false
    /// 音频来源：麦克风 / 系统共享音频
    @AppStorage("audioSourceModeRaw") private var audioSourceModeRaw = AudioSourceMode.microphone.rawValue
    /// 字幕记录列表标题样式
    @AppStorage("recordTitleStyleRaw") private var recordTitleStyleRaw = RecordTitleStyle.time.rawValue
    /// 字幕浮窗显示方式
    @AppStorage("visualModeRaw") private var visualModeRaw = VisualMode.auto.rawValue
    /// 画中画窗口形状
    @AppStorage("pipShapeRaw") private var pipShapeRaw = PiPShape.standard.rawValue
    /// 是否开启实时翻译（录制中可通过主按钮左侧的玻璃按钮切换）
    @AppStorage("realtimeTranslationEnabled") var realtimeTranslationEnabled = true

    // AI 底层配置保留（仅用于摘要数据兼容）
    @AppStorage("aiProviderModeRaw") private var aiProviderModeRaw = AIProviderMode.auto.rawValue
    @AppStorage("aiAPIEndpoint") var aiAPIEndpoint = ""
    @AppStorage("aiAPIModel") var aiAPIModel = ""
    @AppStorage("hasCompletedSetup") var hasCompletedSetup = false

    var aiProviderMode: AIProviderMode {
        get { AIProviderMode(rawValue: aiProviderModeRaw) ?? .auto }
        set { aiProviderModeRaw = newValue.rawValue }
    }

    var audioSourceMode: AudioSourceMode {
        get { AudioSourceMode(rawValue: audioSourceModeRaw) ?? .microphone }
        set { audioSourceModeRaw = newValue.rawValue }
    }

    var recordTitleStyle: RecordTitleStyle {
        get { RecordTitleStyle(rawValue: recordTitleStyleRaw) ?? .time }
        set { recordTitleStyleRaw = newValue.rawValue }
    }

    var visualMode: VisualMode {
        get { VisualMode(rawValue: visualModeRaw) ?? .auto }
        set { visualModeRaw = newValue.rawValue }
    }

    var pipShape: PiPShape {
        get { PiPShape(rawValue: pipShapeRaw) ?? .standard }
        set { pipShapeRaw = newValue.rawValue }
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