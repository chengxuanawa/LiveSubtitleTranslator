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
            guard shape != oldValue, isActive else { return }
            render(original: lastContent?.original ?? "SubLingo", translated: lastContent?.translated)
        }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var hostView: UIView?
    private var lastContent: (original: String, translated: String?)?
    /// 相对时间基准，用于给样本缓冲打时间戳
    private let playbackAnchor = CACurrentMediaTime()

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        pipController = controller
    }

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// 进入画中画；返回是否成功发起
    @discardableResult
    func start() -> Bool {
        guard Self.isSupported, let pipController else { return false }
        // 不再把音频会话切到 .playback：那会抢占麦克风，导致录音中开画中画时识别掉线
        attachToWindow()
        displayLayer.flush()
        render(original: lastContent?.original ?? "SubLingo", translated: lastContent?.translated)
        pipController.startPictureInPicture()
        return pipController.isPictureInPicturePossible
    }

    func stop() {
        pipController?.stopPictureInPicture()
        hostView?.removeFromSuperview()
        hostView = nil
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
        displayLayer.enqueue(sampleBuffer)
    }

    private func makeSampleBuffer(from image: CGImage, size: CGSize) -> CMSampleBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
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

    private func attachToWindow() {
        guard hostView == nil else { return }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        window.addSubview(host)
        displayLayer.frame = host.bounds
        host.layer.addSublayer(displayLayer)
        hostView = host
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
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        onStateChange?(false)
    }
}