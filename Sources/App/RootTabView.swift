import SwiftUI

/// 根视图：实时字幕 / 历史 / 设置 三个页签（使用系统浮动液态玻璃 Tab 栏）
struct RootTabView: View {
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
    }
}