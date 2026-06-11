// Generates build/AppIcon.iconset — a gauge symbol on a dark rounded square.
// Run via: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset
import AppKit

let iconsetPath = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func render(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)
    // macOS icon grid: content inset from the canvas edge
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let background = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(calibratedRed: 0.125, green: 0.115, blue: 0.105, alpha: 1).setFill()
    background.fill()

    // Anthropic-terracotta gauge symbol, centered
    let terracotta = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .medium)
        .applying(.init(paletteColors: [terracotta]))
    if let symbol = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let scale = (s * 0.6) / max(size.width, size.height)
        let w = size.width * scale
        let h = size.height * scale
        symbol.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        guard let rep = render(pixels: px),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: "\(iconsetPath)/icon_\(base)x\(base)\(suffix).png")
        try? png.write(to: url)
    }
}
print("iconset written to \(iconsetPath)")
