// gen_icon.swift — 渲染 DiskHealth.app 图标（macOS squircle 风格）
// 用法: gen_icon <输出目录>  生成完整 iconset（16~1024）
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 1024 基准坐标空间
let CANVAS: CGFloat = 1024
let SHAPE: CGFloat = 824          // squircle 边长（macOS 图标网格占比）
let RADIUS: CGFloat = 185.5       // squircle 圆角

func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let k = s / CANVAS
    ctx.scaleBy(x: k, y: k)
    // Quartz 坐标 y 向上，先翻转以便按"视觉上下"思考
    ctx.translateBy(x: 0, y: CANVAS)
    ctx.scaleBy(x: 1, y: -1)

    let inset = (CANVAS - SHAPE) / 2
    let shape = CGRect(x: inset, y: inset, width: SHAPE, height: SHAPE)

    // 1. 背景 squircle：蓝 → 青绿 对角渐变
    let bgPath = CGPath(roundedRect: shape, cornerWidth: RADIUS, cornerHeight: RADIUS, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [cg(0x2C5F9E), cg(0x12857F)] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CANVAS, y: CANVAS), options: [])
    }
    // 顶部微光（现代 macOS 质感）
    if let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [cg(0xFFFFFF, 0.16), cg(0xFFFFFF, 0.0)] as CFArray,
                              locations: [0, 0.55]) {
        ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CANVAS * 0.6), options: [])
    }
    ctx.restoreGState()

    // 2. 白色 SSD 卡片（居中，带柔和投影）
    let cardW: CGFloat = 560, cardH: CGFloat = 380
    let card = CGRect(x: (CANVAS - cardW) / 2, y: (CANVAS - cardH) / 2 - 14, width: cardW, height: cardH)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 52, cornerHeight: 52, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 42, color: cg(0x08283C, 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(cg(0xF7FAFC))
    ctx.fillPath()
    ctx.restoreGState()
    // 卡片边缘细描
    ctx.addPath(cardPath)
    ctx.setStrokeColor(cg(0xD7E2EA, 0.8))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // 3. 绿色心电脉冲线（健康监控）
    let cy = card.midY + 10
    let x0 = card.minX + 64
    let pts: [(CGFloat, CGFloat)] = [   // (x 偏移, y 偏移；y 向下为正)
        (0, 0), (86, 0), (106, -26), (126, 0), (160, 0),       // 平坦段
        (186, 52), (216, -132), (246, 84), (272, 0),           // 大脉冲
        (330, 0), (352, -38), (376, 0), (432, 0)               // 收尾小波
    ]
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: x0, y: cy))
    for (dx, dy) in pts { pulse.addLine(to: CGPoint(x: x0 + dx, y: cy + dy)) }
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    ctx.addPath(pulse)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(30)
    ctx.setStrokeColor(cg(0x10B981))
    ctx.strokePath()
    // 脉冲线下方微弱绿光晕
    ctx.setShadow(offset: .zero, blur: 18, color: cg(0x10B981, 0.55))
    ctx.addPath(pulse)
    ctx.setLineWidth(26)
    ctx.setStrokeColor(cg(0x10B981))
    ctx.strokePath()
    ctx.restoreGState()

    // 4. 状态指示灯（卡片右上角小绿点）
    let dotR: CGFloat = 26
    let dot = CGRect(x: card.maxX - 74 - dotR, y: card.minY + 62 - dotR,
                     width: dotR * 2, height: dotR * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: cg(0x10B981, 0.8))
    ctx.addEllipse(in: dot)
    ctx.setFillColor(cg(0x34D399))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("创建 PNG 失败: \(url)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// iconutil 要求的标准 iconset 尺寸（px 为实际像素）
let spec: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in spec {
    guard let img = render(size: px) else { fatalError("渲染失败 \(name)") }
    writePNG(img, to: outDir.appendingPathComponent(name))
}
// 预览图
if let img = render(size: 512) { writePNG(img, to: outDir.appendingPathComponent("preview.png")) }
print("iconset 已生成: \(outDir.path)")
