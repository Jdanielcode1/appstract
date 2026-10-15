import SwiftUI

@main
struct ConvexDashboardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var sessionStore = SessionStore()
    @State private var pulseSettings = PulseSettings()
    @State private var appLock = AppLock.shared
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .dark
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ConvexAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sessionStore)
                .environment(pulseSettings)
                .overlay {
                    if appLock.isLocked { LockScreenView() }
                }
                .tint(.convexAccent)
                .preferredColorScheme(appearance.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                appLock.lock()
                LocalAlertNotifier.shared.scheduleBackgroundRefresh()
            case .active:
                Task { await appLock.promptIfNeeded() }
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(LocalAlertNotifier.backgroundTaskIdentifier)) {
            await LocalAlertNotifier.shared.checkInBackground()
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var sessionStore

    var body: some View {
        Group {
            switch sessionStore.state {
            case .loading:
                ProgressView("Connecting to Convex…")
                    .font(.convexMono(.footnote))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.convexBackground)
            case .signedOut:
                TokenEntryView()
            case .signedIn(let session):
                MainTabView(session: session)
                    // Rebuild the view tree (and its view models) when the token changes.
                    .id(session.tokenDetails.id)
            }
        }
        .task { await sessionStore.restore() }
    }
}

struct MainTabView: View {
    enum TabID: String, Hashable { case overview, projects, chat, alerts, settings }

    @Environment(PulseSettings.self) private var pulseSettings
    @State private var selection: TabID = Self.initialTab
    @State private var push = PushManager.shared
    let session: SessionStore.Session

    var body: some View {
        TabView(selection: $selection) {
            Tab("Overview", systemImage: "gauge.with.dots.needle.33percent", value: .overview) {
                OverviewView(session: session)
            }
            Tab("Projects", systemImage: "folder", value: .projects) {
                ProjectsView(session: session)
            }
            Tab("Ask AI", systemImage: "sparkles", value: .chat) {
                ChatTabView(session: session)
            }
            Tab("Alerts", systemImage: "bell", value: .alerts) {
                AlertsView()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView(session: session)
            }
        }
        // Tapping an alert notification opens the Alerts tab.
        .onChange(of: push.openedAlertEventId) { _, eventId in
            guard eventId != nil else { return }
            selection = .alerts
            push.openedAlertEventId = nil
        }
        .task { await push.refreshAuthorizationStatus() }
        // Local notifications for new alerts while the app is open.
        .task(id: pulseSettings.client?.deploymentURL) {
            guard let pulse = pulseSettings.client else { return }
            await LocalAlertNotifier.shared.run(pulse: pulse)
        }
        // Register this device with the backend whenever the token or backend changes.
        .task(id: DeviceRegistration(token: push.deviceToken, backend: pulseSettings.client?.deploymentURL)) {
            guard let token = push.deviceToken, let pulse = pulseSettings.client else { return }
            try? await pulse.registerDevice(token: token, sandbox: PushManager.isSandbox)
        }
    }

    /// Debug builds accept `-initialTab alerts` (etc.) as a launch argument, for screenshots.
    private static var initialTab: TabID {
        #if DEBUG
        UserDefaults.standard.string(forKey: "initialTab").flatMap(TabID.init(rawValue:)) ?? .overview
        #else
        .overview
        #endif
    }

    private struct DeviceRegistration: Equatable {
        let token: String?
        let backend: URL?
    }
}
