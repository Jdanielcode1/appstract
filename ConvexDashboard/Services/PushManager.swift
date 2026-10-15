import Observation
import UIKit
import UserNotifications

/// Notification permission, the APNs device token, and taps on alert notifications.
@Observable @MainActor final class PushManager {
    static let shared = PushManager()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    private(set) var registrationError: String?
    /// Set when the user taps an alert notification; the UI switches to the Alerts tab.
    var openedAlertEventId: String?

    /// Debug builds get APNs sandbox tokens.
    static var isSandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Set `SUPPORTS_REMOTE_PUSH` in the build (and add the aps-environment entitlement) to enable APNs.
    static var supportsRemotePush: Bool {
        #if SUPPORTS_REMOTE_PUSH
        true
        #else
        false
        #endif
    }

    private init() {}

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        // Remote push is optional; builds without the aps-environment entitlement use local
        // notifications only (LocalAlertNotifier).
        if Self.supportsRemotePush, authorizationStatus == .authorized || authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func requestPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            registrationError = error.localizedDescription
        }
        await refreshAuthorizationStatus()
    }

    // MARK: Called from AppDelegate

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        registrationError = nil
    }

    func didFailToRegister(_ error: Error) {
        registrationError = error.localizedDescription
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushManager.shared.didFailToRegister(error) }
    }
}

/// iOS calls these on the main thread; `@preconcurrency` states that for the pre-Swift-6 protocol.
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// Show alerts as banners even while the app is open. Uses the completion-handler form,
    /// which UIKit always calls on the main thread.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let eventId = response.notification.request.content.userInfo["eventId"] as? String ?? ""
        MainActor.assumeIsolated { PushManager.shared.openedAlertEventId = eventId }
        completionHandler()
    }
}
