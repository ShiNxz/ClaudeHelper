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

    @MainActor
    static func run(model: AppModel, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        if let ids = arg("--sync") {
            model.previewSync(folderIds: ids.split(separator: ",").map(String.init))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(dir.appendingPathComponent("plan-sync.png"))
            model.planSheet = nil
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }

    @MainActor
    static func capture(_ url: URL) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.title == "Claude Helper" }) else { return }
        let target = win.attachedSheet ?? win
        guard let view = target.contentView?.superview ?? target.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
