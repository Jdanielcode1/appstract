import SwiftUI

struct DeploymentDetailView: View {
    @State private var viewModel: DeploymentDetailViewModel
    @State private var isShowingClasses = false
    @State private var isConfirmingPause = false
    /// The limit being edited; `nil` id means a new one.
    @State private var editingLimit: LimitDraft?
    /// Last-hour charts (official deployment metrics); nil when the deployment has no URL.
    @State private var metrics: DeploymentMetricsViewModel?
    private let client: ConvexAPIClient

    init(deployment: Deployment, client: ConvexAPIClient) {
        self.client = client
        _viewModel = State(initialValue: DeploymentDetailViewModel(deployment: deployment, client: client))
        _metrics = State(initialValue: deployment.deploymentUrl.flatMap(URL.init(string:)).map {
            DeploymentMetricsViewModel(deployment: deployment, deploymentURL: $0, client: client)
        })
    }

    private var deployment: Deployment { viewModel.deployment }

    var body: some View {
        List {
            if viewModel.isPaused {
                PausedBanner(state: viewModel.state, isChanging: viewModel.isChanging, onResume: resume)
            }
            if let metrics {
                MetricsSummarySection(viewModel: metrics)
            }
            infoSection
            dataSection
            healthSection
            MonitoringSection(deployment: deployment, client: client)
            usageSection
            limitsSection
            envVarsSection
            controlsSection
        }
        .convexScreenBackground()
        .navigationTitle(deployment.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            let charts = Task { await metrics?.load() }
            await viewModel.load()
            await charts.value
        }
        .task { await viewModel.load() }
        // Polls while visible; pausing when All Metrics is pushed (it polls the same model).
        .task { await metrics?.autoRefresh() }
        .sheet(isPresented: $isShowingClasses) {
            DeploymentClassesView(current: deployment.class ?? "")
        }
        .sheet(item: $editingLimit) { draft in
            UsageLimitEditor(draft: draft, usage: loadedUsage, viewModel: viewModel)
        }
        .confirmationDialog("Pause \(deployment.name)?", isPresented: $isConfirmingPause, titleVisibility: .visible) {
            Button("Pause Deployment", role: .destructive, action: pause)
        } message: {
            Text(pauseWarning)
        }
        .alert("Couldn't make that change", isPresented: changeErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.changeError ?? "")
        }
    }

    private var pauseWarning: String {
        let impact = "New function calls will fail, scheduled jobs wait until you resume, and crons are skipped. Data is kept, and calls and bandwidth aren't billed while paused."
        return deployment.deploymentType == "prod" ? "This is production: your app stops working until you resume. \(impact)" : impact
    }

    private var changeErrorBinding: Binding<Bool> {
        Binding(get: { viewModel.changeError != nil }, set: { if !$0 { viewModel.changeError = nil } })
    }

    private var loadedUsage: CurrentUsage? {
        if case .loaded(let usage) = viewModel.usage { return usage }
        return nil
    }

    /// Pause / resume (official Deployment API). Pausing always asks first.
    @ViewBuilder
    private var controlsSection: some View {
        if case .loaded = viewModel.state {
            ConvexSection {
                if viewModel.isPaused {
                    Button(action: resume) {
                        Label("Resume Deployment", systemImage: "play.circle")
                    }
                    .disabled(viewModel.isChanging)
                } else {
                    Button(role: .destructive, action: confirmPause) {
                        Label("Pause Deployment", systemImage: "pause.circle")
                            .foregroundStyle(Color.convexRed)
                    }
                    .disabled(viewModel.isChanging)
                }
            } header: {
                Eyebrow("Controls")
            } footer: {
                Text("Pausing is an emergency stop: function calls fail until you resume. Nothing is deleted.")
            }
        }
    }

    private func confirmPause() {
        isConfirmingPause = true
    }

    private func pause() {
        Task { await viewModel.setPaused(true) }
    }

    private func resume() {
        Task { await viewModel.setPaused(false) }
    }

    private func addLimit() {
        editingLimit = LimitDraft(limitID: nil, config: .new)
    }

    private func edit(_ limit: UsageLimit) {
        editingLimit = LimitDraft(limitID: limit.id, config: UsageLimitConfig(limit))
    }

    /// Read-only table browser, schedules, and audit log, via the deployment's system queries.
    @ViewBuilder
    private var dataSection: some View {
        if let urlString = deployment.deploymentUrl, let url = URL(string: urlString) {
            ConvexSection("Data & Activity") {
                NavigationLink {
                    DataBrowserView(deploymentURL: url, client: client)
                } label: {
                    SettingsRow("Tables", systemImage: "tablecells", tint: .convexBlue) {
                        Text("Read-only")
                    }
                }
                NavigationLink {
                    ChatView(deployment: deployment, deploymentURL: url, client: client)
                } label: {
                    SettingsRow("Ask AI", systemImage: "sparkles", tint: .convexAccent) {
                        Text("Chat with your data")
                    }
                }
                NavigationLink {
                    QueryRunnerView(deploymentName: deployment.name, deploymentURL: url, client: client)
                } label: {
                    SettingsRow("Run Query", systemImage: "play.rectangle", tint: .convexBlue) {
                        Text("Read-only")
                    }
                }
                NavigationLink {
                    SchedulesView(deploymentURL: url, client: client)
                } label: {
                    SettingsRow("Schedules & Crons", systemImage: "clock.badge.checkmark", tint: .convexGreen)
                }
                NavigationLink {
                    HistoryView(deployment: deployment, deploymentURL: url, client: client)
                } label: {
                    SettingsRow("History", systemImage: "clock.arrow.circlepath", tint: .convexYellow) {
                        Text("Deploys & changes")
                    }
                }
            }
        }
    }

    /// Official Convex insights (read limits, write conflicts) and live logs — no monitoring backend needed.
    private var healthSection: some View {
        ConvexSection("Health") {
            if let urlString = deployment.deploymentUrl, let url = URL(string: urlString) {
                NavigationLink {
                    LiveLogsView(deploymentURL: url, client: client)
                } label: {
                    SettingsRow("Live Logs", systemImage: "dot.radiowaves.left.and.right", tint: .convexGreen) {
                        Text("Calls & errors")
                    }
                }
            }
            NavigationLink {
                InsightsView(deployment: deployment, client: client)
            } label: {
                SettingsRow("Insights", systemImage: "stethoscope", tint: .convexAccent) {
                    Text("72h")
                }
            }
        }
    }

    private func showClasses() {
        isShowingClasses = true
    }

    private var infoSection: some View {
        ConvexSection("Deployment") {
            LabeledContent("Type", value: deployment.typeLabel)
            LabeledContent("Status") {
                switch viewModel.state {
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Unknown")
                case .loaded(let state):
                    Label(state.capitalized, systemImage: state == "running" ? "circle.fill" : "pause.circle.fill")
                        .labelStyle(StatusLabelStyle())
                        .foregroundStyle(state == "running" ? Color.convexGreen : Color.convexYellow)
                }
            }
            if let region = deployment.region {
                LabeledContent("Region", value: region)
            }
            if let deploymentClass = deployment.class {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(deploymentClass.uppercased())
                            .font(.convexMono(.body, weight: .medium))
                        Button(action: showClasses) {
                            Image(systemName: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(Color.convexSecondaryText)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("About deployment classes")
                    }
                } label: {
                    Text("Class")
                }
            }
            if let url = deployment.deploymentUrl {
                LabeledContent("URL") {
                    Text(url)
                        .font(.convexMono(.caption))
                        .textSelection(.enabled)
                }
            }
            if let lastDeploy = deployment.lastDeployTime {
                LabeledContent("Last Deploy", value: lastDeploy.dateFromMillis.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        ConvexSection {
            switch viewModel.usage {
            case .loading:
                ProgressView()
            case .failed(let message):
                SectionError(message: message)
            case .loaded(let usage):
                ForEach(usage.metrics.keys.sorted(), id: \.self) { key in
                    if let metric = usage.metrics[key] {
                        UsageRow(key: key, metric: metric)
                    }
                }
            }
        } header: {
            Eyebrow("Usage")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if case .loaded(let usage) = viewModel.usage, usage.seedStatus != "complete" {
                    Text("Usage is still being calculated and may be understated.")
                }
                Text(ConvexReference.usageWindowsNote)
            }
        }
    }

    @ViewBuilder
    private var limitsSection: some View {
        ConvexSection {
            switch viewModel.limits {
            case .loading:
                ProgressView()
            case .failed(let message):
                SectionError(message: message)
            case .loaded(let limits):
                ForEach(limits) { limit in
                    Button {
                        edit(limit)
                    } label: {
                        UsageLimitRow(limit: limit, usage: loadedUsage)
                    }
                }
                Button(action: addLimit) {
                    Label("Add Usage Limit", systemImage: "plus")
                }
                .disabled(viewModel.isChanging)
            }
        } header: {
            Eyebrow("Usage Limits")
        } footer: {
            Text("A warning limit notifies your team; a disable limit pauses the deployment when it's reached.")
        }
    }

    /// Collapsed to a single row so secrets aren't on screen by default.
    private var envVarsSection: some View {
        ConvexSection {
            NavigationLink {
                EnvironmentVariablesView(deploymentName: deployment.name, envVars: viewModel.envVars)
            } label: {
                LabeledContent {
                    switch viewModel.envVars {
                    case .loading: ProgressView()
                    case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.convexYellow)
                    case .loaded(let vars): Text("\(vars.count)")
                    }
                } label: {
                    Label("Environment Variables", systemImage: "lock.rectangle.stack")
                }
            }
        }
    }
}

/// Environment variable names, with each value hidden until tapped.
struct EnvironmentVariablesView: View {
    let deploymentName: String
    let envVars: DeploymentDetailViewModel.Section<[(name: String, value: String)]>
    @State private var revealed: Set<String> = []

    var body: some View {
        List {
            switch envVars {
            case .loading:
                ProgressView()
            case .failed(let message):
                SectionError(message: message)
            case .loaded(let vars) where vars.isEmpty:
                Text("No environment variables.")
                    .foregroundStyle(Color.convexSecondaryText)
            case .loaded(let vars):
                ConvexSection {
                    ForEach(vars, id: \.name) { envVar in
                        let isRevealed = revealed.contains(envVar.name)
                        Button {
                            if isRevealed { revealed.remove(envVar.name) } else { revealed.insert(envVar.name) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(envVar.name)
                                    .font(.convexMono(.body))
                                    .foregroundStyle(Color.convexText)
                                Text(isRevealed ? envVar.value : "••••••••")
                                    .font(.convexMono(.caption))
                                    .foregroundStyle(Color.convexSecondaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } footer: {
                    Text("Tap a variable to reveal its value.")
                }
            }
        }
        .convexScreenBackground()
        .navigationTitle("Environment Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !revealed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hide All") { revealed.removeAll() }
                }
            }
        }
        // Never leave values revealed when coming back to this screen.
        .onDisappear { revealed.removeAll() }
    }
}

private struct UsageRow: View {
    let key: String
    let metric: CurrentUsage.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(UsageMetric.displayName(key))
                    .foregroundStyle(Color.convexText)
                if let info = ConvexReference.metrics[key] {
                    InfoButton("About \(info.title)") {
                        MetricInfoView(info: info)
                    }
                }
            }
            HStack {
                usage("Today", metric.usage.currentDay)
                Spacer()
                usage("Month", metric.usage.currentMonth)
            }
        }
        .padding(.vertical, 2)
    }

    private func usage(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.convexMono(.caption2, weight: .medium))
                .foregroundStyle(Color.convexSecondaryText)
            Text(UsageMetric.format(value, unit: metric.unit))
                .font(.convexMono(.subheadline, weight: .medium))
                .foregroundStyle(Color.convexText)
        }
    }
}

/// What the limit editor sheet edits: an existing limit (`id`) or a new one.
private struct LimitDraft: Identifiable {
    let limitID: String?
    var config: UsageLimitConfig
    let id = UUID()
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.caption2)
            configuration.title.font(.convexMono(.subheadline, weight: .medium))
        }
    }
}

/// Shown above everything while the deployment is paused (or disabled by a usage limit).
private struct PausedBanner: View {
    let state: DeploymentDetailViewModel.Section<String>
    let isChanging: Bool
    let onResume: () -> Void

    var body: some View {
        ConvexSection {
            VStack(alignment: .leading, spacing: 8) {
                Label(isDisabled ? "Deployment disabled" : "Deployment paused", systemImage: "pause.circle.fill")
                    .font(.convexDisplay(.headline, weight: .medium))
                    .foregroundStyle(Color.convexYellow)
                Text(isDisabled
                     ? "Convex disabled this deployment (often a usage limit). Function calls fail until it's re-enabled."
                     : "Function calls fail, scheduled jobs are waiting, and crons are skipped until you resume.")
                    .font(.footnote)
                    .foregroundStyle(Color.convexSecondaryText)
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.convexAccentFill)
                .disabled(isChanging)
            }
            .padding(.vertical, 4)
        }
    }

    private var isDisabled: Bool {
        if case .loaded("disabled") = state { return true }
        return false
    }
}

/// A limit with how much of it is used (same window as the limit).
private struct UsageLimitRow: View {
    let limit: UsageLimit
    let usage: CurrentUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(UsageMetric.displayName(limit.metric))
                    .foregroundStyle(Color.convexText)
                Spacer()
                Text(limitText)
                    .font(.convexMono(.subheadline, weight: .medium))
                    .foregroundStyle(limit.enabled ? Color.convexText : Color.convexSecondaryText)
            }
            ProgressView(value: min(fraction ?? 0, 1))
                .tint(tint)
                .opacity(fraction == nil ? 0 : 1)
            Text(detail)
                .font(.convexMono(.caption2))
                .foregroundStyle(Color.convexSecondaryText)
        }
        .padding(.vertical, 2)
    }

    private var used: Double? {
        guard let metric = usage?.metrics[limit.metric] else { return nil }
        return limit.window == "day" ? metric.usage.currentDay : metric.usage.currentMonth
    }

    private var fraction: Double? {
        guard let used, limit.limit > 0, limit.enabled else { return nil }
        return used / Double(limit.limit)
    }

    private var tint: Color {
        switch fraction ?? 0 {
        case 1...: .convexRed
        case 0.8...: .convexYellow
        default: .convexGreen
        }
    }

    private var limitText: String {
        UsageMetric.format(Double(limit.limit), unit: usage?.metrics[limit.metric]?.unit ?? UsageLimitConfig.unit(of: limit.metric))
    }

    private var detail: String {
        var parts = [limit.limitType == "disable" ? "Disables deployment" : "Warning", "per \(limit.window)"]
        if let fraction { parts.append("\(MetricFormat.percent(fraction)) used") }
        if !limit.enabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }
}

/// Create, edit, or delete a usage limit. Owns its save/delete actions and dismisses itself.
private struct UsageLimitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: UsageLimitConfig
    @State private var isConfirmingDelete = false
    @State private var isConfirmingSave = false
    private let id: String?
    private let usage: CurrentUsage?
    private let viewModel: DeploymentDetailViewModel

    init(draft: LimitDraft, usage: CurrentUsage?, viewModel: DeploymentDetailViewModel) {
        _config = State(initialValue: draft.config)
        id = draft.limitID
        self.usage = usage
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            Form {
                ConvexSection("Metric") {
                    Picker("Metric", selection: $config.metric) {
                        ForEach(UsageLimitConfig.metrics, id: \.self) { metric in
                            Text(UsageMetric.displayName(metric)).tag(metric)
                        }
                    }
                    Picker("Window", selection: $config.window) {
                        Text("Per day").tag("day")
                        Text("Per month").tag("month")
                    }
                    .pickerStyle(.segmented)
                }

                ConvexSection {
                    LabeledContent {
                        TextField("Limit", value: $config.limit, format: .number)
                            .font(.convexMono(.body))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Limit (\(unit))")
                    }
                    if let used {
                        LabeledContent("Used so far", value: UsageMetric.format(used, unit: usageUnit))
                    }
                } header: {
                    Eyebrow("Amount")
                }

                ConvexSection {
                    Picker("When reached", selection: $config.limitType) {
                        Text("Warn").tag("warning")
                        Text("Disable").tag("disable")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Enabled", isOn: $config.enabled)
                } header: {
                    Eyebrow("When Reached")
                } footer: {
                    Text(typeFooter)
                        .foregroundStyle(disablesNow ? Color.convexRed : Color.convexSecondaryText)
                }

                if id != nil {
                    ConvexSection {
                        Button("Delete Limit", role: .destructive, action: confirmDelete)
                            .disabled(viewModel.isChanging)
                    }
                }
            }
            .convexScreenBackground()
            .navigationTitle(id == nil ? "New Usage Limit" : "Edit Usage Limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: requestSave)
                        .disabled(viewModel.isChanging || config.limit <= 0)
                }
            }
            .confirmationDialog("Delete this usage limit?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Limit", role: .destructive, action: delete)
            }
            .confirmationDialog("Disable the deployment now?", isPresented: $isConfirmingSave, titleVisibility: .visible) {
                Button("Save and Disable", role: .destructive, action: save)
            } message: {
                Text("Usage is already past this limit, so saving it disables the deployment right away.")
            }
        }
    }

    private var unit: String { UsageLimitConfig.unit(of: config.metric) }
    private var usageUnit: String { usage?.metrics[config.metric]?.unit ?? unit }

    private var used: Double? {
        guard let metric = usage?.metrics[config.metric] else { return nil }
        return config.window == "day" ? metric.usage.currentDay : metric.usage.currentMonth
    }

    /// Saving a disable limit at or below current usage would disable the deployment immediately.
    private var disablesNow: Bool {
        config.enabled && config.limitType == "disable" && (used ?? 0) >= Double(config.limit)
    }

    private var typeFooter: String {
        if disablesNow { return "Usage is already past this amount: saving disables the deployment right away." }
        return config.limitType == "disable"
            ? "When reached, Convex disables the deployment: function calls fail until the window resets or you raise the limit."
            : "When reached, Convex notifies your team. Nothing stops."
    }

    private func requestSave() {
        if disablesNow { isConfirmingSave = true } else { save() }
    }

    private func save() {
        Task {
            if await viewModel.saveLimit(id: id, config) { dismiss() }
        }
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func delete() {
        guard let id else { return }
        Task {
            if await viewModel.deleteLimit(id: id) { dismiss() }
        }
    }

    private func close() {
        dismiss()
    }
}

private struct SectionError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(Color.convexYellow)
    }
}
