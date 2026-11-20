import AVFoundation
import AVKit
import QuartzCore
import UIKit

/// 字幕画中画：把最新字幕渲染成视频帧，经 AVSampleBufferDisplayLayer 送入系统画中画窗口。
/// 优先使用视频通话内容源（窗口支持双指缩放），系统拒绝时自动退回样本缓冲内容源。
/// 受系统限制，无法“启动即进入画中画”，需用户点击触发。
@MainActor
final class CaptionPictureInPictureController: NSObject, ObservableObject {

    @Published private(set) var isActive = false

    /// 进入/退出画中画时回调
    var onStateChange: ((Bool) -> Void)?

    /// 原文字号 / 译文字号缩放倍率（由设置注入，建议范围 0.6–1.6）
    var fontScaleProvider: (@MainActor () -> (original: CGFloat, translated: CGFloat))?

    /// 画中画窗口形状（默认 / 长条）
    var shape: PiPShape = .standard {
        didSet {
            guard shape != oldValue else { return }
            guard isActive else {
                // 窗口比例与内容源绑定，销毁会话让下次开启按新形状创建
                teardownController()
                return
            }
            // 运行中切换形状：退出后按新画幅自动重新开启，免去手动操作
            let content = lastContent
            stop()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !self.isActive else { return }
                _ = self.start()
                if let content {
                    self.update(original: content.original, translated: content.translated)
                }
            }
        }
    }

    private let displayView = PiPDisplayView()
    private var displayLayer: AVSampleBufferDisplayLayer { displayView.displayLayer }
    /// 视频通话内容控制器：系统按它呈现的窗口支持双指缩放（iPad）
    private var videoCallViewController: AVPictureInPictureVideoCallViewController?
    /// 优先用视频通话内容源以获得可缩放的画中画窗口；系统拒绝时退回样本缓冲内容源
    private var prefersVideoCallSource = true
    private var contentSource: AVPictureInPictureController.ContentSource?
    private var pipController: AVPictureInPictureController?
    private var hostView: UIView?
    private var lastContent: (original: String, translated: String?)?
    /// 相对时间基准，用于给样本缓冲打时间戳
    private let playbackAnchor = CACurrentMediaTime()
    /// 等待系统允许画中画后再启动
    private var pendingStart = false
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
        contentSource = source
        pipController = controller

        // iPhone 上画中画允许启动的时机由系统异步决定，不能刚创建就强行启动
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self, weak controller] _, _ in
            Task { @MainActor [weak self, weak controller] in
                guard let self,
                      let controller,
                      self.pendingStart,
                      controller.isPictureInPicturePossible else { return }
                self.pendingStart = false
                controller.startPictureInPicture()
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
        // 已在等待系统允许或已经激活时，不重复发起
        if pendingStart || pipController?.isPictureInPictureActive == true { return true }
        // 不再把音频会话切到 .playback：那会抢占麦克风，导致录音中开画中画时识别掉线
        attachToWindow()
        ensureController()
        guard let pipController else { return false }
        displayLayer.flush()
        render(original: lastContent?.original ?? "SubLingo", translated: lastContent?.translated)

        pendingStart = false
        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            pendingStart = true
            // 兜底：等系统状态回调用了一小段时间仍不可用，再尝试一次
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.pendingStart else { return }
                self.pendingStart = false
                self.pipController?.startPictureInPicture()
            }
        }
        return true
    }

    func stop() {
        pendingStart = false
        pipController?.stopPictureInPicture()
        teardownController()
        // 下次开启重新尝试视频通话内容源（可缩放的画中画窗口）
        prefersVideoCallSource = true
        hostView?.removeFromSuperview()
        hostView = nil
        if isActive {
            isActive = false
            onStateChange?(false)
        }
    }

    /// 销毁画中画会话：窗口比例与内容源绑定，重建后才能按新形状生效
    private func teardownController() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        pipController?.delegate = nil
        pipController = nil
        contentSource = nil
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
        let size = shape.renderSize
        // 设置中的字号倍率；夹在 0.6–1.6，避免异常值撑破画布
        let scales = fontScaleProvider?() ?? (original: 1, translated: 1)
        let originalScale = min(1.6, max(0.6, scales.original))
        let translatedScale = min(1.6, max(0.6, scales.translated))
        // 让显示层保持与视频一致的宽高比，系统据此决定画中画窗口比例
        updateDisplayLayout(for: size)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            Self.drawBackground(in: context.cgContext, size: size)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            // 允许按宽度换行，先测量完整高度，再按形状限定的行数裁剪
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 1

            // 画中画窗口有圆角，左右留足内边距，避免文字被圆角切掉
            let horizontalPadding = min(size.height * 0.18, size.width * 0.06)
            let verticalPadding = size.height * 0.10
            let contentRect = CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: size.width - horizontalPadding * 2,
                height: size.height - verticalPadding * 2
            )
            let gap: CGFloat = size.height * 0.04

            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = max(2, size.height * 0.008)
            shadow.shadowOffset = CGSize(width: 0, height: max(1, size.height * 0.003))

            let originalFont = UIFont.systemFont(
                ofSize: size.height * shape.originalFontRatio * originalScale,
                weight: .semibold
            )
            let originalAttributes: [NSAttributedString.Key: Any] = [
                .font: originalFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: shadow,
            ]
            let originalFullBound = (original as NSString).boundingRect(
                with: CGSize(width: contentRect.width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: originalAttributes,
                context: nil
            ).integral
            let originalMaxHeight = Self.maxTextHeight(
                font: originalFont,
                lines: shape.originalMaxLines,
                lineSpacing: paragraph.lineSpacing
            )
            let originalDisplayHeight = min(originalFullBound.height, originalMaxHeight)
            // 超过限定行数时改为显示最后几行（最新内容）
            let originalOverflow = max(0, originalFullBound.height - originalDisplayHeight)

            var translatedAttributes: [NSAttributedString.Key: Any] = [:]
            var translatedFullBound = CGRect.zero
            var translatedDisplayHeight: CGFloat = 0
            var translatedOverflow: CGFloat = 0
            if let translated {
                let translatedFont = UIFont.systemFont(
                    ofSize: size.height * shape.translatedFontRatio * translatedScale,
                    weight: .medium
                )
                translatedAttributes = [
                    .font: translatedFont,
                    // 译文用略带透明度的白色，和原文形成层级但不抢眼
                    .foregroundColor: UIColor.white.withAlphaComponent(0.88),
                    .paragraphStyle: paragraph,
                    .shadow: shadow,
                ]
                translatedFullBound = (translated as NSString).boundingRect(
                    with: CGSize(width: contentRect.width, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: translatedAttributes,
                    context: nil
                ).integral
                // 译文最多显示固定行数，且不能挤占原文之外的剩余空间
                let translatedMaxHeight = Self.maxTextHeight(
                    font: translatedFont,
                    lines: shape.translatedMaxLines,
                    lineSpacing: paragraph.lineSpacing
                )
                let available = max(0, contentRect.height - originalDisplayHeight - gap)
                translatedDisplayHeight = min(translatedFullBound.height, min(translatedMaxHeight, available))
                translatedOverflow = max(0, translatedFullBound.height - translatedDisplayHeight)
            }

            let totalHeight = originalDisplayHeight
                + (translatedDisplayHeight > 0 ? gap + translatedDisplayHeight : 0)
            let startY = contentRect.minY + max(0, (contentRect.height - totalHeight) / 2)

            // 裁剪到可见行数，文字超出时向上滚动显示最新一行
            context.cgContext.saveGState()
            context.cgContext.clip(to: CGRect(
                x: contentRect.minX,
                y: startY,
                width: contentRect.width,
                height: originalDisplayHeight
            ))
            (original as NSString).draw(
                in: CGRect(
                    x: contentRect.minX,
                    y: startY - originalOverflow,
                    width: contentRect.width,
                    height: originalFullBound.height
                ),
                withAttributes: originalAttributes
            )
            context.cgContext.restoreGState()

            if let translated, translatedDisplayHeight > 0 {
                let translatedTop = startY + originalDisplayHeight + gap
                context.cgContext.saveGState()
                context.cgContext.clip(to: CGRect(
                    x: contentRect.minX,
                    y: translatedTop,
                    width: contentRect.width,
                    height: translatedDisplayHeight
                ))
                (translated as NSString).draw(
                    in: CGRect(
                        x: contentRect.minX,
                        y: translatedTop - translatedOverflow,
                        width: contentRect.width,
                        height: translatedFullBound.height
                    ),
                    withAttributes: translatedAttributes
                )
                context.cgContext.restoreGState()
            }
        }
        guard let cgImage = image.cgImage,
              let sampleBuffer = makeSampleBuffer(from: cgImage, size: size) else { return }
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

    /// 限定行数下文字的最大高度（含行距，留 2pt 余量避免裁到降部）
    private static func maxTextHeight(font: UIFont, lines: Int, lineSpacing: CGFloat) -> CGFloat {
        let lineCount = CGFloat(max(1, lines))
        return ceil(font.lineHeight) * lineCount
            + lineSpacing * CGFloat(max(0, lines - 1))
            + 2
    }

    // MARK: - 配色

    /// 参考系统实时字幕的蓝色玻璃底：亮蓝到深蓝渐变 + 顶部高光
    private static func drawBackground(in context: CGContext, size: CGSize) {
        let space = CGColorSpaceCreateDeviceRGB()
        let baseColors = [
            UIColor(red: 0.22, green: 0.47, blue: 1.00, alpha: 1).cgColor,
            UIColor(red: 0.05, green: 0.20, blue: 0.68, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: baseColors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
        let highlightColors = [
            UIColor.white.withAlphaComponent(0.16).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray
        if let highlight = CGGradient(colorsSpace: space, colors: highlightColors, locations: [0, 1]) {
            context.drawLinearGradient(
                highlight,
                start: .zero,
                end: CGPoint(x: 0, y: size.height * 0.55),
                options: []
            )
        }
    }

    private func makeSampleBuffer(from image: CGImage, size: CGSize) -> CMSampleBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            // AVSampleBufferDisplayLayer 需要 IOSurface 支撑，否则画中画可能黑屏
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // CGContext 的位图内存首行就是画面顶部，直接绘制即为正常方向，
        // 不要再做翻转，否则画中画里文字会镜像
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime() - playbackAnchor, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
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
        isActive = true
        // 内容控制器此时已完成布局，按实际窗口尺寸铺满显示层
        updateDisplayLayout(for: shape.renderSize)
        onStateChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        onStateChange?(false)
        // 用户关闭窗口后销毁会话，下次开启按当前形状重建
        teardownController()
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 视频通话内容源被系统拒绝时退回样本缓冲内容源，保证画中画仍能使用
            if self.prefersVideoCallSource {
                self.prefersVideoCallSource = false
                self.isActive = false
                self.onStateChange?(false)
                self.teardownController()
                if self.start(), let content = self.lastContent {
                    self.update(original: content.original, translated: content.translated)
                }
                return
            }
            self.isActive = false
            self.onStateChange?(false)
            self.teardownController()
        }
    }
}