import SwiftUI

/// 根视图：实时字幕 / 字幕记录 / 设置 三个页签
struct RootTabView: View {
    var body: some View {
        TabView {
            LiveCaptionsView()
                .tabItem {
                    Label("实时字幕", systemImage: "captions.bubble")
                }
            TranscriptListView()
                .tabItem {
                    Label("字幕记录", systemImage: "list.bullet.rectangle")
                }
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}