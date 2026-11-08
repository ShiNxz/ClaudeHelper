import AppKit
import SwiftUI
import UserNotifications

enum AppInfo {
    /// Shown in the window title, menus, alerts and notifications.
    static let name = "Relay"
}

extension Notification.Name {
    static let openHelperWindow = Notification.Name("openHelperWindow")
}

/// A chat title inside a message. The title is isolated from the sentence around it, so a right-to-left title
/// (Hebrew, Arabic) does not turn the whole message around.
func quoted(_ title: String) -> String { "\"\u{2068}" + title + "\u{2069}\"" }

/// macOS notifications, for messages that should reach the user when the helper's window is not in front
/// (after a switch from the menu bar, an automatic switch, or opening a chat in Claude). Falls back to the
/// in-window toast when notifications are turned off, or when the binary runs outside its app bundle.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    /// UNUserNotificationCenter needs a real app bundle; outside one it crashes.
    var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil && SelfCheck.outputDir == nil
    }

    func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for permission now (macOS asks once), so the first real notification is not lost to the prompt.
    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a notification, or call `fallback` when that is not possible.
    func post(title: String, body: String, fallback: @escaping @MainActor () -> Void) {
        guard available else { fallback(); return }
        // After the first answer this returns at once without asking again.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                onMainQueue { fallback() }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if error != nil { onMainQueue { fallback() } }
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show notifications even while the helper is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// Clicking a notification opens the helper's window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        onMainQueue { NotificationCenter.default.post(name: .openHelperWindow, object: nil) }
        completionHandler()
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let title: String?
    let text: String
    let warning: Bool
}

/// A short message at the bottom of the window that goes away by itself.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.warning ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                if let t = toast.title { Text(t).font(.callout.bold()) }
                Text(toast.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 520, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
    }
}
