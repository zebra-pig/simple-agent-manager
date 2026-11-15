// Push notifications: hand the APNs device token to the core (which registers it
// with the server while signed in) and open the tapped notification's session.

import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor enum Push {
    /// Set by `AppModel`; the core that registers the token.
    static weak var core: App?
    static let delegate = PushDelegate()

    /// Ask once for permission, then register (the OS calls back with the token).
    /// Safe to call on every launch: the token is re-registered, which keeps it fresh.
    static func enable() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    static func received(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let sandbox = true // development-signed builds get sandbox tokens
        #else
        let sandbox = false
        #endif
        guard let core else { return }
        Task { await core.setPushToken(token: PushToken(platform: .apns, token: token, sandbox: sandbox)) }
    }
}

/// Tapped notifications, waiting for the navigation stack to open them.
@MainActor @Observable final class PushRouter {
    static let shared = PushRouter()
    var pending: SessionRef?
}

final class PushDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Show banners while the app is open too, as the web app does.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// The server sends `projectId` and `sessionId` next to `aps`
    /// (apps/api/src/durable-objects/notification-native-push.ts).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let projectId = info["projectId"] as? String, let sessionId = info["sessionId"] as? String else { return }
        await MainActor.run { PushRouter.shared.pending = SessionRef(projectId: projectId, sessionId: sessionId) }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = Push.delegate
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.received(deviceToken: deviceToken)
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = Push.delegate
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.received(deviceToken: deviceToken)
    }
}
#endif
