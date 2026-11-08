import AppKit
import HelperCore
import SwiftUI

struct ClaudeHelperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 720)

        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            MenuBarLabel()
        }
    }
}

/// The menu bar icon. It lives as long as the app, so it also opens the window when a notification is clicked.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            .onReceive(NotificationCenter.default.publisher(for: .openHelperWindow)) { _ in
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// "5h 42% · wk 81%" for menus, or nil without data.
func usageSummary(_ u: AccountUsage?) -> String? {
    guard let u else { return nil }
    var parts = ["5h \(u.fiveHourNow())%"]
    if let w = u.sevenDayNow() { parts.append("wk \(w)%") }
    return parts.joined(separator: " \u{00B7} ")
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open \(AppInfo.name)") { show(.sessions) }
        Button("Search Chats") { show(.search) }
        Button("Sync Chats") { show(.sync) }
        Divider()
        if model.switching {
            Text("Switching: " + (model.switchSteps.last ?? "starting"))
        } else if !model.accountEntries.isEmpty {
            Text("Claude account")
            ForEach(model.accountEntries) { e in
                let usage = usageSummary(e.usage).map { "   " + $0 } ?? ""
                if e.isActive {
                    Button("\u{2713} " + e.title + usage) {}.disabled(true)
                } else if let p = e.profile, !p.needsLogin {
                    Button("     " + e.title + usage) { model.activate(e) }
                } else {
                    Button("     " + e.title + (e.profile == nil ? " (log in to save)" : " (log in again)")) { model.activate(e) }
                }
            }
            if model.autoSwitchEnabled {
                Text(model.autoSwitchStatus ?? "Auto-switch on at \(model.autoSwitchThreshold)%")
            }
            Button("Manage Accounts...") { show(.accounts) }
        }
        Divider()
        Text(model.indexStatusText)
        if model.indexProgress.isRunning {
            Button("Stop Indexing") { model.cancelIndexing() }
        } else {
            Button("Update Search Index") { model.startIndexing() }
        }
        Divider()
        Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    func show(_ s: AppSection) {
        model.section = s
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                switch model.section {
                case .sessions: SessionsView()
                case .search: SearchView()
                case .accounts: AccountsView()
                case .sync: SyncView()
                case .backups: BackupsView()
                }
            }
            .overlay(alignment: .bottom) {
                if let t = model.toast {
                    ToastView(toast: t) { model.toast = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { model.toast = nil }
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
        }
        .sheet(item: $model.planSheet) { _ in PlanSheetView() }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .task {
            if let dir = SelfCheck.outputDir { await SelfCheck.run(model: model, dir: dir) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(model.claudeRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(model.claudeRunning ? "Claude is running" : "Claude is not running")
            }
            if model.indexProgress.isRunning {
                ProgressView(value: model.indexProgress.fraction).controlSize(.small)
            }
            Text(model.indexStatusText).lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
