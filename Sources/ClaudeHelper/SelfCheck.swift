import AppKit
import HelperCore
import SwiftUI

/// `--snapshot <dir>`: the app walks through its screens and saves each window as PNG, then quits.
/// It only previews plans, it never applies one. Used to check the UI without screen recording rights.
enum SelfCheck {
    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static var outputDir: URL? { arg("--snapshot").map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// Filter the Sessions table starts with, so the check can show the chats this account lacks.
    @MainActor static var sessionsFilter: StatusFilter?

    @MainActor
    static func run(model: AppModel, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveMenuBarIcon(dir.appendingPathComponent("menubar-icon.png"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for section in AppSection.allCases {
            model.section = section
            if section == .search {
                model.autoSelectFirstResult = true
                model.searchQuery = arg("--query") ?? "deploy"
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            capture(dir.appendingPathComponent(section.rawValue.replacingOccurrences(of: " ", with: "-") + ".png"))
        }
        if let r = model.snapshot?.allSessions.first(where: { $0.isArchived && !$0.isStarred && !$0.folder.isBackupCopy }) {
            model.section = .sessions
            model.queue([r], archived: false)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            capture(dir.appendingPathComponent("pending.png"))
            model.previewPending()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(dir.appendingPathComponent("plan-restore.png"))
            model.planSheet = nil
            model.discardPending()
        }
        // A chat the signed-in account lacks: opening it shows the pull preview, never Claude.
        if let r = model.snapshot?.allSessions.first(where: { model.canPull($0) }) {
            model.section = .search
            sessionsFilter = .elsewhere
            try? await Task.sleep(nanoseconds: 500_000_000)
            model.section = .sessions
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(dir.appendingPathComponent("sessions-not-here.png"))
            sessionsFilter = nil
            model.open(r)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(dir.appendingPathComponent("plan-pull.png"))
            model.planSheet = nil
        }
        model.showToast(Toast(title: "Switched to someone@example.com", text: quoted("עיצוב חדש - Website redesign") + " is archived. It opens, but stays out of Claude's sidebar until you restore it.", warning: false))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        capture(dir.appendingPathComponent("toast.png"))
        if let ids = arg("--sync") {
            model.previewSync(folderIds: ids.split(separator: ",").map(String.init))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(dir.appendingPathComponent("plan-sync.png"))
            model.planSheet = nil
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }

    /// The template icon drawn 8x on a light and a dark strip, like the two menu bar styles.
    @MainActor
    static func saveMenuBarIcon(_ url: URL) {
        let scale: CGFloat = 8, side: CGFloat = 18 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.15, alpha: 1), NSColor.white)].enumerated() {
            let r = NSRect(x: CGFloat(i) * side, y: 0, width: side, height: side)
            bg.setFill(); r.fill()
            let tinted = NSImage(size: r.size, flipped: false) { rect in
                MenuBarIcon.image.draw(in: rect)
                fg.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: r)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    static func capture(_ url: URL) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.title == AppInfo.name }) else { return }
        let target = win.attachedSheet ?? win
        guard let view = target.contentView?.superview ?? target.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
