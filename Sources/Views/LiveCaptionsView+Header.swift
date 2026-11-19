import SwiftUI

// MARK: - 顶部标题栏与语言切换

extension LiveCaptionsView {

    /// 左侧清空 + 标题，右侧语言胶囊（横屏时标题居中，与系统 Tab 栏的横屏样式统一）
    func header(isLandscape: Bool, windowControlsInset: CGFloat) -> some View {
        Group {
            if isLandscape {
                ZStack {
                    Text("实时字幕")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 12) {
                        clearButton
                        Spacer(minLength: 0)
                        languageControls
                    }
                    .padding(.leading, windowControlsInset)
                }
            } else {
                HStack(spacing: 12) {
                    clearButton
                    Text("实时字幕")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    languageControls
                }
                .padding(.leading, windowControlsInset)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isLandscape ? 2 : 6)
        .padding(.bottom, isLandscape ? 4 : 8)
    }

    private var clearButton: some View {
        Button {
            viewModel.clearSegments()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(viewModel.segments.isEmpty && viewModel.liveDisplayText.isEmpty)
        .accessibilityLabel("清空字幕")
    }

    /// 语言切换：源语言、目标语言各一块液态玻璃胶囊，中间箭头保持透明可点击对换
    private var languageControls: some View {
        HStack(spacing: 2) {
            sourceLanguageMenu
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture { swapLanguages() }
                .accessibilityLabel("对换语言")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { swapLanguages() }
            targetLanguageMenu
        }
    }

    /// 对换识别语言与翻译语言
    private func swapLanguages() {
        let source = settings.sourceLanguageIdentifier
        settings.sourceLanguageIdentifier = settings.targetLanguageIdentifier
        settings.targetLanguageIdentifier = source
        settings.objectWillChange.send()
    }

    private var sourceLanguageMenu: some View {
        languageMenu("识别语言", selection: $settings.sourceLanguageIdentifier)
    }

    private var targetLanguageMenu: some View {
        languageMenu("翻译为", selection: $settings.targetLanguageIdentifier)
    }

    private func languageMenu(_ title: String, selection: Binding<String>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(LanguageOption.all) { option in
                    Text(option.displayName).tag(option.identifier)
                }
            }
        } label: {
            languageChip(LanguageOption.option(for: selection.wrappedValue).displayName)
        }
    }

    private func languageChip(_ name: String) -> some View {
        Text(shortName(name))
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: "（").first ?? name
    }
}
