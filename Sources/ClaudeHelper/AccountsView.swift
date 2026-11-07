import HelperCore
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var renaming: LoginProfile?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Save the account Claude is signed in to now, then use Add Another Account to log in to the next one and save it too. After that you can switch between saved accounts from the menu bar without logging in again. Don't use Log out inside Claude for this: logging out can end that login on the server.")
                    .foregroundStyle(.secondary)
            }
            Section("Signed in now") {
                HStack {
                    if let id = model.snapshot?.activeAccountId {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.email(forAccount: id) ?? "Account " + String(id.prefix(8)))
                            Text(model.activeProfile.map { "Saved as " + $0.name } ?? "Not saved yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Claude does not look signed in.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("", text: $newName, prompt: Text(model.activeProfile?.name ?? model.email(forAccount: model.snapshot?.activeAccountId) ?? "Name, e.g. Work"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button(model.activeProfile == nil ? "Save This Login" : "Save Again") {
                        model.saveCurrentLogin(name: newName.isEmpty
                            ? (model.activeProfile?.name ?? model.email(forAccount: model.snapshot?.activeAccountId) ?? "")
                            : newName)
                        newName = ""
                    }
                    .disabled(model.snapshot?.activeAccountId == nil || model.switching)
                }
            }
            Section {
                if model.profiles.isEmpty {
                    Text("No saved accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(model.profiles) { p in
                    ProfileRow(profile: p, email: model.email(forAccount: p.accountId), active: p.id == model.activeProfile?.id,
                               onSwitch: { model.confirmAndSwitch(p) },
                               onRename: { renaming = p; renameText = p.name },
                               onDelete: { model.deleteProfile(p) })
                }
            } header: {
                HStack {
                    Text("Saved accounts")
                    Spacer()
                    Button("Add Another Account...") { model.confirmAndAddAccount() }
                        .disabled(model.switching)
                        .help("Saves this login, then reopens Claude signed out so you can log in to another account")
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
                Text("Rename saved account").font(.headline)
                TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { model.renameProfile(p, to: renameText); renaming = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }
}

struct ProfileRow: View {
    let profile: LoginProfile
    let email: String?
    let active: Bool
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var detailText: String {
        var who = ""
        if let email {
            if email != profile.name { who = email + ", " }
        } else {
            who = "Account " + String((profile.accountId ?? "unknown").prefix(8)) + ", "
        }
        return who + "saved " + profile.savedAt.formatted(date: .abbreviated, time: .shortened) + ", " + expiryText
    }

    var expiryText: String {
        guard let e = profile.sessionExpires else { return "login expiry unknown" }
        return (profile.isExpired ? "login expired " : "login valid until ") + e.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                    if active { Text("signed in").font(.caption).foregroundStyle(.green) }
                }
                Text(detailText)
                    .font(.caption).foregroundStyle(profile.isExpired ? .orange : .secondary)
            }
            Spacer()
            Button("Rename", action: onRename)
            Button("Delete", action: onDelete)
            Button("Switch", action: onSwitch).disabled(active || profile.isExpired)
        }
    }
}
