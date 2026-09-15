import AppKit

/// Picks a ghost-text colour that is actually legible on whatever is behind it.
///
/// Without this the overlay falls back to the app's own text colour at 42%
/// alpha, which disappears entirely on a dark background — the suggestion is
/// drawn but invisible.
enum BackdropSampler {
    struct Backdrop: Sendable {
        /// 0 = black, 1 = white.
        let luminance: Double

        var isDark: Bool { luminance < 0.45 }

        /// Grey with enough contrast to read, but clearly subordinate to the
        /// user's own text.
        var ghostColor: NSColor {
            isDark
                ? NSColor(white: 1.0, alpha: 0.55)
                : NSColor(white: 0.0, alpha: 0.42)
        }
    }

    /// Averages the frame, ignoring fully transparent pixels.
    static func sample(_ frame: CapturedFrame) -> Backdrop? {
        let image = frame.image
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        // Downsample hard: a handful of pixels is plenty for an average, and it
        // keeps this cheap enough to run on a timer.
        let targetWidth = min(width, 24)
        let targetHeight = min(height, 8)

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        var total = 0.0
        var counted = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.1 else { continue }
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            // Rec. 709 luma: matches perceived brightness better than a mean.
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            counted += 1
        }
        guard counted > 0 else { return nil }
        return Backdrop(luminance: total / Double(counted))
    }
}
