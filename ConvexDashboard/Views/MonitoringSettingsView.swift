import SwiftUI

/// Connects the app to the user's self-hosted monitoring backend (`backend/` in the repo).
struct MonitoringSettingsView: View {
    @Environment(PulseSettings.self) private var pulseSettings
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var appKey = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var isConfirmingDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                if let client = pulseSettings.client {
                    ConvexSection("Connected") {
                        LabeledContent("Backend") {
                            Text(client.deploymentURL.host() ?? client.deploymentURL.absoluteString)
                                .font(.convexMono(.caption))
                        }
                        Button("Disconnect", role: .destructive) { isConfirmingDisconnect = true }
                    }
                    if case .signedIn(let session) = sessionStore.state,
                       let name = client.deploymentURL.host()?.components(separatedBy: ".").first {
                        BackendUsageSection(client: session.client, deploymentName: name)
                    }
                } else {
                    ConvexSection {
                        TextField("https://your-backend.convex.cloud", text: $urlString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.convexMono(.body))
                        SecureField("APP_KEY", text: $appKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.convexMono(.body))
                    } header: {
                        Eyebrow("Monitoring Backend")
                    } footer: {
                        Text("Deploy `backend/` from this app's repo to your own Convex account (`npx convex deploy`), set an APP_KEY env var, then enter its URL and key here. Your logs stay in your account.")
                    }

                    if let errorMessage {
                        ConvexSection {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.convexRed)
                        }
                    }

                    ConvexSection {
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                Text("Connect")
                                Spacer()
                                if isConnecting { ProgressView() }
                            }
                        }
                        .disabled(urlString.isEmpty || appKey.isEmpty || isConnecting)
                    }
                }
            }
            .convexScreenBackground()
            .navigationTitle("Monitoring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Disconnect monitoring backend?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { pulseSettings.disconnect() }
            } message: {
                Text("Existing log streams keep sending data to your backend. Turn monitoring off per deployment first to stop them.")
            }
        }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await pulseSettings.connect(urlString: urlString, appKey: appKey)
            appKey = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The backend's own usage and limits, so a noisy monitored app can't quietly run up its bill.
private struct BackendUsageSection: View {
    @State private var viewModel: BackendUsageViewModel
    private let client: ConvexAPIClient

    init(client: ConvexAPIClient, deploymentName: String) {
        self.client = client
        _viewModel = State(initialValue: BackendUsageViewModel(client: client, deploymentName: deploymentName))
    }

    var body: some View {
        ConvexSection {
            switch viewModel.state {
            case .loading:
                ProgressView()
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexSecondaryText)
            case .loaded(let deployment, let usage, let limits):
                ForEach(["functionCalls", "databaseIoGb"], id: \.self) { key in
                    if let metric = usage?.metrics[key] {
                        LabeledContent(UsageMetric.displayName(key)) {
                            Text("\(UsageMetric.format(metric.usage.currentMonth, unit: metric.unit)) this month")
                                .font(.convexMono(.caption))
                        }
                    }
                }
                NavigationLink {
                    DeploymentDetailView(deployment: deployment, client: client)
                } label: {
                    SettingsRow("Usage Limits", systemImage: "gauge.with.dots.needle.67percent",
                                tint: limitCount(limits) == 0 ? .convexYellow : .convexGreen) {
                        Text(limitsLabel(limits))
                    }
                }
            }
        } header: {
            Eyebrow("Backend Usage")
        } footer: {
            Text("Every event your monitored apps send runs a function on the backend. Add a usage limit so a noisy app can't run up its bill.")
        }
        .task { await viewModel.load() }
    }

    private func limitCount(_ limits: [UsageLimit]?) -> Int? {
        limits?.filter(\.enabled).count
    }

    private func limitsLabel(_ limits: [UsageLimit]?) -> String {
        switch limitCount(limits) {
        case nil: "Manage"
        case 0: "None set"
        case let count?: "\(count) active"
        }
    }
}
