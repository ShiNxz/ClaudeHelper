// Renders Resources/AppIcon.icns from plain shapes (no SF Symbols, no third-party logos).
// Run: swift scripts/make-icon.swift [output.icns]
import AppKit

let size: CGFloat = 1024

/// Body and tail are filled separately so the overlap does not cancel out.
func bubble(_ rect: NSRect, radius: CGFloat, tailLeft: Bool) {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    let tail = NSBezierPath()
    let baseY = rect.minY + 2
    if tailLeft {
        tail.move(to: NSPoint(x: rect.minX + radius * 0.6, y: baseY + 30))
        tail.line(to: NSPoint(x: rect.minX + radius * 0.2, y: baseY - 70))
        tail.line(to: NSPoint(x: rect.minX + radius * 1.6, y: baseY + 30))
    } else {
        tail.move(to: NSPoint(x: rect.maxX - radius * 0.6, y: baseY + 30))
        tail.line(to: NSPoint(x: rect.maxX - radius * 0.2, y: baseY - 70))
        tail.line(to: NSPoint(x: rect.maxX - radius * 1.6, y: baseY + 30))
    }
    tail.close()
    tail.fill()
}

/// Four-point sparkle with curved sides.
func sparkle(center c: NSPoint, radius r: CGFloat, pinch: CGFloat = 0.18) -> NSBezierPath {
    let p = NSBezierPath()
    let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
    let k = r * pinch
    let controls = [NSPoint(x: c.x + k, y: c.y + k), NSPoint(x: c.x + k, y: c.y - k), NSPoint(x: c.x - k, y: c.y - k), NSPoint(x: c.x - k, y: c.y + k)]
    p.move(to: tips[0])
    for i in 0..<4 {
        p.curve(to: tips[(i + 1) % 4], controlPoint1: controls[i], controlPoint2: controls[i])
    }
    p.close()
    return p
}

// Warm terracotta and cream, in the spirit of the Claude app, with an original mark (not Anthropic's logo).
let terracotta = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let cream = NSColor(red: 0.980, green: 0.961, blue: 0.918, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.875, green: 0.500, blue: 0.370, alpha: 1),
           ending: NSColor(red: 0.760, green: 0.380, blue: 0.255, alpha: 1))!.draw(in: bg, angle: -90)

cream.setFill()
bubble(NSRect(x: 235, y: 330, width: 554, height: 420), radius: 125, tailLeft: true)

terracotta.setFill()
sparkle(center: NSPoint(x: 512, y: 540), radius: 150).fill()
image.unlockFocus()

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
if CommandLine.arguments.contains("--png") {
    try! fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                     to: URL(fileURLWithPath: "icon-preview.png"))
}
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print("wrote \(out.path)")
