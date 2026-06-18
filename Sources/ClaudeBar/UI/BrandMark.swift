import AppKit
import SwiftUI

/// The ClaudeBar brand mark — a gauge ring around a `>_` terminal prompt —
/// rendered for the menu bar. Returned as a template image so macOS tints it to
/// match the menu bar (the Monochrome Light / Monochrome Dark variants from the
/// design spec). The colourful gradient version lives in scripts/make-icon.swift
/// for the app icon; keep the geometry here in sync with it.
enum BrandMark {
    // Geometry as fractions of the square canvas (origin bottom-left). Strokes
    // are a touch heavier than the app icon so the mark stays legible at ~16pt.
    private static let ringRadius: CGFloat = 0.31
    private static let ringWidth: CGFloat = 0.10
    private static let promptWidth: CGFloat = 0.085
    private static let arcStartDeg: CGFloat = 138
    private static let arcEndDeg: CGFloat = -128

    // Scales the whole mark up within its square so it reads at the size of
    // neighbouring menu-bar icons rather than floating in empty padding.
    private static let fill: CGFloat = 1.18

    private static func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

    /// Template menu-bar image. `pointSize` is the rendered square edge in points.
    static func menuBarImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = pointSize
            let center = CGPoint(x: s / 2, y: s / 2)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: fill, y: fill)
            ctx.translateBy(x: -center.x, y: -center.y)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Gauge arc (the gap on the left echoes the app icon).
            ctx.setLineWidth(ringWidth * s)
            ctx.addArc(center: center, radius: ringRadius * s,
                       startAngle: deg(arcStartDeg), endAngle: deg(arcEndDeg), clockwise: true)
            ctx.strokePath()

            // `>_` prompt.
            ctx.setLineWidth(promptWidth * s)
            let chevron = CGMutablePath()
            chevron.move(to: CGPoint(x: 0.355 * s, y: 0.595 * s))
            chevron.addLine(to: CGPoint(x: 0.495 * s, y: 0.498 * s))
            chevron.addLine(to: CGPoint(x: 0.355 * s, y: 0.401 * s))
            ctx.addPath(chevron)
            ctx.strokePath()

            let underscore = CGMutablePath()
            underscore.move(to: CGPoint(x: 0.520 * s, y: 0.398 * s))
            underscore.addLine(to: CGPoint(x: 0.650 * s, y: 0.398 * s))
            ctx.addPath(underscore)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
