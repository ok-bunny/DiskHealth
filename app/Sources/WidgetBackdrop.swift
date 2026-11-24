import AppKit
import Combine
import ImageIO

@MainActor
final class WidgetBackdrop: ObservableObject {
    // 只有已知的暗色壁纸才覆盖系统外观。
    @Published private(set) var prefersDark = false
    private let sampler = WallpaperSampler()
    private var pending: Task<Void, Never>?

    func update(for panel: NSPanel) {
        pending?.cancel()
        pending = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let panel, panel.isVisible else { return }
            let workspace = NSWorkspace.shared
            guard let screen = panel.screen, let url = workspace.desktopImageURL(for: screen), url.isFileURL else {
                if prefersDark { prefersDark = false }
                return
            }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            let fill = (options[.fillColor] as? NSColor)?.cgColor
                .converted(to: WallpaperSampler.gray, intent: .defaultIntent, options: nil)?.components?.first
            let luminance = await sampler.luminance(at: url, screen: screen.frame, panel: panel.frame,
                backingScale: screen.backingScaleFactor, scaling: scaling ?? .scaleProportionallyUpOrDown,
                clip: (options[.allowClipping] as? NSNumber)?.boolValue ?? false, fill: fill)
            guard !Task.isCancelled else { return }
            // 在线性亮度临界点附近保留当前样式，避免拖动或卡片高度变化时来回切换。
            let threshold = prefersDark ? 0.22 : 0.16
            let dark = luminance.map { $0 < threshold } ?? false
            if prefersDark != dark { prefersDark = dark }
        }
    }
}

private actor WallpaperSampler {
    static let gray = CGColorSpace(name: CGColorSpace.linearGray)!
    private var cache: (url: URL, modified: Date?, thumbnail: Thumbnail?)?

    func luminance(at url: URL, screen: CGRect, panel: CGRect, backingScale: CGFloat,
                   scaling: NSImageScaling, clip: Bool, fill: CGFloat?) -> CGFloat? {
        let area = panel.intersection(screen)
        var file = url
        file.removeCachedResourceValue(forKey: .contentModificationDateKey)
        guard !Task.isCancelled, !area.isEmpty,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        let modified = values.contentModificationDate
        if cache?.url != url || cache?.modified != modified {
            cache = (url, modified, Thumbnail(url: url))
        }
        guard let thumb = cache?.thumbnail else { return nil }
        let size = thumb.sizeOnScreen(screen.size, backingScale: backingScale, scaling: scaling, clip: clip)
        let rect = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                          width: size.width, height: size.height)

        // 只把面板所在壁纸区域投影到一个很小的线性灰度位图中，两者均以左下角为原点。
        let side = 12
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 2, space: Self.gray,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        if let fill, let color = CGColor(colorSpace: Self.gray, components: [fill, 1]) {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        context.scaleBy(x: CGFloat(side) / area.width, y: CGFloat(side) / area.height)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.draw(thumb.image, in: rect)

        var graySum = 0, alphaSum = 0
        for i in 0..<(side * side) {
            graySum += Int(pixels[2 * i])
            alphaSum += Int(pixels[2 * i + 1])
        }
        // 大部分区域是未知的填充色或透明像素时，回到系统外观。
        guard alphaSum > side * side * 255 / 2 else { return nil }
        return CGFloat(graySum) / CGFloat(alphaSum)
    }

    private struct Thumbnail {
        let image: CGImage
        let pixelSize: CGSize

        init?(url: URL) {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
                  // 动态壁纸可以有多个时段的画面，公开接口没有给出当前帧。
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, width > 0,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, height > 0 else { return nil }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return nil
            }
            image = thumbnail
            let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
            pixelSize = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }

        func sizeOnScreen(_ screen: CGSize, backingScale: CGFloat, scaling: NSImageScaling, clip: Bool) -> CGSize {
            if scaling == .scaleAxesIndependently { return screen }
            let natural = CGSize(width: pixelSize.width / backingScale, height: pixelSize.height / backingScale)
            if scaling == .scaleNone { return natural }
            let x = screen.width / natural.width, y = screen.height / natural.height
            let fit = clip ? max(x, y) : min(x, y)
            let scale = scaling == .scaleProportionallyDown ? min(1, fit) : fit
            return CGSize(width: natural.width * scale, height: natural.height * scale)
        }
    }
}
