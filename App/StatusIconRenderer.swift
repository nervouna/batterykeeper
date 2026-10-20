import AppKit
import BatteryKeeperCore

/// Draws the menu bar image for a ``StatusIconModel``. Without colour the image is a template, so the menu
/// bar tints it; with colour it is drawn at display time in the menu bar's appearance.
enum StatusIconRenderer {
    static let height: CGFloat = 16
    static let badgeWidth: CGFloat = 10

    static func image(for model: StatusIconModel) -> NSImage? {
        let badgeSymbol = symbolName(model.badge)
        let bodyWidth: CGFloat
        switch model.style {
        case .battery: bodyWidth = 24
        case .ring: bodyWidth = 14
        case .text: bodyWidth = 0
        }
        if bodyWidth == 0 && badgeSymbol == nil { return nil }
        let width = bodyWidth + (badgeSymbol == nil ? 0 : badgeWidth + (bodyWidth > 0 ? 2 : 0))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let palette = Palette(model: model)
            var x: CGFloat = 0
            if let badgeSymbol {
                drawSymbol(badgeSymbol, in: NSRect(x: 0, y: 0, width: badgeWidth, height: height), color: palette.badge)
                x = badgeWidth + 2
            }
            switch model.style {
            case .battery: drawBattery(in: NSRect(x: x, y: 0, width: bodyWidth, height: height), model: model, palette: palette)
            case .ring: drawRing(in: NSRect(x: x, y: 0, width: bodyWidth, height: height), model: model, palette: palette)
            case .text: break
            }
            return true
        }
        image.isTemplate = !model.colorful
        return image
    }

    private struct Palette {
        var outline: NSColor
        var fill: NSColor
        var badge: NSColor

        init(model: StatusIconModel) {
            guard model.colorful else {
                outline = NSColor.black.withAlphaComponent(0.45)
                fill = .black
                badge = .black
                return
            }
            let label = NSColor.labelColor
            outline = label.withAlphaComponent(0.45)
            let accent: NSColor
            if model.badge == .cycle {
                accent = .systemPurple
            } else if model.isLow {
                accent = .systemRed
            } else {
                switch model.status {
                case .charging: accent = .systemGreen
                case .heldAtLimit: accent = .systemBlue
                case .dischargingOnPower: accent = .systemOrange
                default: accent = label
                }
            }
            fill = accent
            badge = accent
        }
    }

    private static func drawBattery(in rect: NSRect, model: StatusIconModel, palette: Palette) {
        let body = NSRect(x: rect.minX + 0.5, y: rect.midY - 5.5, width: rect.width - 3, height: 11)
        let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        palette.outline.setStroke()
        outline.stroke()

        let nub = NSRect(x: body.maxX + 0.5, y: rect.midY - 2, width: 1.5, height: 4)
        palette.outline.setFill()
        NSBezierPath(roundedRect: nub, xRadius: 0.75, yRadius: 0.75).fill()

        let inner = body.insetBy(dx: 2, dy: 2)
        let fraction = min(max(model.fill, 0), 1)
        guard fraction > 0 else { return }
        let fillRect = NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * fraction), height: inner.height)
        palette.fill.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private static func drawRing(in rect: NSRect, model: StatusIconModel, palette: Palette) {
        let lineWidth: CGFloat = 2.2
        let diameter = min(rect.width, rect.height) - lineWidth - 1
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = diameter / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        palette.outline.setStroke()
        track.stroke()

        let fraction = min(max(model.fill, 0), 1)
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        palette.fill.setStroke()
        arc.stroke()
    }

    private static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = symbol.size
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: size))
    }

    static func symbolName(_ badge: IconBadge) -> String? {
        switch badge {
        case .none: nil
        case .charging: "bolt.fill"
        case .held: "pause.fill"
        case .discharging: "arrow.down"
        case .cycle: "arrow.triangle.2.circlepath"
        }
    }
}
