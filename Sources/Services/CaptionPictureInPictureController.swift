import AVFoundation
import AVKit
import QuartzCore
import UIKit

/// 字幕画中画：把最新字幕渲染成视频帧，通过 AVSampleBufferDisplayLayer + AVPictureInPictureController
/// 送入系统画中画窗口（iPad / iPhone 均支持）。受系统限制，无法“启动即进入画中画”，需用户点击触发。
@MainActor
final class CaptionPictureInPictureController: NSObject, ObservableObject {

    @Published private(set) var isActive = false

    /// 进入/退出画中画时回调
    var onStateChange: ((Bool) -> Void)?

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

    private let displayLayer = AVSampleBufferDisplayLayer()
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

    /// 内容源必须在显示层加入窗口后再创建，否则 iPhone 上可能永远无法进入画中画
    private func ensureController() {
        guard pipController == nil else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
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
    }

    /// 更新画中画内容（仅在画中画激活时渲染）
    func update(original: String, translated: String?) {
        lastContent = (original, translated)
        guard isActive else { return }
        render(original: original, translated: translated)
    }

    // MARK: - 渲染

    private func render(original: String, translated: String?) {
        let size = shape.renderSize
        // 让显示层保持与视频一致的宽高比，系统据此决定画中画窗口比例
        fitDisplayLayer(to: size)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail

            let padding = size.height * 0.065
            let contentRect = CGRect(
                x: padding,
                y: padding,
                width: size.width - padding * 2,
                height: size.height - padding * 2
            )
            let originalHeight = contentRect.height * 0.52
            let gap: CGFloat = 8

            let originalAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.height * 0.085, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            (original as NSString).draw(
                in: CGRect(x: contentRect.minX, y: contentRect.minY, width: contentRect.width, height: originalHeight),
                withAttributes: originalAttributes
            )

            if let translated {
                let translatedAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size.height * 0.068, weight: .regular),
                    .foregroundColor: UIColor.systemYellow,
                    .paragraphStyle: paragraph,
                ]
                (translated as NSString).draw(
                    in: CGRect(
                        x: contentRect.minX,
                        y: contentRect.minY + originalHeight + gap,
                        width: contentRect.width,
                        height: contentRect.height - originalHeight - gap
                    ),
                    withAttributes: translatedAttributes
                )
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

    /// 显示层按视频宽高比在窗口内居中，避免整窗比例覆盖画中画窗口形状
    private func fitDisplayLayer(to videoSize: CGSize) {
        guard let hostView else { return }
        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0,
              videoSize.width > 0, videoSize.height > 0 else { return }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let fitted = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = CGRect(
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
            // 用整窗大小承载显示层并放到最底层，避免 2×2 的宿主视图导致画中画黑屏
            let host = UIView(frame: window.bounds)
            host.isUserInteractionEnabled = false
            host.backgroundColor = .clear
            window.insertSubview(host, at: 0)
            host.layer.addSublayer(displayLayer)
            hostView = host
        }
        // 必须在创建 ContentSource 之前把显示层调成目标画幅，
        // 否则系统会按整窗（竖屏）比例锁定画中画窗口
        fitDisplayLayer(to: shape.renderSize)
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
            self.isActive = false
            self.onStateChange?(false)
            self.teardownController()
        }
    }
}