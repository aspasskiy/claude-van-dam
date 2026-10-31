import AppKit

/// Two stacked bars for the active account: 5h on top, 7d below. An account
/// without a session limit (verified Ultra) gets one thicker bar for the week.
enum StatusIcon {
    static func image(fiveHour: Double?, sevenDay: Double?, sessionUnlimited: Bool = false, dimmed: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let barHeight: CGFloat = 5
        let gap: CGFloat = 2.5
        let image = NSImage(size: size, flipped: false) { rect in
            // Drawn lazily inside the status button, so labelColor follows
            // the menu bar's light/dark appearance.
            let barWidth = rect.width - 1
            if sessionUnlimited {
                let h: CGFloat = 7
                drawBar(in: NSRect(x: 0.5, y: rect.midY - h / 2, width: barWidth, height: h), pct: sevenDay, dimmed: dimmed)
                return true
            }
            let top = NSRect(x: 0.5, y: rect.midY + gap / 2, width: barWidth, height: barHeight)
            let bottom = NSRect(x: 0.5, y: rect.midY - gap / 2 - barHeight, width: barWidth, height: barHeight)
            drawBar(in: top, pct: fiveHour, dimmed: dimmed)
            drawBar(in: bottom, pct: sevenDay, dimmed: dimmed)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawBar(in rect: NSRect, pct: Double?, dimmed: Bool) {
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard let pct, pct > 0 else { return }
        let width = max(rect.height, rect.width * CGFloat(min(pct, 100)) / 100)
        let fill = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let color = dimmed ? NSColor.labelColor.withAlphaComponent(0.5) : Level(pct).nsColor
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
