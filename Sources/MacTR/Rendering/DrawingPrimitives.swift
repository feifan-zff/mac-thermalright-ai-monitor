// DrawingPrimitives.swift — Core Graphics drawing utilities
//
// Ported from trcc_monitor.py drawing functions.
// All drawing uses CGContext directly for maximum control.

import AppKit
import CoreGraphics
import Foundation

enum Draw {

    // MARK: - Background

    /// Draw vertical gradient background.
    /// In flipped context: Y=0 is top, so bgTop at y=0, bgBot at y=height.
    static func gradientBackground(_ ctx: CGContext) {
        guard let bg = backgroundImage() else { return }
        ctx.saveGState()
        // Undo flip: an untransformed, same-size .copy blit takes CG's memcpy fast
        // path (~0.3ms) instead of shading the full gradient every frame (~3.4ms).
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -CGFloat(Layout.height))
        ctx.setBlendMode(.copy)
        ctx.draw(bg, in: CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        ctx.restoreGState()
    }

    private static let backgroundLock = NSLock()
    nonisolated(unsafe) private static var background: (w: Int, h: Int, image: CGImage)?

    /// The vertical background gradient, rendered once per screen size.
    private static func backgroundImage() -> CGImage? {
        backgroundLock.lock(); defer { backgroundLock.unlock() }
        let w = Layout.width, h = Layout.height
        if let b = background, b.w == w, b.h == h { return b.image }
        let colors = [Color.bgTop, Color.bgBot] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors, locations: [0, 1]),
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Native CG coords: bgTop at the top edge (y = height)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(h)),
            end: CGPoint(x: 0, y: 0),
            options: [])
        guard let image = ctx.makeImage() else { return nil }
        background = (w, h, image)
        return image
    }

    // MARK: - Panel

    /// Draw a rounded panel. Assumes flipped context (Y=0 at top).
    static func panel(_ ctx: CGContext, x: Int, y: Int, w: Int, h: Int, radius: CGFloat = 16) {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        ctx.setFillColor(Color.panelBG)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    // MARK: - Arc Gauge

    /// Draw an arc gauge (like speedometer).
    /// Assumes flipped context (Y=0 at top, like PIL).
    /// PIL arc: start=135°, sweep=270° clockwise.
    /// In flipped CG: clockwise in screen space = clockwise:false in CG API.
    static func arcGauge(
        _ ctx: CGContext, cx: Int, cy: Int, radius: Int,
        percent: Double, color: CGColor, colorDark: CGColor, thickness: CGFloat = 12
    ) {
        let r = CGFloat(radius)
        let center = CGPoint(x: CGFloat(cx), y: CGFloat(cy))

        // In flipped context, Y is inverted so angles go clockwise visually
        // PIL: start=135, end=135+270=405. CG flipped: use positive angles, clockwise=false
        let startAngle = CGFloat(135) * .pi / 180
        let fullEndAngle = CGFloat(135 + 270) * .pi / 180

        // Background arc
        ctx.setStrokeColor(colorDark)
        ctx.setLineWidth(thickness)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: r, startAngle: startAngle,
                   endAngle: fullEndAngle, clockwise: false)
        ctx.strokePath()

        // Foreground arc (percentage)
        if percent > 0 {
            let pct = min(percent, 100)
            let sweepAngle = startAngle + (fullEndAngle - startAngle) * CGFloat(pct / 100)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(thickness)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: r, startAngle: startAngle,
                       endAngle: sweepAngle, clockwise: false)
            ctx.strokePath()

            // End dot — in flipped context, sin goes downward (+Y)
            let dotR = thickness / 2
            let ex = CGFloat(cx) + r * cos(sweepAngle)
            let ey = CGFloat(cy) + r * sin(sweepAngle)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: ex - dotR, y: ey - dotR,
                                       width: dotR * 2, height: dotR * 2))
        }
    }

    // MARK: - Bar

    /// Draw a rounded progress bar
    static func bar(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        percent: Double, color: CGColor, bg: CGColor = Color.barBG
    ) {
        let radius = CGFloat(h) / 2

        // Background
        let bgRect = CGRect(x: x, y: y, width: w, height: h)
        ctx.setFillColor(bg)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        // Fill
        if percent > 0 {
            let pct = min(percent, 100)
            let fw = max(h, Int(Double(w) * pct / 100))
            let fillRect = CGRect(x: x, y: y, width: fw, height: h)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }

    // MARK: - Text

    // Typeset once: the panel draws the same few hundred texts in the same
    // fonts and colours again and again, and laying a text out (font fallback
    // for Chinese, shaping) is most of what drawing it costs
    private struct TextKey: Hashable {
        let string: String
        let font: NSFont
        let color: CGColor?   // nil: measured only
    }
    nonisolated(unsafe) private static var lines: [TextKey: CTLine] = [:]
    private static let linesLock = NSLock()

    private static func line(_ string: String, font: NSFont, color: CGColor?) -> CTLine {
        let key = TextKey(string: string, font: font, color: color)
        linesLock.lock()
        defer { linesLock.unlock() }
        if let l = lines[key] { return l }
        if lines.count > 4000 { lines.removeAll(keepingCapacity: true) }   // texts that tick come and go
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        lines[key] = l
        return l
    }

    /// A text's width, as drawn.
    static func width(_ string: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(string, font: font, color: nil), nil, nil, nil))
    }

    /// Draw text with its line's top-left at a position, as NSString drawing
    /// in a flipped view does. Assumes context is already flipped (Y=0 at top).
    static func text(
        _ ctx: CGContext, _ string: String, x: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let l = line(string, font: font, color: color)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(l, &ascent, nil, nil)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let matrix = ctx.textMatrix
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // upright glyphs in a flipped context
        // NSString drawing puts the baseline at the ascent rounded (matched pixel for pixel)
        ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(y) + ascent.rounded())
        CTLineDraw(l, ctx)
        ctx.textMatrix = matrix
    }

    /// Draw centered text
    static func centeredText(
        _ ctx: CGContext, _ string: String, cx: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let x = CGFloat(cx) - width(string, font: font) / 2
        text(ctx, string, x: Int(x), y: y, font: font, color: color)
    }

    // MARK: - Line

    static func line(
        _ ctx: CGContext, from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat = 1
    ) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    // MARK: - Sparkline (trend graph)

    /// Draw a mirrored bar chart with labels above and below.
    /// Layout:  [topLabel topValue]
    ///          [====chart area====]
    ///          [botLabel botValue]
    /// Total height = labelH + chartH + labelH
    static func mirrorBarChart(
        _ ctx: CGContext,
        topValues: [Double], bottomValues: [Double],
        x: Int, y: Int, w: Int, h: Int,
        topColor: CGColor, bottomColor: CGColor,
        topLabel: String, bottomLabel: String,
        topCurrent: String, bottomCurrent: String
    ) {
        let labelH = 16
        let chartY = y + labelH + 2
        let chartH = h - (labelH + 2) * 2
        guard chartH > 4 else { return }

        let midY = CGFloat(chartY + chartH / 2)
        let halfH = CGFloat(chartH / 2)
        let count = max(topValues.count, bottomValues.count)
        guard count > 0 else { return }

        let barW = max(1, CGFloat(w) / CGFloat(count))
        let topMax = topValues.max() ?? 1
        let botMax = bottomValues.max() ?? 1
        let maxVal = max(topMax, botMax, 1)

        // Top label line
        text(ctx, "\(topLabel) \(topCurrent)", x: x, y: y,
             font: Fonts.system(15), color: topColor)

        // Center axis
        ctx.setStrokeColor(Color.border)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: CGFloat(x), y: midY))
        ctx.addLine(to: CGPoint(x: CGFloat(x + w), y: midY))
        ctx.strokePath()

        // Top bars (grow upward)
        for (i, val) in topValues.enumerated() {
            let barH = CGFloat(val / maxVal) * (halfH - 1)
            if barH < 0.5 { continue }
            let bx = CGFloat(x) + CGFloat(i) * barW
            ctx.setFillColor(topColor.copy(alpha: 0.8) ?? topColor)
            ctx.fill(CGRect(x: bx, y: midY - barH, width: max(barW - 1, 1), height: barH))
        }

        // Bottom bars (grow downward)
        for (i, val) in bottomValues.enumerated() {
            let barH = CGFloat(val / maxVal) * (halfH - 1)
            if barH < 0.5 { continue }
            let bx = CGFloat(x) + CGFloat(i) * barW
            ctx.setFillColor(bottomColor.copy(alpha: 0.8) ?? bottomColor)
            ctx.fill(CGRect(x: bx, y: midY, width: max(barW - 1, 1), height: barH))
        }

        // Bottom label line
        text(ctx, "\(bottomLabel) \(bottomCurrent)", x: x, y: y + h - labelH,
             font: Fonts.system(15), color: bottomColor)
    }

    /// Format bytes per second to human-readable string
    static func formatBytesPerSec(_ bps: Double) -> String {
        if bps >= 1_000_000_000 { return String(format: "%.1f GB/s", bps / 1e9) }
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1e6) }
        if bps >= 1_000 { return String(format: "%.1f KB/s", bps / 1e3) }
        return String(format: "%.0f B/s", bps)
    }
}
