import AppKit
import HelperCore
import SwiftUI

struct ClaudeHelperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Claude Helper", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 720)

        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Claude Helper") { show(.sessions) }
        Button("Search Chats") { show(.search) }
        Button("Account Sync") { show(.sync) }
        Divider()
        if model.switching {
            Text("Switching: " + (model.switchSteps.last ?? "starting"))
        } else if model.profiles.isEmpty {
            Button("Save Current Login...") { show(.accounts) }
        } else {
            Text("Switch Claude account")
            ForEach(model.profiles) { p in
                Button {
                    model.confirmAndSwitch(p)
                } label: {
                    if p.id == model.activeProfile?.id { Text("\u{2713} " + p.name) } else { Text("     " + p.name) }
                }
                .disabled(p.id == model.activeProfile?.id)
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
        Button("Quit Claude Helper") { NSApp.terminate(nil) }
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
                if let banner = model.banner {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(banner).lineLimit(2)
                        Spacer()
                        Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.15))
                }
                switch model.section {
                case .sessions: SessionsView()
                case .search: SearchView()
                case .accounts: AccountsView()
                case .sync: SyncView()
                case .backups: BackupsView()
                }
            }
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
