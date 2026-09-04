import AppKit

/// Original vector mark: an open C surrounding a connected node.
/// Template rendering lets macOS choose the tint for every menu bar appearance.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let arc = NSBezierPath()
            arc.lineWidth = 1.75
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: 8, y: 9), radius: 6,
                          startAngle: 45, endAngle: 315, clockwise: false)
            arc.stroke()

            let connection = NSBezierPath()
            connection.lineWidth = 1.75
            connection.lineCapStyle = .round
            connection.move(to: NSPoint(x: 8, y: 9))
            connection.line(to: NSPoint(x: 15, y: 9))
            connection.stroke()

            NSBezierPath(ovalIn: NSRect(x: 6, y: 7, width: 4, height: 4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 13.5, y: 7.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude Connection Watcher"
        return image
    }
}
