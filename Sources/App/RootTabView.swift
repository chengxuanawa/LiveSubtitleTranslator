import SwiftUI

/// 根视图：实时字幕 / 历史 / 设置 三个页签（使用系统浮动液态玻璃 Tab 栏）
struct RootTabView: View {
    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            Tab("实时字幕", systemImage: "captions.bubble") {
                LiveCaptionsView()
            }
            Tab("历史", systemImage: "list.bullet.rectangle") {
                TranscriptListView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .translationTask(source: sourceLanguage, target: targetLanguage) { session in
            viewModel.attachTranslationSession(session)
        }
    }

    private var sourceLanguage: Locale.Language {
        Locale.Language(identifier: settings.sourceLanguageIdentifier)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: settings.targetLanguageIdentifier)
    }
}
