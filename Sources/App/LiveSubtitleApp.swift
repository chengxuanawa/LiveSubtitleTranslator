import SwiftUI

@main
struct LiveSubtitleApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var viewModel: LiveSessionViewModel
    @StateObject private var transcriptStore: TranscriptStore
    @StateObject private var aiService: AIService

    init() {
        let settings = SettingsStore()
        let transcriptStore = TranscriptStore()
        let aiService = AIService(settings: settings)
        let viewModel = LiveSessionViewModel(
            speechRecognizer: SpeechRecognizerService(),
            translationService: TranslationService(),
            settings: settings,
            transcriptStore: transcriptStore,
            liveActivity: LiveActivityService(),
            systemAudioServer: SystemAudioStreamServer(),
            aiService: aiService
        )
        _settings = StateObject(wrappedValue: settings)
        _transcriptStore = StateObject(wrappedValue: transcriptStore)
        _viewModel = StateObject(wrappedValue: viewModel)
        _aiService = StateObject(wrappedValue: aiService)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                // 左边缘手势优先给 App；真正的返回识别器在历史详情页的
                // EdgeSwipeBackView 中，避免台前调度/窗口化下被系统手势抢走
                .defersSystemGestures(on: .leading)
                .environmentObject(viewModel)
                .environmentObject(settings)
                .environmentObject(transcriptStore)
                .environmentObject(aiService)
                .sheet(isPresented: onboardingBinding) {
                    OnboardingView()
                        .environmentObject(settings)
                        .environmentObject(aiService)
                        .interactiveDismissDisabled()
                }
        }
    }

    /// 首次启动展示 AI 引擎选择引导
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedSetup },
            set: { settings.hasCompletedSetup = !$0 }
        )
    }
}
