import SwiftUI

@main
struct LiveSubtitleApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var viewModel: LiveSessionViewModel
    @StateObject private var transcriptStore: TranscriptStore

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
        _settings = StateObject(wrappedValue: settings)
        _transcriptStore = StateObject(wrappedValue: transcriptStore)
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(viewModel)
                .environmentObject(settings)
                .environmentObject(transcriptStore)
        }
    }
}