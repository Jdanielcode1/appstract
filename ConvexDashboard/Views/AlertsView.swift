import SwiftUI
import UserNotifications

/// Alert history, alert rules, and notification setup.
struct AlertsView: View {
    @Environment(PulseSettings.self) private var pulseSettings
    @State private var viewModel = AlertsViewModel()
    @State private var editingRule: AlertRule?
    @State private var isShowingBackendSetup = false

    var body: some View {
        NavigationStack {
            Group {
                if let pulse = pulseSettings.client {
                    AlertsList(viewModel: viewModel, pulse: pulse, editingRule: $editingRule)
                        .task(id: pulse.deploymentURL) { await viewModel.autoRefresh(pulse: pulse) }
                } else {
                    NoBackendView(onConnect: showBackendSetup)
                }
            }
            .navigationTitle("Alerts")
            .toolbar { LogoToolbarItem() }
            .sheet(item: $editingRule) { rule in
                if let pulse = pulseSettings.client {
                    RuleEditorView(rule: rule, deployments: viewModel.deployments) { saved in
                        try await viewModel.save(saved, pulse: pulse)
                    }
                }
            }
            .sheet(isPresented: $isShowingBackendSetup) {
                MonitoringSettingsView()
            }
        }
    }

    private func showBackendSetup() {
        isShowingBackendSetup = true
    }
}

private struct NoBackendView: View {
    let onConnect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Monitoring Backend", systemImage: "bell.slash")
        } description: {
            Text("Alerts are detected by your self-hosted monitoring backend. Connect it to set up rules and get notified.")
        } actions: {
            Button("Connect Backend", action: onConnect)
                .buttonStyle(.borderedProminent)
                .tint(.convexAccentFill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.convexBackground)
    }
}

private struct AlertsList: View {
    let viewModel: AlertsViewModel
    let pulse: PulseClient
    @Binding var editingRule: AlertRule?

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
                    .listRowBackground(Color.convexSurface)
            }

            ConvexSection {
                NotificationStatusCard(viewModel: viewModel, pulse: pulse)
            }

            ConvexSection {
                if viewModel.rules.isEmpty && viewModel.hasLoaded {
                    EmptyRulesCard(onAdd: addRecommended)
                }
                ForEach(viewModel.rules) { rule in
                    RuleRow(rule: rule, onToggle: { toggle(rule, enabled: $0) }, onEdit: { editingRule = rule })
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(rule) }
                        }
                }
                AddRuleMenu(onSelect: addRule)
            } header: {
                HStack {
                    Eyebrow("Rules")
                    Spacer()
                    if !viewModel.rules.isEmpty {
                        Eyebrow("\(viewModel.enabledRuleCount) of \(viewModel.rules.count) on")
                    }
                }
            }

            if viewModel.events.isEmpty && viewModel.hasLoaded {
                ConvexSection("History") {
                    Text("Nothing has fired yet. Alerts show up here even when notifications are off.")
                        .font(.callout)
                        .foregroundStyle(Color.convexSecondaryText)
                        .padding(.vertical, 6)
                }
            } else if viewModel.availableCategories.count > 2 {
                // Only worth filtering when there are at least two kinds of alerts.
                ConvexSection("History") {
                    ChipBar(items: viewModel.availableCategories.map { ChipBar.Item(id: $0.category, title: $0.category.rawValue, count: $0.count) },
                            selection: $viewModel.category)
                }
            }

            ForEach(viewModel.sections) { section in
                ConvexSection(section.title) {
                    ForEach(section.events) { event in
                        NavigationLink {
                            AlertEventDetailView(event: event, pulse: pulse)
                        } label: {
                            AlertEventRow(event: event)
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .overlay {
            if !viewModel.hasLoaded {
                ProgressView()
            }
        }
        .refreshable { await viewModel.load(pulse: pulse) }
    }

    private func addRule(_ kind: AlertRule.Kind) {
        editingRule = .new(kind)
    }

    private func addRecommended() {
        Task { await viewModel.addRecommendedRules(pulse: pulse) }
    }

    private func toggle(_ rule: AlertRule, enabled: Bool) {
        Task { await viewModel.setEnabled(rule, enabled: enabled, pulse: pulse) }
    }

    private func delete(_ rule: AlertRule) {
        Task { await viewModel.delete(rule, pulse: pulse) }
    }
}

/// Inline "Add rule" row; a menu of rule kinds with their descriptions.
private struct AddRuleMenu: View {
    let onSelect: (AlertRule.Kind) -> Void

    var body: some View {
        Menu {
            ForEach(AlertRule.Kind.allCases) { kind in
                Button {
                    onSelect(kind)
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                    Text(kind.summary)
                }
            }
        } label: {
            HStack(spacing: 12) {
                IconTile(systemImage: "plus", tint: .convexAccent)
                Text("Add Rule")
                    .foregroundStyle(Color.convexAccent)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
    }
}

/// One compact card: notification state, how alerts are delivered, and a test button.
private struct NotificationStatusCard: View {
    @State private var push = PushManager.shared
    let viewModel: AlertsViewModel
    let pulse: PulseClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(systemImage: isAllowed ? "bell.badge.fill" : "bell.slash.fill",
                         tint: isAllowed ? .convexGreen : .convexYellow, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isAllowed ? "Notifications on" : "Notifications off")
                        .font(.convexDisplay(.headline, weight: .medium))
                        .foregroundStyle(Color.convexText)
                    Text(subtitle)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                actionButton
            }
            if let message = viewModel.testMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
                    .padding(.leading, 52)
            }
        }
        .padding(.vertical, 6)
        .task { await push.refreshAuthorizationStatus() }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch push.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Button(action: sendTest) {
                if viewModel.isSendingTest {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isSendingTest)
        case .denied:
            Button("Settings", action: openSystemSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
        default:
            Button("Enable", action: requestPermission)
                .buttonStyle(.borderedProminent)
                .tint(.convexAccentFill)
                .controlSize(.small)
        }
    }

    private var isAllowed: Bool {
        [.authorized, .provisional, .ephemeral].contains(push.authorizationStatus)
    }

    /// Apple push only when the build supports it, this device registered, and the backend has a key.
    private var usesRemotePush: Bool {
        PushManager.supportsRemotePush && push.deviceToken != nil && viewModel.status?.pushConfigured == true
    }

    private var subtitle: String {
        switch push.authorizationStatus {
        case .denied: "Turned off in iOS Settings"
        case .notDetermined: "Allow to get alerts on this phone"
        default: usesRemotePush ? "Instant · Apple push" : "Local · every 30s while open"
        }
    }

    private func requestPermission() {
        Task { await push.requestPermission() }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func sendTest() {
        Task { await viewModel.sendTest(pulse: pulse) }
    }
}

private struct EmptyRulesCard: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No rules yet")
                .font(.convexDisplay(.headline, weight: .medium))
                .foregroundStyle(Color.convexText)
            Text("Start with alerts for any new error and for error rates above 5%.")
                .font(.callout)
                .foregroundStyle(Color.convexSecondaryText)
            Button("Add Recommended Rules", action: onAdd)
                .buttonStyle(.borderedProminent)
                .tint(.convexAccentFill)
        }
        .padding(.vertical, 6)
    }
}

extension AlertRule.Kind {
    var tint: Color {
        switch self {
        case .newError: .convexRed
        case .errorRate: .convexYellow
        case .schedulerLag: .convexBlue
        case .logMatch: .convexAccent
        case .deploy: .convexGreen
        }
    }
}

private struct RuleRow: View {
    let rule: AlertRule
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    IconTile(systemImage: rule.kind.systemImage, tint: rule.kind.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.kind.title)
                            .font(.convexDisplay(.headline, weight: .medium))
                            .foregroundStyle(Color.convexText)
                        Text(rule.detail)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexSecondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits the rule")

            Toggle(rule.kind.title, isOn: Binding(get: { rule.enabled }, set: onToggle))
                .labelsHidden()
                .tint(.convexAccentFill)
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

struct AlertEventRow: View {
    let event: AlertEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: event.systemImage, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.convexText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(event.firedAt.dateFromMillis, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.convexMono(.caption2))
                        .foregroundStyle(Color.convexSecondaryText)
                }
                Text(event.body)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(3)
                if let problem = deliveryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Color.convexYellow)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        if event.kind == "test" { return .convexSecondaryText }
        return AlertRule.Kind(rawValue: event.kind)?.tint ?? .convexRed
    }

    /// Hide the expected "no push" reasons; with local delivery they aren't problems.
    private var deliveryProblem: String? {
        guard let error = event.deliveryError,
              !error.hasPrefix("Push not configured"), error != "No devices registered" else { return nil }
        return error
    }
}
