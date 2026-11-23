import CoreGraphics
import Foundation
import ImageIO

/// Рисует иконку приложения в каждом нужном размере отдельно:
/// уменьшение из одного большого PNG размывает куб на 16–32 px.
enum IconRenderer {
    static let variants: [(name: String, size: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    static func gradient(_ ctx: CGContext, _ colors: [CGColor],
                         from: CGPoint, to: CGPoint) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: space, colors: colors as CFArray,
                           locations: nil)!
        ctx.drawLinearGradient(g, start: from, end: to, options: [])
    }

    /// Радиальная тень: у эллипса с резкой кромкой видны края, поэтому гасим альфу к границе.
    static func softShadow(_ ctx: CGContext, center: CGPoint,
                           width: CGFloat, height: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: space,
                           colors: [rgb(0x1A0B3A, 0.42),
                                    rgb(0x1A0B3A, 0.16),
                                    rgb(0x1A0B3A, 0)] as CFArray,
                           locations: [0, 0.55, 1])!
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: height / width)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: width / 2, options: [])
        ctx.restoreGState()
    }

    static func polygon(_ ctx: CGContext, _ points: [CGPoint]) {
        ctx.beginPath()
        ctx.addLines(between: points)
        ctx.closePath()
    }

    static func render(size: Int) -> CGImage {
        let s = CGFloat(size)
        let ctx = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        // Дальше рисуем в координатах с началом в левом верхнем углу.
        ctx.translateBy(x: 0, y: s)
        ctx.scaleBy(x: 1, y: -1)

        // Поле иконки: у macOS содержимое занимает ~82% холста.
        let inset = s * 0.09
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = body.width * 0.2237
        let plate = CGPath(roundedRect: body, cornerWidth: radius,
                           cornerHeight: radius, transform: nil)

        if size <= 32 {
            ctx.addPath(plate)
            ctx.setFillColor(rgb(0x39206E))
            ctx.fillPath()
            let cx = body.midX
            let cy = body.midY
            let w = body.width * 0.30
            let h = w * 0.5
            let depth = body.height * 0.26
            let top = CGPoint(x: cx, y: cy - h - depth / 2)
            let left = CGPoint(x: cx - w, y: cy - depth / 2)
            let right = CGPoint(x: cx + w, y: cy - depth / 2)
            let center = CGPoint(x: cx, y: cy + h - depth / 2)
            let bottom = CGPoint(x: cx, y: center.y + depth)
            for (points, color) in [
                ([top, right, center, left], rgb(0xFFFFFF)),
                ([left, center, bottom, CGPoint(x: left.x, y: left.y + depth)], rgb(0x9976E3)),
                ([center, right, CGPoint(x: right.x, y: right.y + depth), bottom], rgb(0xD2BBFF))
            ] {
                polygon(ctx, points)
                ctx.setFillColor(color)
                ctx.fillPath()
            }
            return ctx.makeImage()!
        }
        // Фон: тот же фиолетовый градиент, что у кнопки «Играть».
        ctx.saveGState()
        ctx.addPath(plate)
        ctx.clip()
        gradient(ctx, [rgb(0x7A5CF0), rgb(0x9C56D8), rgb(0x5B3AAE)],
                 from: CGPoint(x: body.minX, y: body.minY),
                 to: CGPoint(x: body.maxX, y: body.maxY))
        // Мягкий блик сверху, чтобы плитка не выглядела плоской.
        gradient(ctx, [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)],
                 from: CGPoint(x: body.midX, y: body.minY),
                 to: CGPoint(x: body.midX, y: body.midY))
        ctx.restoreGState()

        // Тонкая светлая кромка.
        ctx.saveGState()
        if size >= 128 {
            ctx.addPath(plate)
            ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
            ctx.setLineWidth(max(1, s * 0.004))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Куб: изометрия 2:1. На малых размерах доля площади больше,
        // иначе в Dock 16 px куб теряется.
        let scale: CGFloat = size <= 32 ? 1.16 : (size <= 64 ? 1.06 : 1.0)
        let halfW = body.width * 0.225 * scale
        let halfH = halfW * 0.5
        let edge = body.height * 0.20 * scale
        let cx = body.midX
        let cy = body.midY - edge * 0.16

        let top = CGPoint(x: cx, y: cy - halfH - edge * 0.5)
        let right = CGPoint(x: cx + halfW, y: cy - edge * 0.5)
        let center = CGPoint(x: cx, y: cy + halfH - edge * 0.5)
        let left = CGPoint(x: cx - halfW, y: cy - edge * 0.5)
        let rightBottom = CGPoint(x: right.x, y: right.y + edge)
        let centerBottom = CGPoint(x: cx, y: center.y + edge)
        let leftBottom = CGPoint(x: left.x, y: left.y + edge)

        // Тень: мягкое радиальное пятно, а не эллипс с резкой кромкой.
        if size >= 64 {
            softShadow(ctx, center: CGPoint(x: cx, y: centerBottom.y + edge * 0.06),
                       width: halfW * 2.5, height: halfH * 1.5)
        }

        // Верхняя грань — самая светлая.
        polygon(ctx, [top, right, center, left])
        ctx.saveGState()
        ctx.clip()
        gradient(ctx, [rgb(0xFFFFFF), rgb(0xDCD2FF)],
                 from: top, to: CGPoint(x: cx, y: center.y + halfH))
        ctx.restoreGState()

        // Правая грань.
        polygon(ctx, [right, rightBottom, centerBottom, center])
        ctx.saveGState()
        ctx.clip()
        gradient(ctx, [rgb(0xC7B4FF), rgb(0x9B7CE8)],
                 from: right, to: centerBottom)
        ctx.restoreGState()

        // Левая грань — в тени.
        polygon(ctx, [left, center, centerBottom, leftBottom])
        ctx.saveGState()
        ctx.clip()
        gradient(ctx, [rgb(0x8C6FD6), rgb(0x6A4FB8)],
                 from: left, to: centerBottom)
        ctx.restoreGState()

        // Рёбра куба: держат форму на маленьких размерах.
        if size >= 32 {
            ctx.saveGState()
            ctx.setStrokeColor(rgb(0xFFFFFF, 0.26))
            ctx.setLineWidth(max(1, s * 0.005))
            ctx.setLineJoin(.round)
            for face in [[top, right, center, left],
                         [right, rightBottom, centerBottom, center],
                         [left, center, centerBottom, leftBottom]] {
                polygon(ctx, face)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest), "не удалось записать \(url.lastPathComponent)")
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var cache: [Int: CGImage] = [:]
for variant in IconRenderer.variants {
    let image = cache[variant.size] ?? IconRenderer.render(size: variant.size)
    cache[variant.size] = image
    IconRenderer.write(image, to: iconset.appendingPathComponent(variant.name))
    print("\(variant.name): \(variant.size)px")
}
IconRenderer.write(IconRenderer.render(size: 1024),
                   to: root.appendingPathComponent("icon.png"))
print("icon.png: 1024px")