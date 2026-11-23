import SwiftUI
import CoreGraphics
import Foundation
import ImageIO

/// Тот же SF Symbol и стиль, что над HomeCraft на главном экране.
/// Каждый размер рендерится отдельно, фон остаётся прозрачным.
@MainActor
enum IconRenderer {
    static let variants: [(name: String, size: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]

    static func render(size: Int) -> CGImage {
        let content = Image(systemName: "cube.fill")
            .font(.system(size: CGFloat(size) * 0.68, weight: .light))
            .foregroundStyle(.purple)
            .frame(width: CGFloat(size), height: CGFloat(size))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            preconditionFailure("не удалось отрисовать cube.fill")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest), "не удалось записать \(url.lastPathComponent)")
    }
}

try MainActor.assumeIsolated {
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
}