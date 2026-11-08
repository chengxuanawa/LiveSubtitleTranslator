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
        let viewModel = LiveSessionViewModel(
            speechRecognizer: SpeechRecognizerService(),
            translationService: TranslationService(),
            settings: settings,
            transcriptStore: transcriptStore,
            liveActivity: LiveActivityService(),
            systemAudioServer: SystemAudioStreamServer()
        )
        let aiService = AIService(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _transcriptStore = StateObject(wrappedValue: transcriptStore)
        _viewModel = StateObject(wrappedValue: viewModel)
        _aiService = StateObject(wrappedValue: aiService)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(viewModel)
                .environmentObject(settings)
                .environmentObject(transcriptStore)
                .environmentObject(aiService)
        }
    }
}