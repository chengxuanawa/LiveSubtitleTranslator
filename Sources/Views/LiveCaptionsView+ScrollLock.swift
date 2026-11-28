import SwiftUI
import UIKit

extension LiveCaptionsView {
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
    func autoScrollLockControl(_ proxy: ScrollViewProxy) -> some View {
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
}
