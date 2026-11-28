import SwiftUI
import UIKit

// MARK: - 实时字幕气泡、逐字吐字与分段列表

extension LiveCaptionsView {

    /// 实时字幕沿用完整宽度，说话人标签在气泡内分边显示
    private var liveBubble: some View {
        let speakerLabel = settings.speakerDiarizationExperiment ? speakerDiarization.currentSpeakerLabel : nil
        return VStack(alignment: .leading, spacing: 6) {
            if let speakerLabel {
                SpeakerChip(label: speakerLabel, icon: "person.wave.2.fill")
            }

            if !revealedText.isEmpty {
                liveRevealText
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.liveDisplayText.isEmpty {
                Text(viewModel.livePlaceholderText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .captionBubbleBackground(speakerLabel: speakerLabel)
        .padding(.horizontal, 12)
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

    func scrollToBottom(
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
    private func polish(_ segment: CaptionSegment) {
        Task {
            guard let polished = await aiService.polish(segment: segment) else { return }
            viewModel.applyPolishedText(polished, to: segment.id)
        }
    }
}
