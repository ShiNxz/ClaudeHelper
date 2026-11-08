import HelperCore
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: LoginProfile?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Every account used on this Mac is listed here, with how much of its 5-hour and weekly limit is used. Switch between saved ones from here or from the menu bar, without logging in again. For an account that is not saved yet, click Log In and Save once.")
                    .foregroundStyle(.secondary)
                Text("Don't use Log out inside Claude, and don't sign in to a saved account by hand: both end its saved login. The signed-in account's saved copy refreshes by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                if model.accountEntries.isEmpty {
                    Text("No accounts found yet.").foregroundStyle(.secondary)
                }
                let pick = model.autoSwitchPick?.id
                ForEach(model.accountEntries) { e in
                    AccountRow(entry: e, switching: model.switching, isNextPick: e.id == pick,
                               onActivate: { model.activate(e) },
                               onSave: { model.saveCurrentLogin(name: e.email ?? e.title) },
                               onRename: e.profile.map { p in { renaming = p; renameText = p.name } },
                               onForget: e.profile.map { p in { model.deleteProfile(p) } })
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Button("Add Another Account...") { model.confirmAndAddAccount() }
                        .disabled(model.switching)
                        .help("For an account never used on this Mac: reopens Claude signed out so you can log in to it")
                }
            }
            Section {
                Toggle("Switch to the least used account when this one runs low", isOn: $model.autoSwitchEnabled)
                Picker("Switch at", selection: $model.autoSwitchThreshold) {
                    ForEach([80, 85, 90, 95, 98, 100], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!model.autoSwitchEnabled)
                .help("Of the 5-hour or the weekly limit, whichever is reached first")
                Toggle("Wait until running chats finish", isOn: $model.autoSwitchWaitForIdle)
                    .disabled(!model.autoSwitchEnabled)
                Text(autoSwitchExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = model.autoSwitchStatus {
                    Label(status, systemImage: "clock").font(.callout).foregroundStyle(.orange)
                } else if model.autoSwitchEnabled, let next = model.autoSwitchPick {
                    Text("Next account when needed: \(next.title)").font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Auto-switch")
            }
            Section("When switching") {
                Toggle("Merge chats between the accounts picked in Sync chats", isOn: $model.switchSyncEnabled)
                Text(model.pickedAccounts.count >= 2
                     ? "\(model.pickedAccounts.count) accounts are picked. Each merge is backed up first."
                     : "Pick at least two accounts in Sync chats for this to do anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.switching || !model.switchSteps.isEmpty {
                Section("Last switch") {
                    ForEach(Array(model.switchSteps.enumerated()), id: \.offset) { _, s in Text(s).font(.callout) }
                    if model.switching { ProgressView().controlSize(.small) }
                }
            }
            Section {
                Text("Saved logins stay on this Mac in ~/Library/Application Support/ClaudeHelper/profiles (only your user can read it). They are copies of Claude's own encrypted login data and work only on this Mac. Relay never reads the Keychain and never shows or sends the login data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refresh()
            model.refreshUsage()
        }
        .sheet(item: $renaming) { p in
            VStack(alignment: .leading, spacing: 12) {
                Text("Name for this account").font(.headline)
                TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") { model.renameProfile(p, to: renameText); renaming = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }
}

extension AccountsView {
    var autoSwitchExplanation: String {
        var t = "Checks every minute while Claude runs. When the signed-in account reaches \(model.autoSwitchThreshold)% of its 5-hour or weekly limit, "
            + "it picks the saved account with the lowest weekly use that is under \(model.autoSwitchThreshold)% on both. Claude quits and reopens on that account, "
            + "the chats you worked on in the last day are copied over (backed up first), and the newest one opens again."
        t += model.autoSwitchWaitForIdle
            ? " It waits until no chat is writing, so no reply is cut off. If a chat hits the limit first, it stops there; send \"continue\" in it after the switch."
            : " A chat that is still replying stops when Claude quits; send \"continue\" in it after the switch."
        return t
    }
}

/// Percent used of one limit, as a small bar.
struct UsageMeter: View {
    let label: String
    let percent: Int
    let detail: String?

    var color: Color { percent >= 90 ? .red : percent >= 70 ? .orange : .green }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(percent > 0 ? 3 : 0, 70 * CGFloat(min(percent, 100)) / 100))
            }
            .frame(width: 70, height: 6)
            Text("\(percent)%").monospacedDigit().fixedSize().frame(minWidth: 34, alignment: .leading)
            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        }
        .font(.caption)
    }
}

struct UsageLine: View {
    let usage: AccountUsage?
    let isActive: Bool

    /// "15:14" today, "Sat 23:19" within a week either way, otherwise "7 Nov".
    static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if abs(d.timeIntervalSinceNow) < 6.5 * 86400 { return d.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        if let u = usage {
            let now = Date()
            HStack(spacing: 14) {
                UsageMeter(label: "5-hour", percent: u.fiveHourNow(now), detail: u.fiveHourReset(now).map { "resets by " + Self.when($0) })
                if let week = u.sevenDayNow(now) {
                    UsageMeter(label: "Week", percent: week, detail: u.weekReset(now).map { "resets by " + Self.when($0) })
                }
                Text(asOf(u, now)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            }
            .help("From Claude's own usage records. Updated about every 30 minutes while this account is signed in; for other accounts it is the last known figure, and a limit counts as reset once its window has passed.")
        } else {
            Text(isActive ? "No usage recorded yet. Claude records it about every 30 minutes." : "No usage known. Claude records it while this account is signed in.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    func asOf(_ u: AccountUsage, _ now: Date) -> String {
        let age = now.timeIntervalSince(u.sampledAt)
        if age < 120 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        return "as of " + Self.when(u.sampledAt)
    }
}

struct AccountRow: View {
    let entry: AppModel.AccountEntry
    let switching: Bool
    var isNextPick = false
    let onActivate: () -> Void
    let onSave: () -> Void
    let onRename: (() -> Void)?
    let onForget: (() -> Void)?

    var status: (text: String, warning: Bool) {
        guard let p = entry.profile else {
            return (entry.isActive ? "Signed in, not saved yet" : "Not saved yet", false)
        }
        if let problem = p.problem { return (problem, true) }
        if p.isExpired { return ("Saved login expired. Use Log In Again.", true) }
        var t = "Saved " + p.savedAt.formatted(date: .abbreviated, time: .shortened)
        if let e = p.sessionExpires { t += ", valid until " + e.formatted(date: .abbreviated, time: .omitted) }
        return (t, false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            UsageLine(usage: entry.usage, isActive: entry.isActive)
        }
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                    if let n = entry.nickname { Text(n).foregroundStyle(.secondary) }
                    if entry.isActive { Text("signed in").font(.caption).foregroundStyle(.green) }
                    if isNextPick {
                        Text("next").font(.caption).foregroundStyle(.blue)
                            .help("Auto-switch would move to this account")
                    }
                }
                Text(status.text).font(.caption)
                    .foregroundStyle(status.warning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let onRename { Button("Rename", action: onRename) }
            if let onForget { Button("Forget", action: onForget).help("Delete Relay's saved copy of this login") }
            if entry.isActive {
                if entry.profile == nil { Button("Save", action: onSave).disabled(switching) }
            } else if let p = entry.profile, !p.needsLogin {
                Button("Switch", action: onActivate).disabled(switching)
            } else {
                Button(entry.profile == nil ? "Log In and Save" : "Log In Again", action: onActivate).disabled(switching)
            }
        }
    }
}
