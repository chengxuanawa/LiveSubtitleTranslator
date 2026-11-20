import SwiftUI
import UIKit

// MARK: - 实时字幕气泡、逐字吐字与分段列表

extension LiveCaptionsView {

    // MARK: 实时字幕气泡（追加在列表底部）

    /// 正在识别中的字幕气泡（列表中使用，左右留出与气泡相同的边距）
    private var liveBubble: some View {
        liveBubbleCore
            .padding(.horizontal, 12)
    }

    /// 正在识别中的字幕气泡本体：逐字显示，末尾字符渐显
    private var liveBubbleCore: some View {
        VStack(alignment: .leading, spacing: 6) {
            if revealedText.isEmpty {
                if viewModel.liveDisplayText.isEmpty {
                    Text(viewModel.isRecognitionPaused ? "已暂停识别，录屏仍在继续" : "正在聆听…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                liveRevealText
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.realtimeTranslationEnabled, !viewModel.isRecognitionPaused {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.top, 2)
                    Text(viewModel.pendingText.isEmpty ? "断句后生成译文" : "AI 整理分段中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .captionBubbleBackground()
    }

    /// 实时文字：末尾几个字符用透明度渐变淡入，其余保持正常清晰
    private var liveRevealText: Text {
        let characters = Array(revealedText)
        guard !characters.isEmpty else { return Text("") }

        let fadeCount = tailSettled ? 0 : 3
        let fadeStart = max(0, characters.count - fadeCount)
        var attributed = AttributedString()
        if fadeStart > 0 {
            var piece = AttributedString(String(characters[0..<fadeStart]))
            piece.foregroundColor = Color.primary
            attributed.append(piece)
        }
        for index in fadeStart..<characters.count {
            let step = Double(index - fadeStart + 1) / Double(max(1, characters.count - fadeStart))
            var piece = AttributedString(String(characters[index]))
            piece.foregroundColor = Color.primary.opacity(0.35 + 0.65 * step)
            attributed.append(piece)
        }
        return Text(attributed)
    }

    // MARK: 逐字吐字

    /// 识别文本变化时同步：识别结果被修正则直接对齐，否则启动逐字吐字
    func syncRevealedText() {
        let target = viewModel.liveDisplayText
        guard !target.isEmpty else {
            revealTask?.cancel()
            revealTask = nil
            revealedText = ""
            tailSettled = true
            return
        }
        guard target.hasPrefix(revealedText) else {
            revealedText = target
            tailSettled = true
            return
        }
        startRevealPumpIfNeeded()
    }

    /// 每 60ms 吐一个字；积压较多时一次多吐几个追上识别速度
    private func startRevealPumpIfNeeded() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            while !Task.isCancelled {
                let target = viewModel.liveDisplayText
                guard target.hasPrefix(revealedText) else {
                    revealedText = target
                    tailSettled = true
                    break
                }
                let backlog = target.count - revealedText.count
                guard backlog > 0 else { break }
                let step = backlog > 12 ? 3 : (backlog > 5 ? 2 : 1)
                let end = target.index(target.startIndex, offsetBy: revealedText.count + step)
                revealedText = String(target[..<end])
                tailSettled = false
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            revealTask = nil
            // 退出瞬间目标又变长时补一次，避免漏字
            if viewModel.liveDisplayText.count > revealedText.count {
                startRevealPumpIfNeeded()
                return
            }
            // 没有新字后稍等片刻，再让末尾字符恢复完全清晰
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, revealTask == nil else { return }
            tailSettled = true
        }
    }

    // MARK: 分段记录

    func segmentList(isLandscape: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.segments) { segment in
                        CaptionSegmentRow(
                            segment: segment,
                            showTranslationFailure: settings.realtimeTranslationEnabled
                                && viewModel.failedTranslationIDs.contains(segment.id),
                            onRetryTranslation: { viewModel.retryTranslation(for: segment) },
                            onPolishRequest: { polish(segment) },
                            onReveal: { viewModel.markSegmentAnimated(segment.id) }
                        )
                        .id(segment.id)
                    }

                    if !viewModel.liveDisplayText.isEmpty || viewModel.state == .listening {
                        liveBubble
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        // 仅上下拖动时固定列表；用户自己滑回底部后自动解除
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        lockAutoScroll(proxy)
                    }
            )
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { _, distanceToBottom in
                guard autoScrollLocked, distanceToBottom < 16 else { return }
                autoScrollUnlockTask?.cancel()
                autoScrollLocked = false
            }
            .onAppear {
                scrollToBottom(proxy, animated: false, force: true)
            }
            // 系统锚点在横屏/文字高频增长时不可靠，改为显式跟随：
            // 实时文字每吐一个字、新字幕落库时都平滑贴底
            .onChange(of: revealedText) { _, _ in
                scrollToBottom(proxy, animated: true, duration: 0.12)
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                scrollToBottom(proxy, animated: true, duration: 0.22)
            }
            .onChange(of: viewModel.state) { _, state in
                if state == .listening {
                    scrollToBottom(proxy, animated: true)
                } else {
                    autoScrollUnlockTask?.cancel()
                    autoScrollLocked = false
                }
            }
            // 直接作用在 ScrollView 上，确保 iOS 26 的 soft 顶部边缘效果生效
            .softTopEdgeEffect()
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    if autoScrollLocked, viewModel.state == .listening {
                        autoScrollLockControl(proxy)
                            .padding(.bottom, isLandscape ? 24 : 120)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: autoScrollLocked)
            }
        }
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        force: Bool = false,
        duration: Double = 0.25
    ) {
        guard force || !autoScrollLocked else { return }
        Task { @MainActor in
            // 等这一轮文字布局完成再滚，否则会滚到增长前的位置
            await Task.yield()
            guard force || !autoScrollLocked else { return }
            if animated {
                withAnimation(.easeInOut(duration: duration)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// 开始或重置回到实时的倒计时；时间为 0 时保持固定，不自动返回
    private func lockAutoScroll(_ proxy: ScrollViewProxy) {
        guard viewModel.state == .listening else { return }
        autoScrollLocked = true
        autoScrollUnlockTask?.cancel()
        let seconds = autoScrollResumeSeconds
        guard seconds >= 1 else { return }
        autoScrollUnlockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            autoScrollLocked = false
            // 倒计时结束平滑滑回最新位置，而不是等下一段文字突然拉过去
            scrollToBottom(proxy, animated: true, force: true, duration: 0.5)
        }
    }

    private func resumeAutoScroll(_ proxy: ScrollViewProxy) {
        autoScrollUnlockTask?.cancel()
        autoScrollLocked = false
        scrollToBottom(proxy, animated: true, force: true)
    }

    /// 右侧悬浮控制：上方波形图标拖动设定自动返回秒数，下方突起箭头一键回到最新
    private func autoScrollLockControl(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            waveTimeHandle(proxy)
            returnToLatestTab(proxy)
        }
    }

    private var lockTimeText: String {
        autoScrollResumeSeconds >= 1 ? "\(Int(autoScrollResumeSeconds)) 秒" : "一直固定"
    }

    /// 波形图标：上下拖动调时间，点按给出触感反馈并弹出当前时间
    private func waveTimeHandle(_ proxy: ScrollViewProxy) -> some View {
        Image(systemName: "waveform")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 44)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 17,
                    bottomLeadingRadius: 17,
                    style: .continuous
                )
                .fill(.ultraThinMaterial)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showLockTimePopupBriefly()
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if lockTimeDragStart == nil {
                            lockTimeDragStart = autoScrollResumeSeconds
                            showLockTimePopupBriefly(hold: true)
                        }
                        let start = lockTimeDragStart ?? 0
                        let seconds = (start - value.translation.height / 3).rounded()
                        let clamped = min(30, max(0, seconds))
                        guard clamped != autoScrollResumeSeconds else { return }
                        autoScrollResumeSeconds = clamped
                        UISelectionFeedbackGenerator().selectionChanged()
                        lockAutoScroll(proxy)
                    }
                    .onEnded { _ in
                        lockTimeDragStart = nil
                        showLockTimePopupBriefly()
                    }
            )
            .overlay(alignment: .leading) {
                if showLockTimePopup {
                    Text(lockTimeText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: Capsule())
                        .fixedSize()
                        .offset(x: -58)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .accessibilityLabel("自动回到实时时间：\(lockTimeText)")
    }

    /// 从右边缘突起的箭头：点击回到最新字幕并解除固定
    private func returnToLatestTab(_ proxy: ScrollViewProxy) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            resumeAutoScroll(proxy)
        } label: {
            Image(systemName: "chevron.left")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 40)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        style: .continuous
                    )
                    .fill(.ultraThinMaterial)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到最新")
    }

    /// 弹出时间气泡并自动收起；拖动期间保持显示
    private func showLockTimePopupBriefly(hold: Bool = false) {
        lockTimePopupTask?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            showLockTimePopup = true
        }
        guard !hold else { return }
        lockTimePopupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showLockTimePopup = false
            }
        }
    }

    /// 长按字幕行触发 AI 润色
    private func polish(_ segment: CaptionSegment) {
        Task {
            guard let polished = await aiService.polish(segment: segment) else { return }
            viewModel.applyPolishedText(polished, to: segment.id)
        }
    }
}
