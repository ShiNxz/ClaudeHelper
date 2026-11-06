// Renders Resources/AppIcon.icns from plain shapes (no SF Symbols, no third-party marks).
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

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.27, green: 0.47, blue: 0.96, alpha: 1),
           ending: NSColor(red: 0.14, green: 0.22, blue: 0.55, alpha: 1))!.draw(in: bg, angle: -90)

NSColor(white: 1, alpha: 0.45).setFill()
bubble(NSRect(x: 215, y: 455, width: 430, height: 300), radius: 80, tailLeft: true)

NSColor.white.setFill()
bubble(NSRect(x: 375, y: 295, width: 440, height: 310), radius: 85, tailLeft: false)

NSColor(red: 0.20, green: 0.33, blue: 0.80, alpha: 1).setFill()
for i in 0..<3 {
    let cx = 485 + CGFloat(i) * 110
    NSBezierPath(ovalIn: NSRect(x: cx - 30, y: 420, width: 60, height: 60)).fill()
}
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
