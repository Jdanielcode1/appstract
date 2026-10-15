import SwiftUI

/// "Enable monitoring" switch for one deployment.
struct MonitoringSection: View {
    @Environment(PulseSettings.self) private var pulseSettings
    @State private var viewModel: MonitoringViewModel
    @State private var isConfirmingEnable = false
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
            Text("Streams function calls, errors, and logs to your monitoring backend. Requires Convex Pro on this deployment.")
        }
        // Re-check whenever the backend connection changes.
        .task(id: pulseSettings.client?.deploymentURL) {
            await viewModel.refresh(pulse: pulseSettings.client)
        }
        .confirmationDialog("Enable monitoring?", isPresented: $isConfirmingEnable, titleVisibility: .visible) {
            Button("Enable") {
                guard let pulse = pulseSettings.client else { return }
                Task { await viewModel.enable(pulse: pulse) }
            }
        } message: {
            Text("This creates a webhook log stream on this deployment that sends every function call, error, and console log to your monitoring backend.")
        }
        .confirmationDialog("Turn off monitoring?", isPresented: $isConfirmingDisable, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { disable(deleteData: false) }
            Button("Turn Off and Delete Data", role: .destructive) { disable(deleteData: true) }
        } message: {
            Text("The log stream will be removed from this deployment.")
        }
        .sheet(isPresented: $isShowingSettings) {
            MonitoringSettingsView()
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
        case .off, .on:
            Toggle(isOn: Binding(
                get: { viewModel.status == .on },
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

            if viewModel.status == .on, let pulse = pulseSettings.client {
                NavigationLink {
                    FunctionsView(deploymentName: deploymentName, source: pulse)
                } label: {
                    Label("Function Health", systemImage: "waveform.path.ecg")
                }
                NavigationLink {
                    RecentErrorsView(deploymentName: deploymentName, source: pulse)
                } label: {
                    Label("Recent Errors", systemImage: "exclamationmark.octagon")
                }
                NavigationLink {
                    LogsView(deploymentName: deploymentName, source: pulse)
                } label: {
                    Label("Live Logs", systemImage: "text.alignleft")
                }
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
                    guard let pulse = pulseSettings.client else { return }
                    Task { await viewModel.repair(pulse: pulse) }
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
            Button("Turn Off Monitoring", role: .destructive) { isConfirmingDisable = true }
                .disabled(viewModel.isWorking)
        case .otherWebhookExists(let url):
            VStack(alignment: .leading, spacing: 4) {
                Label("Another webhook log stream is already configured.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.convexYellow)
                Text("Convex allows one webhook stream per deployment. Remove it in the Convex dashboard to use monitoring here.")
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
                Text(url)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .textSelection(.enabled)
            }
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

    private func disable(deleteData: Bool) {
        guard let pulse = pulseSettings.client else { return }
        Task { await viewModel.disable(pulse: pulse, deleteData: deleteData) }
    }
}
