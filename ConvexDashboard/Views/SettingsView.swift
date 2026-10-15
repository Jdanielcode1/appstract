import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PulseSettings.self) private var pulseSettings
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .dark
    @State private var push = PushManager.shared
    @State private var appLock = AppLock.shared
    @AppStorage("aiSeesResults") private var aiSeesResults = true
    @AppStorage(AIRunMode.storageKey) private var aiRunMode: AIRunMode = .automatic
    @State private var isShowingMonitoringSettings = false
    @State private var isConfirmingSignOut = false

    let session: SessionStore.Session

    var body: some View {
        NavigationStack {
            List {
                ConvexSection {
                    AccountHeader(tokenDetails: session.tokenDetails)
                }

                ConvexSection("Appearance") {
                    AppearancePicker(selection: $appearance)
                }

                ConvexSection {
                    Toggle(isOn: Binding(get: { appLock.isEnabled },
                                         set: { enabled in Task { await appLock.setEnabled(enabled) } })) {
                        SettingsRow("Require \(AppLock.biometryName)", systemImage: "faceid", tint: .convexGreen)
                    }
                    .tint(Color.convexAccentFill)
                } header: {
                    Eyebrow("Security")
                } footer: {
                    Text(AppLock.canAuthenticate
                         ? "Locks the app at launch and whenever you leave it."
                         : "Set a device passcode in iOS Settings to lock the app.")
                }

                ConvexSection {
                    Button(action: showMonitoringSettings) {
                        SettingsRow("Monitoring Backend", systemImage: "waveform.path.ecg",
                                    tint: pulseSettings.isConfigured ? .convexGreen : .convexSecondaryText) {
                            Text(pulseSettings.client?.deploymentURL.host()?.components(separatedBy: ".").first ?? "Not connected")
                        }
                    }
                    Button(action: openNotificationSettings) {
                        SettingsRow("Notifications", systemImage: "bell.badge",
                                    tint: notificationsOn ? .convexRed : .convexSecondaryText) {
                            Text(notificationsLabel)
                        }
                    }
                } header: {
                    Eyebrow("Monitoring")
                } footer: {
                    Text("Your self-hosted backend powers function health, logs, alerts, and Ask AI.")
                }

                ConvexSection {
                    Toggle(isOn: $aiSeesResults) {
                        SettingsRow("AI can see results", systemImage: "eye", tint: .convexAccent)
                    }
                    .tint(Color.convexAccentFill)
                    Picker(selection: $aiRunMode) {
                        ForEach(AIRunMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        SettingsRow("Run AI queries", systemImage: "play.circle", tint: .convexGreen)
                    }
                } header: {
                    Eyebrow("Ask AI")
                } footer: {
                    Text((aiSeesResults
                         ? "The AI sees up to 20 rows of each query result to check and summarize its answer, and the values of status-like fields when building a data catalog."
                         : "The AI only sees row counts and field names, never your data. Answers are checked less.")
                         + " Queries always run read-only on this phone, at most 10,000 documents each on production (25,000 on dev). Past chats show saved results; nothing reruns until you tap Refresh.")
                }

                ConvexSection {
                    Link(destination: URL(string: "https://dashboard.convex.dev")!) {
                        SettingsRow("Convex Dashboard", systemImage: "safari", tint: .convexBlue) {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    Link(destination: URL(string: "https://docs.convex.dev")!) {
                        SettingsRow("Convex Docs", systemImage: "book", tint: .convexYellow) {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    SettingsRow("Version", systemImage: "info", tint: .convexSecondaryText) {
                        Text(Self.appVersion)
                    }
                } header: {
                    Eyebrow("About")
                } footer: {
                    Text("Unofficial app, not affiliated with Convex. Fonts: Kanit and IBM Plex Mono (SIL Open Font License).")
                }

                ConvexSection {
                    Button(role: .destructive, action: confirmSignOut) {
                        Text("Disconnect")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .convexScreenBackground()
            .navigationTitle("Settings")
            .toolbar { LogoToolbarItem() }
            .task { await push.refreshAuthorizationStatus() }
            .sheet(isPresented: $isShowingMonitoringSettings) {
                MonitoringSettingsView()
            }
            .confirmationDialog("Disconnect from Convex?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { sessionStore.signOut() }
            } message: {
                Text("The access token will be removed from this device.")
            }
        }
    }

    private var notificationsOn: Bool {
        [.authorized, .provisional, .ephemeral].contains(push.authorizationStatus)
    }

    private var notificationsLabel: String {
        switch push.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Not set"
        }
    }

    private func showMonitoringSettings() {
        isShowingMonitoringSettings = true
    }

    private func confirmSignOut() {
        isConfirmingSignOut = true
    }

    /// iOS manages notification permission; ask first if never asked, otherwise open iOS Settings.
    private func openNotificationSettings() {
        if push.authorizationStatus == .notDetermined {
            Task { await push.requestPermission() }
        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}

private struct AccountHeader: View {
    let tokenDetails: TokenDetails

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: "key.fill", tint: .convexAccent, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(scopeLabel)
                Text(tokenDetails.name)
                    .font(.convexDisplay(.title3, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Text("Created \(tokenDetails.createTime.dateFromMillis, format: .dateTime.month().day().year())")
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var scopeLabel: String {
        switch tokenDetails.scope {
        case .team: "Team access token"
        case .project: "Project access token"
        }
    }
}

/// Dark / Light / System as tappable swatches previewing each palette.
private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppearanceMode.allCases) { mode in
                AppearanceSwatch(mode: mode, isSelected: mode == selection) {
                    selection = mode
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AppearanceSwatch: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 64)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Color.convexAccentFill : Color.convexHairline,
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                HStack(spacing: 4) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.convexAccentFill : Color.convexSecondaryText)
                    Text(mode.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.convexText)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.label) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Mini mock of a screen: background, a card, and an accent line, in that mode's colors.
    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .dark:
            SwatchPreview(scheme: .dark)
        case .light:
            SwatchPreview(scheme: .light)
        case .system:
            HStack(spacing: 0) {
                SwatchPreview(scheme: .light)
                SwatchPreview(scheme: .dark)
            }
        }
    }
}

private struct SwatchPreview: View {
    let scheme: ColorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.convexBackground
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color.convexAccent).frame(width: 22, height: 5)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.convexSurface)
                    .frame(height: 22)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.convexText.opacity(0.6)).frame(width: 18, height: 3).padding(.leading, 5)
                    }
            }
            .padding(8)
        }
        .environment(\.colorScheme, scheme)
    }
}
