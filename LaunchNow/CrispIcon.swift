import AppKit

/// 按屏幕上实际显示的像素重画 App 图标，边缘才锐利。
/// NSWorkspace 给的图标名义尺寸只有 32pt，直接交给 SwiftUI 的 Image(nsImage:).resizable() 拉大时，
/// 它拿小尺寸的那一档位图去放大（实测 94pt 时边缘锐度只有按像素画的 1/20）。
/// 这里在「1 单位 = 1 像素」的位图上调 NSImage.draw(in:)，系统会按目标像素挑最合适的那一档来画
enum CrispIcon {
    private final class Entry {
        /// 画这张图用的原图；App 更新后重新扫描会换成新的图标对象，对不上就重画
        weak var source: NSImage?
        let image: NSImage

        init(source: NSImage, image: NSImage) {
            self.source = source
            self.image = image
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// - Parameters:
    ///   - id: 图标的稳定标识（App 路径），和像素尺寸一起作缓存键
    ///   - side: 显示边长（pt）
    ///   - scale: 屏幕倍率
    static func image(_ source: NSImage, id: String, side: CGFloat, scale: CGFloat) -> NSImage {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, scale > 0, source.size.width > 0, source.size.height > 0 else { return source }
        let key = "\(id)|\(pixels)" as NSString
        if let entry = cache.object(forKey: key), entry.source === source {
            return entry.image
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return source
        }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return source }

        let pointSide = CGFloat(pixels) / scale
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pointSide, height: pointSide))
        cache.setObject(Entry(source: source, image: image), forKey: key, cost: pixels * pixels * 4)
        return image
    }
}
