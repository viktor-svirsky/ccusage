import Cocoa

// Icon sizes: (points, scale)
let iconSizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (64, 1), (64, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

func renderIcon(pixelSize: Int) -> NSImage {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let image = NSImage(size: size)
    image.lockFocus()

    let rect = NSRect(origin: .zero, size: size)
    let cornerRadius = CGFloat(pixelSize) * 0.22

    // Rounded rect clipping path
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()

    // Gradient background (dark blue to purple)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.4, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.4, green: 0.1, blue: 0.5, alpha: 1.0)
    )!
    gradient.draw(in: rect, angle: -45)

    // Draw SF Symbol "gauge.medium"
    let symbolName = "gauge.medium"
    let symbolSize = CGFloat(pixelSize) * 0.55
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)

    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
    {
        let symbolSize = symbol.size
        let x = (CGFloat(pixelSize) - symbolSize.width) / 2
        let y = (CGFloat(pixelSize) - symbolSize.height) / 2
        let symbolRect = NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height)

        NSColor.white.setFill()
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceAtop, fraction: 1.0)

        // Draw white tinted symbol
        let tintedImage = NSImage(size: NSSize(width: symbolSize.width, height: symbolSize.height))
        tintedImage.lockFocus()
        NSColor.white.set()
        symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        tintedImage.unlockFocus()

        tintedImage.draw(in: symbolRect)
    }

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, pixelSize: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context

    let targetRect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    image.draw(in: targetRect, from: .zero, operation: .copy, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// Main
let iconsetDir = "CCUsage.iconset"
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (points, scale) in iconSizes {
    let pixelSize = points * scale
    let image = renderIcon(pixelSize: pixelSize)
    let suffix = scale > 1 ? "@\(scale)x" : ""
    let filename = "\(iconsetDir)/icon_\(points)x\(points)\(suffix).png"
    savePNG(image, pixelSize: pixelSize, to: filename)
    print("Generated \(filename) (\(pixelSize)x\(pixelSize) px)")
}

print("Done. Run: iconutil -c icns \(iconsetDir)")
