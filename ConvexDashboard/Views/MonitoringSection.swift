import SwiftUI

/// Monitoring for one deployment: one toggle; instant errors on Convex Pro, 5-minute checks otherwise.
struct MonitoringSection: View {
    @Environment(PulseSettings.self) private var pulseSettings
    @State private var viewModel: MonitoringViewModel
    @State private var isConfirmingEnable = false
    @State private var isConfirmingInstant = false
    @State private var isConfirmingStopInstant = false
    @State private var isConfirmingDisable = false
    @State private var isShowingSettings = false
    private let deploymentName: String

    init(deployment: Deployment, client: ConvexAPIClient) {
        deploymentName = deployment.name
        _viewModel = State(initialValue: MonitoringViewModel(deployment: deployment, client: client))
    }

    var body: some View {
        ConvexSection {
            content
            if let error = viewModel.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.convexRed)
            }
        } header: {
            Eyebrow("Monitoring")
        } footer: {
            Text(footer)
        }
        // Re-check whenever the backend connection changes.
        .task(id: pulseSettings.client?.deploymentURL) {
            await viewModel.refresh(pulse: pulseSettings.client)
        }
        .confirmationDialog("Enable monitoring?", isPresented: $isConfirmingEnable, titleVisibility: .visible) {
            Button("Enable") { run { await viewModel.enable(pulse: $0) } }
        } message: {
            Text("Your monitoring backend tracks this deployment's calls and errors and sends alerts. On Convex Pro, errors arrive instantly through a log stream; on other plans, counts update every 5 minutes.")
        }
        .confirmationDialog("Turn on instant errors?", isPresented: $isConfirmingInstant, titleVisibility: .visible) {
            Button("Turn On") { run { await viewModel.addInstantErrors(pulse: $0) } }
        } message: {
            Text("Adds a log stream that sends every call, error and console log to your backend as it happens: error messages, latency, and new-error, log and deploy alerts. Needs Convex Pro. Backend usage grows with this app's traffic.")
        }
        .confirmationDialog("Turn off instant errors?", isPresented: $isConfirmingStopInstant, titleVisibility: .visible) {
            Button("Turn Off Instant Errors") { run { await viewModel.removeInstantErrors(pulse: $0) } }
        } message: {
            Text("Removes the log stream to save backend usage. Calls and errors keep updating every 5 minutes. Collected data is kept.")
        }
        .confirmationDialog("Turn off monitoring?", isPresented: $isConfirmingDisable, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { disable(deleteData: false) }
            Button("Turn Off and Delete Data", role: .destructive) { disable(deleteData: true) }
        } message: {
            Text("Your backend stops collecting data for this deployment.")
        }
        .sheet(isPresented: $isShowingSettings) {
            MonitoringSettingsView()
        }
    }

    private var footer: String {
        switch viewModel.status {
        case .lite:
            "Calls and errors update every 5 minutes. Instant errors need Convex Pro. Live Logs (above) shows calls as they happen."
        case .on, .streamFailed:
            "Instant: errors, logs and latency arrive as they happen."
        default:
            "Tracks calls and errors and sends alerts: instantly on Convex Pro, every 5 minutes on other plans."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .checking:
            ProgressView()
        case .backendNotConfigured:
            Button("Set Up Monitoring Backend…") { isShowingSettings = true }
        case .isMonitoringBackend:
            Label("This is your monitoring backend.", systemImage: "info.circle")
                .foregroundStyle(Color.convexSecondaryText)
        case .off, .lite, .on:
            Toggle(isOn: Binding(
                get: { viewModel.status.isEnabled },
                set: { isOn in
                    if isOn { isConfirmingEnable = true } else { isConfirmingDisable = true }
                }
            )) {
                HStack {
                    Text("Enable Monitoring")
                    if viewModel.isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isWorking)

            if case .lite(let error?) = viewModel.status {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color.convexYellow)
                    Button("Reconnect") { run { await viewModel.reconnect(pulse: $0) } }
                        .disabled(viewModel.isWorking)
                }
                .padding(.vertical, 2)
            }
            if viewModel.status.isEnabled {
                links
            }
            if case .lite = viewModel.status {
                instantErrorsOption
            }
            if viewModel.status == .on {
                Button("Turn Off Instant Errors…") { isConfirmingStopInstant = true }
                    .disabled(viewModel.isWorking)
            }
        case .streamFailed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Convex stopped sending events to your backend.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.convexYellow)
                Text(reason)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                    .textSelection(.enabled)
                Button {
                    run { await viewModel.repair(pulse: $0) }
                } label: {
                    HStack {
                        Text("Repair")
                        if viewModel.isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isWorking)
            }
            .padding(.vertical, 2)
            Button("Use 5-Minute Checks Instead") { run { await viewModel.removeInstantErrors(pulse: $0) } }
                .disabled(viewModel.isWorking)
            Button("Turn Off Monitoring", role: .destructive) { isConfirmingDisable = true }
                .disabled(viewModel.isWorking)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.convexYellow)
                Button("Retry") {
                    Task { await viewModel.refresh(pulse: pulseSettings.client) }
                }
            }
        }
    }

    @ViewBuilder
    private var links: some View {
        if let pulse = pulseSettings.client {
            let isFull = viewModel.status == .on
            NavigationLink {
                FunctionsView(deploymentName: deploymentName, source: pulse, hasDetails: isFull)
            } label: {
                Label("Function Health", systemImage: "waveform.path.ecg")
            }
            // Live Logs (straight from Convex) is under Health for every deployment.
            if isFull {
                NavigationLink {
                    RecentErrorsView(deploymentName: deploymentName, source: pulse)
                } label: {
                    Label("Saved Errors", systemImage: "exclamationmark.octagon")
                }
                NavigationLink {
                    LogsView(deploymentName: deploymentName, source: pulse)
                } label: {
                    Label("Saved Logs", systemImage: "text.alignleft")
                }
            }
        }
    }

    /// 5-minute checks → instant errors. Convex allows one webhook stream per deployment.
    @ViewBuilder
    private var instantErrorsOption: some View {
        if let url = viewModel.otherWebhookURL {
            VStack(alignment: .leading, spacing: 4) {
                Text("Instant errors need this deployment's webhook log stream, which already points elsewhere:")
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
                Text(url)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .textSelection(.enabled)
            }
        } else {
            if let reason = viewModel.instantErrorsUnavailable {
                Text("Instant errors unavailable: \(reason)")
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Button {
                isConfirmingInstant = true
            } label: {
                Label("Turn On Instant Errors…", systemImage: "bolt")
            }
            .disabled(viewModel.isWorking)
        }
    }

    private func run(_ action: @escaping @MainActor (PulseClient) async -> Void) {
        guard let pulse = pulseSettings.client else { return }
        Task { await action(pulse) }
    }

    private func disable(deleteData: Bool) {
        run { await viewModel.disable(pulse: $0, deleteData: deleteData) }
    }
}
