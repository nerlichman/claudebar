// Generates build/AppIcon.iconset — the designer's ClaudeBar mark
// (assets/logo-claude-bar.png) composited, centered, onto a dark squircle.
// Run via: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset
import AppKit

let iconsetPath = "build/AppIcon.iconset"
let markPath = "assets/logo-claude-bar.png"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

/// Loads the brand mark and trims its transparent margins so it can be centered
/// precisely on the squircle regardless of the source canvas aspect ratio.
func loadTrimmedMark() -> NSImage? {
    guard let img = NSImage(contentsOfFile: markPath),
          let tiff = img.tiffRepresentation,
          let srcRep = NSBitmapImageRep(data: tiff) else { return nil }
    let w = srcRep.pixelsWide, h = srcRep.pixelsHigh

    // Redraw into a known RGBA8 layout so alpha is byte 3 of every pixel.
    guard let norm = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: norm)
    srcRep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = norm.bitmapData else { return nil }
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY, let cg = norm.cgImage else { return nil }
    let bw = maxX - minX + 1, bh = maxY - minY + 1
    guard let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: bw, height: bh)) else { return nil }
    return NSImage(cgImage: cropped, size: NSSize(width: bw, height: bh))
}

let mark = loadTrimmedMark()
if mark == nil { FileHandle.standardError.write(Data("warning: could not load \(markPath)\n".utf8)) }

func render(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = nsCtx?.cgContext else { return nil }

    let s = CGFloat(pixels)

    // Dark squircle background with a subtle top-down highlight.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    let bgGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.165, green: 0.150, blue: 0.135, alpha: 1),
        NSColor(calibratedRed: 0.090, green: 0.082, blue: 0.074, alpha: 1),
    ])!
    bgGrad.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // The mark, scaled to fill ~74% of the canvas and centered.
    if let mark {
        let target = s * 0.74
        let scale = target / max(mark.size.width, mark.size.height)
        let dw = mark.size.width * scale, dh = mark.size.height * scale
        mark.draw(in: NSRect(x: (s - dw) / 2, y: (s - dh) / 2, width: dw, height: dh),
                  from: .zero, operation: .sourceOver, fraction: 1)
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
