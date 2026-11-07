import AppKit

/// Menu bar icon: a chat bubble with a sparkle cut out, drawn as a template image so macOS tints it
/// for light and dark menu bars. Same mark as the app icon.
enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 16, height: 12.5), xRadius: 4, yRadius: 4)
            // Sparkle cut out of the bubble (even-odd fill).
            let c = NSPoint(x: 9, y: 10.25), r: CGFloat = 4.4, k = r * 0.2
            let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
            let ctrl = [NSPoint(x: c.x + k, y: c.y + k), NSPoint(x: c.x + k, y: c.y - k), NSPoint(x: c.x - k, y: c.y - k), NSPoint(x: c.x - k, y: c.y + k)]
            body.move(to: tips[0])
            for i in 0..<4 { body.curve(to: tips[(i + 1) % 4], controlPoint1: ctrl[i], controlPoint2: ctrl[i]) }
            body.close()
            body.windingRule = .evenOdd
            body.fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 3.5, y: 5))
            tail.line(to: NSPoint(x: 2.5, y: 1))
            tail.line(to: NSPoint(x: 7.5, y: 5))
            tail.close()
            tail.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
