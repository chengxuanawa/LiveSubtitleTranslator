import AVFoundation
import AVKit
import QuartzCore
import UIKit

/// 字幕画中画：把最新字幕渲染成视频帧，经 AVSampleBufferDisplayLayer 送入系统画中画窗口。
/// 优先使用视频通话内容源（窗口支持双指缩放），系统拒绝时自动退回样本缓冲内容源。
/// 受系统限制，无法“启动即进入画中画”，需用户点击触发。
@MainActor
final class CaptionPictureInPictureController: NSObject {

    private enum StartStage: Equatable {
        case idle, waitingForAvailability, starting
    }

    private var isActive = false
    private var startStage = StartStage.idle

    var isRequested: Bool {
        isActive || startStage != .idle || shapeRestartTask != nil
    }

    /// 进入/退出画中画时回调
    var onStateChange: ((Bool) -> Void)?

    /// 原文字号 / 译文字号缩放倍率（由设置注入，建议范围 0.6–1.6）
    var fontScaleProvider: (@MainActor () -> (original: CGFloat, translated: CGFloat))?

    /// 画中画窗口形状（默认 / 长条）
    var shape: PiPShape = .standard {
        didSet {
            guard shape != oldValue else { return }
            let shouldRestart = isRequested
            stop()
            guard shouldRestart else { return }
            shapeRestartTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                self.shapeRestartTask = nil
                _ = self.start()
            }
        }
    }

    private let displayView = PiPDisplayView()
    private var displayLayer: AVSampleBufferDisplayLayer { displayView.displayLayer }
    /// 视频通话内容控制器：系统按它呈现的窗口支持双指缩放（iPad）
    private var videoCallViewController: AVPictureInPictureVideoCallViewController?
    /// 优先用视频通话内容源以获得可缩放的画中画窗口；系统拒绝时退回样本缓冲内容源
    private var prefersVideoCallSource = true
    private var pipController: AVPictureInPictureController?
    private var hostView: UIView?
    private var lastContent: (original: String, translated: String?)?
    /// 相对时间基准，用于给样本缓冲打时间戳
    private let playbackAnchor = CACurrentMediaTime()
    private var startTimeoutTask: Task<Void, Never>?
    private var shapeRestartTask: Task<Void, Never>?
    private var possibleObservation: NSKeyValueObservation?

    override init() {
        super.init()
        displayView.backgroundColor = .clear
        displayLayer.videoGravity = .resizeAspect
        // 样本缓冲显示层需要时间基准才能按时渲染，否则画中画里会是黑屏
        var timebase: CMTimebase?
        _ = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let timebase {
            displayLayer.controlTimebase = timebase
            _ = CMTimebaseSetTime(timebase, time: .zero)
            _ = CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    /// 内容源必须在宿主视图加入窗口后再创建，否则 iPhone 上可能永远无法进入画中画
    private func ensureController() {
        guard pipController == nil, let hostView else { return }
        let source: AVPictureInPictureController.ContentSource
        if prefersVideoCallSource {
            let contentViewController = PiPCaptionVideoCallViewController()
            // 内容尺寸决定画中画窗口的宽高比
            contentViewController.preferredContentSize = shape.renderSize
            contentViewController.view.backgroundColor = .clear
            // 先给内容视图一个有效尺寸，保证首帧样本缓冲有可渲染区域
            contentViewController.view.frame = CGRect(origin: .zero, size: shape.renderSize)
            displayView.removeFromSuperview()
            displayView.autoresizingMask = []
            displayView.frame = contentViewController.view.bounds
            contentViewController.view.addSubview(displayView)
            contentViewController.onLayout = { [weak self, weak contentViewController] in
                guard let self, let contentViewController else { return }
                self.displayView.frame = contentViewController.view.bounds
            }
            videoCallViewController = contentViewController
            source = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: hostView,
                contentViewController: contentViewController
            )
        } else {
            displayView.removeFromSuperview()
            displayView.frame = hostView.bounds
            hostView.addSubview(displayView)
            source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
        }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        if !prefersVideoCallSource {
            controller.requiresLinearPlayback = true
        }
        pipController = controller

        // iPhone 上画中画允许启动的时机由系统异步决定，不能刚创建就强行启动
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self, weak controller] _, _ in
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller, controller.isPictureInPicturePossible else { return }
                self.startWhenAvailable(controller)
            }
        }
    }

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// 进入画中画；返回是否成功发起
    @discardableResult
    func start() -> Bool {
        guard Self.isSupported else { return false }
        // 系统要求画中画在前台发起；后台调用可能被拒绝甚至触发系统异常
        guard UIApplication.shared.applicationState == .active else { return false }
        if isRequested || pipController?.isPictureInPictureActive == true { return true }
        // 不再把音频会话切到 .playback：那会抢占麦克风，导致录音中开画中画时识别掉线
        attachToWindow()
        ensureController()
        guard let pipController else { return false }
        displayLayer.flush()
        render(original: lastContent?.original ?? "SubLingo", translated: lastContent?.translated)

        startStage = .waitingForAvailability
        if pipController.isPictureInPicturePossible {
            startWhenAvailable(pipController)
        } else {
            startTimeoutTask = Task { [weak self, weak pipController] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, let pipController, !Task.isCancelled else { return }
                self.startWhenAvailable(pipController)
            }
        }
        return true
    }

    private func startWhenAvailable(_ controller: AVPictureInPictureController) {
        guard pipController === controller, startStage == .waitingForAvailability else { return }
        cancelStartTimeout()
        startStage = .starting
        controller.startPictureInPicture()
    }

    private func cancelStartTimeout() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
    }

    func stop() {
        finishStop(requestSystemStop: true)
    }

    private func finishStop(requestSystemStop: Bool) {
        shapeRestartTask?.cancel()
        shapeRestartTask = nil
        pipController?.delegate = nil
        if requestSystemStop {
            pipController?.stopPictureInPicture()
        }
        teardownController()
        // 下次手动开启时优先使用可缩放的内容源。
        prefersVideoCallSource = true
        hostView?.removeFromSuperview()
        hostView = nil
        setActive(false)
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onStateChange?(active)
    }

    private func teardownController() {
        cancelStartTimeout()
        startStage = .idle
        possibleObservation?.invalidate()
        possibleObservation = nil
        pipController?.delegate = nil
        pipController = nil
        displayView.removeFromSuperview()
        videoCallViewController = nil
    }

    /// 更新画中画内容（仅在画中画激活时渲染）
    func update(original: String, translated: String?) {
        lastContent = (original, translated)
        guard isActive else { return }
        render(original: original, translated: translated)
    }

    /// 设置变化后按当前内容立即重绘（如字号调节）
    func refresh() {
        guard isActive else { return }
        render(original: lastContent?.original ?? "", translated: lastContent?.translated)
    }

    // MARK: - 渲染

    private func render(original: String, translated: String?) {
        updateDisplayLayout(for: shape.renderSize)
        let scales = fontScaleProvider?() ?? (original: 1, translated: 1)
        guard let sampleBuffer = PiPCaptionRenderer.frame(
            original: original,
            translated: translated,
            shape: shape,
            scales: scales,
            elapsed: CACurrentMediaTime() - playbackAnchor
        ) else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        // 实时字幕不需要等待时间戳，立即显示最新一帧
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        displayLayer.enqueue(sampleBuffer)
    }

    /// 视频通话内容源由系统铺满窗口；样本缓冲内容源需要按视频宽高比在宿主视图内居中
    private func updateDisplayLayout(for videoSize: CGSize) {
        if prefersVideoCallSource {
            if let contentView = videoCallViewController?.view,
               contentView.bounds.width > 0, contentView.bounds.height > 0 {
                displayView.frame = contentView.bounds
            }
            return
        }
        guard let hostView else { return }
        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0,
              videoSize.width > 0, videoSize.height > 0 else { return }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let fitted = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayView.frame = CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        CATransaction.commit()
    }

    private func attachToWindow() {
        if hostView == nil {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
            guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
            // 用整窗大小的透明宿主作为画中画动画的起始/恢复位置
            let host = UIView(frame: window.bounds)
            host.isUserInteractionEnabled = false
            host.backgroundColor = .clear
            window.insertSubview(host, at: 0)
            hostView = host
        }
    }
}

/// 画中画内容视图：图层直接使用 AVSampleBufferDisplayLayer
private final class PiPDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

/// 视频通话式画中画的内容控制器：布局变化时把显示层铺满，窗口缩放后内容跟着适配
private final class PiPCaptionVideoCallViewController: AVPictureInPictureVideoCallViewController {
    var onLayout: (@MainActor () -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension CaptionPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // 返回有限时长而不是 positiveInfinity，避免系统在画中画窗口标注「直播」
        CMTimeRange(start: .zero, duration: CMTime(seconds: 86_400, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {}
}

// MARK: - AVPictureInPictureControllerDelegate

extension CaptionPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard pipController === controller else { return }
        startStage = .idle
        setActive(true)
        refresh()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard pipController === controller else { return }
        finishStop(requestSystemStop: false)
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller, self.pipController === controller else { return }
            if self.prefersVideoCallSource {
                self.prefersVideoCallSource = false
                self.teardownController()
                if !self.start() { self.finishStop(requestSystemStop: false) }
            } else {
                self.stop()
            }
        }
    }
}
