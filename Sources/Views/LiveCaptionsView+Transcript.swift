import SwiftUI
import UIKit

// MARK: - 实时字幕气泡、逐字吐字与分段列表

extension LiveCaptionsView {

    // MARK: 实时字幕气泡（追加在列表底部）

    /// 正在识别中的字幕气泡（列表中使用，按当前说话人左右分边）
    private var liveBubble: some View {
        HStack(spacing: 0) {
            if liveSpeakerLabel != nil, liveBubbleIsRightAligned {
                Spacer(minLength: 64)
            }
            liveBubbleCore
                .frame(maxWidth: liveSpeakerLabel == nil ? .infinity : 560)
            if liveSpeakerLabel != nil, !liveBubbleIsRightAligned {
                Spacer(minLength: 64)
            }
        }
        .padding(.horizontal, 12)
    }

    private var liveSpeakerLabel: String? {
        settings.speakerDiarizationExperiment ? speakerDiarization.currentSpeakerLabel : nil
    }

    private var liveBubbleIsRightAligned: Bool {
        SpeakerPalette.isRightAligned(label: liveSpeakerLabel)
    }

    private var liveBubbleTint: Color {
        guard liveSpeakerLabel != nil else { return .clear }
        return SpeakerPalette.tint(for: liveSpeakerLabel).opacity(0.16)
    }

    /// 正在识别中的字幕气泡本体：逐字显示，末尾字符渐显
    private var liveBubbleCore: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.speakerDiarizationExperiment,
               let speaker = speakerDiarization.currentSpeakerLabel {
                SpeakerChip(label: speaker, icon: "person.wave.2.fill")
            }

            if revealedText.isEmpty {
                if viewModel.liveDisplayText.isEmpty {
                    Text(viewModel.livePlaceholderText)
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

            if settings.realtimeTranslationEnabled,
               !viewModel.isRecognitionPaused,
               viewModel.state == .listening {
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(liveBubbleTint)
        )
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
                // 积压越多一次吐得越多，避免长句逐字动画追不上识别速度
                let step = backlog > 24 ? 6 : (backlog > 12 ? 4 : (backlog > 5 ? 2 : 1))
                let end = target.index(target.startIndex, offsetBy: revealedText.count + step)
                revealedText = String(target[..<end])
                tailSettled = false
                try? await Task.sleep(nanoseconds: 35_000_000)
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
                            onReveal: { viewModel.markSegmentAnimated(segment.id) },
                            onWordTap: { word, sentence in
                                wordLookupRequest = WordLookupRequest(word: word, sentence: sentence)
                            },
                            speakerLabel: settings.speakerDiarizationExperiment
                                ? speakerDiarization.label(for: segment.startTime)
                                : nil
                        )
                        .id(segment.id)
                        // 只做淡入：卡片位置由列表展开和滚动弹簧带动，
                        // 不再从上一张卡片底部缩放“弹出来”
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: .opacity
                            )
                        )
                    }

                    if !viewModel.liveDisplayText.isEmpty
                        || viewModel.state == .listening
                        || (viewModel.audioSourceMode == .systemAudio && viewModel.isWaitingForBroadcast) {
                        liveBubble
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
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
                // 逐字增长时用柔和短弹簧，避免频繁重定向造成生硬跳动
                scrollToBottom(
                    proxy,
                    animated: true,
                    animation: .spring(response: 0.34, dampingFraction: 0.9)
                )
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                // 新卡片插入时给一点回弹，视觉上更自然
                scrollToBottom(
                    proxy,
                    animated: true,
                    animation: .spring(response: 0.48, dampingFraction: 0.84)
                )
            }
            .onChange(of: viewModel.state) { _, state in
                if state == .listening {
                    scrollToBottom(
                        proxy,
                        animated: true,
                        animation: .spring(response: 0.42, dampingFraction: 0.86)
                    )
                } else {
                    autoScrollUnlockTask?.cancel()
                    autoScrollLocked = false
                }
            }
            // 直接作用在 ScrollView 上，确保 iOS 26 的 soft 顶部边缘效果生效
            .softTopEdgeEffect()
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    if viewModel.state == .listening {
                        autoScrollLockControl(proxy)
                            .padding(.bottom, isLandscape ? 96 : 120)
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
        animation: Animation = .spring(response: 0.42, dampingFraction: 0.86)
    ) {
        guard force || !autoScrollLocked else { return }
        Task { @MainActor in
            // 等这一轮文字布局完成再滚，否则会滚到增长前的位置
            await Task.yield()
            guard force || !autoScrollLocked else { return }
            if animated {
                withAnimation(animation) {
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
            scrollToBottom(
                proxy,
                animated: true,
                force: true,
                animation: .spring(response: 0.55, dampingFraction: 0.82)
            )
        }
    }

    private func resumeAutoScroll(_ proxy: ScrollViewProxy) {
        autoScrollUnlockTask?.cancel()
        autoScrollLocked = false
        scrollToBottom(proxy, animated: true, force: true)
    }

    /// 右侧悬浮控制：条纹定时手柄（常驻）+ 固定时的“回到最新”小舌
    private func autoScrollLockControl(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            stripeTimeHandle(proxy)
            if autoScrollLocked {
                returnToLatestTab(proxy)
            }
        }
    }

    private var lockTimeText: String {
        autoScrollResumeSeconds >= 1 ? "\(Int(autoScrollResumeSeconds)) 秒" : "一直固定"
    }

    /// 条纹宽度（两端短、中间长），参考系统刻度的样子
    private static let stripeWidths: [CGFloat] = [5, 6, 8, 11, 15, 22, 15, 11, 8, 6, 5]

    private var stripeColor: Color {
        autoScrollLocked ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.3)
    }

    private var stripeStrongColor: Color {
        autoScrollLocked ? Color.accentColor : Color.primary.opacity(0.8)
    }

    /// 刻度条纹手柄：按住放大并在旁边显示时间，上下拖动定时，单点一直固定
    private func stripeTimeHandle(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(Self.stripeWidths.enumerated()), id: \.offset) { index, width in
                Capsule()
                    .fill(index == Self.stripeWidths.count / 2 ? stripeStrongColor : stripeColor)
                    .frame(width: width, height: 2)
            }
        }
        .frame(width: 26, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .frame(width: 34)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 17,
                bottomLeadingRadius: 17,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
        }
        .contentShape(Rectangle())
        .scaleEffect(isLockTimeExpanded ? 1.28 : 1, anchor: .trailing)
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isLockTimeExpanded)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if lockTimeDragStart == nil {
                        lockTimeDragStart = autoScrollResumeSeconds
                        lockTimePressStartedAt = Date()
                        withAnimation { isLockTimeExpanded = true }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        revealLockTimePopup()
                    }
                    // 轻微抖动不算调时间，避免单点被误判成拖动
                    guard abs(value.translation.height) > 3 else { return }
                    let start = lockTimeDragStart ?? 0
                    let seconds = (start - value.translation.height / 3).rounded()
                    let clamped = min(30, max(0, seconds))
                    guard clamped != autoScrollResumeSeconds else { return }
                    autoScrollResumeSeconds = clamped
                    UISelectionFeedbackGenerator().selectionChanged()
                    lockAutoScroll(proxy)
                    revealLockTimePopup()
                }
                .onEnded { value in
                    let heldFor = lockTimePressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    let isTap = heldFor < 0.3 && abs(value.translation.height) < 5
                    lockTimeDragStart = nil
                    lockTimePressStartedAt = nil
                    withAnimation { isLockTimeExpanded = false }
                    if isTap {
                        // 单点：直接一直固定，仅变色，不浮出时间窗
                        autoScrollResumeSeconds = 0
                        lockAutoScroll(proxy)
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        hideLockTimePopup()
                    } else if autoScrollResumeSeconds < 1 {
                        hideLockTimePopup()
                    }
                    // 定时值会在锁定期间持续显示在左侧小窗里
                }
        )
        .overlay(alignment: .leading) {
            if showLockTimePopup || (autoScrollLocked && autoScrollResumeSeconds >= 1) {
                Text(lockTimeText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(autoScrollLocked ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize()
                    .offset(x: -62)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
            }
        }
        .onChange(of: autoScrollLocked) { _, locked in
            if !locked {
                hideLockTimePopup()
            }
        }
        .accessibilityLabel("字幕自动滚动定时：\(lockTimeText)，单点一直固定，按住上下拖动调时间")
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

    /// 显示时间气泡：按住期间实时反馈；定时值在锁定期间持续显示
    private func revealLockTimePopup() {
        withAnimation(.snappy(duration: 0.18)) {
            showLockTimePopup = true
        }
    }

    /// 立即收起时间气泡（单点一直固定时不需要时间窗）
    private func hideLockTimePopup() {
        guard showLockTimePopup else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            showLockTimePopup = false
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
