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
                Text("Every account used on this Mac is listed here. Switch between saved ones from here or from the menu bar, without logging in again. For an account that is not saved yet, click Log In and Save once.")
                    .foregroundStyle(.secondary)
                Text("Don't use Log out inside Claude, and don't sign in to a saved account by hand: both end its saved login. The signed-in account's saved copy refreshes by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                if model.accountEntries.isEmpty {
                    Text("No accounts found yet.").foregroundStyle(.secondary)
                }
                ForEach(model.accountEntries) { e in
                    AccountRow(entry: e, switching: model.switching,
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
            Section("When switching") {
                Toggle("Sync chats between the account folders picked in Account sync", isOn: $model.switchSyncEnabled)
                Text(model.syncSelection.count >= 2
                     ? "\(model.syncSelection.count) folders are picked. Each sync is backed up first."
                     : "Pick at least two folders in Account sync for this to do anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.switching || !model.switchSteps.isEmpty {
                Section("Last switch") {
                    ForEach(Array(model.switchSteps.enumerated()), id: \.offset) { _, s in Text(s).font(.callout) }
                    if model.switching { ProgressView().controlSize(.small) }
                }
            }
            Section {
                Text("Saved logins stay on this Mac in ~/Library/Application Support/ClaudeHelper/profiles (only your user can read it). They are copies of Claude's own encrypted login data and work only on this Mac. The helper never reads the Keychain and never shows or sends the login data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
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

struct AccountRow: View {
    let entry: AppModel.AccountEntry
    let switching: Bool
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                    if let n = entry.nickname { Text(n).foregroundStyle(.secondary) }
                    if entry.isActive { Text("signed in").font(.caption).foregroundStyle(.green) }
                }
                Text(status.text).font(.caption)
                    .foregroundStyle(status.warning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let onRename { Button("Rename", action: onRename) }
            if let onForget { Button("Forget", action: onForget).help("Delete the helper's saved copy of this login") }
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
