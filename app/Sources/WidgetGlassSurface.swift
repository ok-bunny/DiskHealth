import AppKit

/// 卡片的材质跟随窗口边界，前景内容独立测量并保持清晰。
final class WidgetGlassSurface: NSView {
    init(frame: NSRect, content: NSView) {
        super.init(frame: frame)
        let radius: CGFloat = 16
        let surface: NSView
        if #available(macOS 26.4, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = radius
            surface = glass
        } else {
            let frost = NSVisualEffectView(frame: bounds)
            frost.material = .popover
            frost.blendingMode = .behindWindow
            frost.state = .active
            let side = 2 * radius + 1
            let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            frost.maskImage = mask
            surface = frost
        }
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)

        // 非激活的面板也要保持数字清晰。玻璃只负责背景，文字独立合成。
        let wash = NSBox(frame: bounds)
        wash.boxType = .custom
        wash.titlePosition = .noTitle
        wash.borderWidth = 0
        wash.cornerRadius = radius
        wash.fillColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? .black.withAlphaComponent(0.36) : .white.withAlphaComponent(0.18)
        }
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }
}
