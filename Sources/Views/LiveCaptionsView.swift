import SwiftUI
import UIKit

/// 实时字幕主界面：顶部大字幕 + 分段记录 + 悬浮控制栏（麦克风 / 系统共享音频）
/// 具体 UI 与交互按职责拆分在同目录的 +Header / +Transcript / +Controls 扩展中。
struct LiveCaptionsView: View {

    @EnvironmentObject var viewModel: LiveSessionViewModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var aiService: AIService
    /// 横屏兜底判断：部分情况下窗口尺寸更新滞后，紧凑高度也视为横屏
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let broadcastExtensionID = "com.example.sublingo.broadcast"
    let bottomAnchorID = "transcript-bottom"

    /// 已经逐字吐出的实时文本
    @State var revealedText = ""
    /// 末尾字符是否已结束渐显（没有新字后恢复完全清晰）
    @State var tailSettled = true
    /// 逐字吐字任务
    @State var revealTask: Task<Void, Never>?
    /// 用户滑离底部后保持固定，默认不再自动拉回
    @State var autoScrollLocked = false
    /// 可选的自动回到实时倒计时（0 表示一直固定）
    @State var autoScrollUnlockTask: Task<Void, Never>?
    @AppStorage("autoScrollResumeSeconds") var autoScrollResumeSeconds: Double = 0
    /// 调整时间时显示的气泡
    @State var showLockTimePopup = false
    /// 拖动条纹图标设定时间的起始值
    @State var lockTimeDragStart: Double?
    /// 按住定时条纹时放大反馈
    @State var isLockTimeExpanded = false
    /// 按住定时条纹的起始时刻，用于区分单点与拖动
    @State var lockTimePressStartedAt: Date?
    /// 系统共享面板正在唤起：给出即时反馈并避免重复点击排队
    @State var isSystemPanelRequesting = false
    @State var systemPanelRequestTask: Task<Void, Never>?
    /// 单词释义弹窗
    @State var wordLookupRequest: WordLookupRequest?

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height || verticalSizeClass == .compact
            // iPad 窗口化 / 台前调度下的窗口控制按钮会占用左上角，
            // 用系统给的容器圆角内边距把顶栏内容整体右移避让
            let windowControlsInset = proxy.containerCornerInsets.topLeading.width
            Group {
                if isLandscape {
                    // 横屏单栏铺满：实时文字本来就在列表底部更新，
                    // 不再单独分栏；系统 Tab 栏在左下，悬浮按钮让到右下
                    transcriptColumn(isLandscape: true, windowControlsInset: windowControlsInset)
                        .safeAreaPadding(.bottom, 76)
                        .overlay(alignment: .bottomTrailing) {
                            floatingControls
                                .padding(.trailing, 16)
                                .padding(.bottom, 12)
                        }
                } else {
                    transcriptColumn(isLandscape: false, windowControlsInset: windowControlsInset)
                        .safeAreaPadding(.bottom, 96)
                        .overlay(alignment: .bottomTrailing) {
                            floatingControls
                                .padding(.trailing, 20)
                                .padding(.bottom, 16)
                        }
                }
            }
            .frame(maxWidth: isLandscape ? .infinity : 900, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .onAppear {
                viewModel.prepareSystemAudioServer()
                // 重新进入页面直接对齐当前文本，避免重放逐字动画
                revealedText = viewModel.liveDisplayText
                tailSettled = true
                revealTask?.cancel()
                revealTask = nil
            }
            .onChange(of: viewModel.liveDisplayText) { _, _ in
                syncRevealedText()
            }
            .onChange(of: settings.keepScreenOnWhileRecognizing) { _, _ in
                viewModel.refreshIdleTimer()
            }
            .onChange(of: settings.pipOriginalFontScale) { _, _ in
                viewModel.refreshPictureInPicture()
            }
            .onChange(of: settings.pipTranslatedFontScale) { _, _ in
                viewModel.refreshPictureInPicture()
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
            }
            .sheet(item: $wordLookupRequest) { request in
                WordLookupCard(request: request)
                    .presentationDetents([.height(300), .medium])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
        }
    }

    /// 字幕栏：顶栏作为滚动视图的安全区插入视图，列表会滑到顶栏与状态栏下方
    private func transcriptColumn(isLandscape: Bool, windowControlsInset: CGFloat) -> some View {
        segmentList(isLandscape: isLandscape)
            .safeAreaInset(edge: .top, spacing: 0) {
                // 顶栏背后的柔和模糊：列表上滚到标题栏下方时逐渐虚化淡出
                header(isLandscape: isLandscape, windowControlsInset: windowControlsInset)
                    .background {
                        SoftTopBlurView()
                            .ignoresSafeArea(edges: .top)
                    }
            }
    }
}
