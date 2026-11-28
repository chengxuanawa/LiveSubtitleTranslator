import CoreMedia
import CoreVideo
import UIKit

/// 把当前字幕绘制为画中画显示层可用的样本缓冲。
@MainActor
enum PiPCaptionRenderer {
    static func frame(
        original: String,
        translated: String?,
        shape: PiPShape,
        scales: (original: CGFloat, translated: CGFloat),
        elapsed: CFTimeInterval
    ) -> CMSampleBuffer? {
        let size = shape.renderSize
        // 设置中的字号倍率；夹在 0.6–1.6，避免异常值撑破画布
        let originalScale = min(1.6, max(0.6, scales.original))
        let translatedScale = min(1.6, max(0.6, scales.translated))
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
        guard let cgImage = image.cgImage else { return nil }
        return makeSampleBuffer(from: cgImage, size: size, elapsed: elapsed)
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

    private static func makeSampleBuffer(from image: CGImage, size: CGSize, elapsed: CFTimeInterval) -> CMSampleBuffer? {
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
            presentationTimeStamp: CMTime(seconds: elapsed, preferredTimescale: 600),
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
}
