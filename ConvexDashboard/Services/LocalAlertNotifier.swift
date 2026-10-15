import BackgroundTasks
import Foundation
import UserNotifications

/// Turns new backend alert events into local notifications, so alerts work without an Apple
/// push key. Runs every 30s while the app is open and opportunistically via background refresh
/// (iOS decides when; typically every 15 min to a few hours, never after a force-quit).
@MainActor final class LocalAlertNotifier {
    static let shared = LocalAlertNotifier()
    static let backgroundTaskIdentifier = "com.dcantu.convexdashboard.alerts"
    static let foregroundInterval: Duration = .seconds(30)

    /// Newest `firedAt` already shown. Per-device convenience state, so UserDefaults is fine.
    private static let lastNotifiedKey = "lastNotifiedAlertFiredAt"
    private static let maxPerCheck = 5

    private init() {}

    /// Shows notifications for alert events fired since the last check.
    func check(pulse: PulseClient) async {
        let defaults = UserDefaults.standard
        guard let events = try? await pulse.alertEvents(limit: 20) else { return }

        // First run: start from now instead of replaying old alerts.
        guard defaults.object(forKey: Self.lastNotifiedKey) != nil else {
            defaults.set(Double(events.first?.firedAt ?? Int64(Date.now.timeIntervalSince1970 * 1000)), forKey: Self.lastNotifiedKey)
            return
        }
        let lastNotified = Int64(defaults.double(forKey: Self.lastNotifiedKey))
        let newEvents = events
            .filter { $0.firedAt > lastNotified }
            // Already delivered by Apple push to registered devices; avoid duplicates.
            .filter { ($0.deliveredCount ?? 0) == 0 }
            .sorted { $0.firedAt < $1.firedAt }
        guard let newest = events.map(\.firedAt).max(), newest > lastNotified else { return }
        defaults.set(Double(newest), forKey: Self.lastNotifiedKey)

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for event in newEvents.suffix(Self.maxPerCheck) {
            await schedule(id: event.id, title: event.title, body: event.body, thread: event.deploymentName, eventId: event.id)
        }
        let skipped = newEvents.count - Self.maxPerCheck
        if skipped > 0 {
            await schedule(id: "summary-\(newest)", title: "\(skipped) more alerts",
                           body: "Open Alerts to see everything that fired.", thread: "summary", eventId: nil)
        }
    }

    /// Shows one specific event immediately, regardless of the watermark (used by "Test").
    /// Returns false when notifications aren't allowed.
    func show(_ event: AlertEvent) async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        await schedule(id: event.id, title: event.title, body: event.body, thread: event.deploymentName, eventId: event.id)
        let defaults = UserDefaults.standard
        if Double(event.firedAt) > defaults.double(forKey: Self.lastNotifiedKey) {
            defaults.set(Double(event.firedAt), forKey: Self.lastNotifiedKey)
        }
        return true
    }

    /// Foreground polling loop; cancel the calling task to stop.
    func run(pulse: PulseClient) async {
        while !Task.isCancelled {
            await check(pulse: pulse)
            try? await Task.sleep(for: Self.foregroundInterval)
        }
    }

    /// Background refresh entry point: reads the backend from the Keychain since no UI is running.
    func checkInBackground() async {
        scheduleBackgroundRefresh()
        guard let pulse = PulseSettings.storedClient() else { return }
        await check(pulse: pulse)
    }

    /// Asks iOS to wake the app later. Safe to call repeatedly; the newest request replaces older ones.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func schedule(id: String, title: String, body: String, thread: String, eventId: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        if let eventId { content.userInfo = ["eventId": eventId] }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
