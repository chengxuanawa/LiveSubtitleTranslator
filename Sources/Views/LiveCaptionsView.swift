import SwiftUI

/// 实时字幕主界面：字幕列表 + 实时预览 + 录音控制
struct LiveCaptionsView: View {

    @EnvironmentObject private var viewModel: LiveSessionViewModel
    @EnvironmentObject private var settings: SettingsStore

    private let bottomAnchorID = "bottomAnchor"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentList

                if !viewModel.livePartialText.isEmpty {
                    livePreviewBanner
                }

                Divider()
                controlBar
            }
            .navigationTitle("实时字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    clearButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    languageMenu
                }
            }
            .alert(
                "无法开始识别",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.dismissError() } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .translationTask(source: sourceLanguage, target: targetLanguage) { session in
                viewModel.attachTranslationSession(session)
            }
        }
    }

    // MARK: - 翻译会话（SwiftUI 注入，兼容 iOS 18+）

    private var sourceLanguage: Locale.Language {
        Locale.Language(identifier: settings.sourceLanguageIdentifier)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: settings.targetLanguageIdentifier)
    }

    // MARK: - 字幕列表

    private var segmentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if viewModel.segments.isEmpty {
                        ContentUnavailableView(
                            "点击下方按钮开始",
                            systemImage: "captions.bubble",
                            description: Text("本机识别语音并实时生成双语字幕")
                        )
                        .padding(.top, 100)
                    } else {
                        ForEach(viewModel.segments) { segment in
                            CaptionSegmentRow(segment: segment)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.livePartialText) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard settings.autoScrollToLatest else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - 实时预览

    private var livePreviewBanner: some View {
        Text(viewModel.livePartialText)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .transition(.opacity)
    }

    // MARK: - 控制区

    private var controlBar: some View {
        VStack(spacing: 8) {
            Button {
                viewModel.toggle()
            } label: {
                Image(systemName: viewModel.state == .listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(
                        (viewModel.state == .listening ? Color.red : Color.accentColor),
                        in: Circle()
                    )
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.state == .listening)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.state == .listening ? "停止识别" : "开始识别")

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        switch viewModel.state {
        case .listening:
            let mode = settings.requiresOnDeviceRecognition ? "设备端识别" : "在线识别"
            return settings.showInLiveActivity ? "正在聆听 · \(mode) · 灵动岛同步" : "正在聆听 · \(mode)"
        case .idle:
            return "点击开始，麦克风将实时生成字幕"
        case .ended:
            return "已停止 · 记录已保存"
        }
    }

    // MARK: - 工具栏

    private var clearButton: some View {
        Button {
            viewModel.clearSegments()
        } label: {
            Image(systemName: "trash")
        }
        .disabled(viewModel.segments.isEmpty && viewModel.livePartialText.isEmpty)
        .accessibilityLabel("清空字幕")
    }

    private var languageMenu: some View {
        Menu {
            Picker("识别语言", selection: $settings.sourceLanguageIdentifier) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
            Picker("翻译为", selection: $settings.targetLanguageIdentifier) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
        } label: {
            Text(pairLabel)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
    }

    private var pairLabel: String {
        let source = LanguageOption.option(for: settings.sourceLanguageIdentifier).displayName
        let target = LanguageOption.option(for: settings.targetLanguageIdentifier).displayName
        return "\(shortName(source)) → \(shortName(target))"
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: "（").first ?? name
    }
}