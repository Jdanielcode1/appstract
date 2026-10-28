import SwiftUI

/// Every project's default deployments at a glance: platform usage for all, function health for
/// monitored ones, and an "attention" list of errors, limit pressure, and scheduler lag.
struct OverviewView: View {
    @Environment(PulseSettings.self) private var pulseSettings
    @State private var viewModel: OverviewViewModel
    @State private var savedQueries = SavedQueriesStore.shared
    private let session: SessionStore.Session

    init(session: SessionStore.Session) {
        self.session = session
        _viewModel = State(initialValue: OverviewViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.convexRed)
                }

                if pulseSettings.isConfigured {
                    healthSection
                } else if !viewModel.cards.isEmpty {
                    ConvexSection {
                        Label("Connect a monitoring backend (Settings → Monitoring Backend) to see function errors and latency here.",
                              systemImage: "waveform.path.ecg")
                            .font(.callout)
                            .foregroundStyle(Color.convexSecondaryText)
                    }
                }

                if !savedQueries.items.isEmpty {
                    ConvexSection {
                        ForEach(savedQueries.items) { query in
                            NavigationLink {
                                SavedQueryRunView(query: query, client: session.client)
                            } label: {
                                SavedQueryRow(query: query, showsDeployment: true)
                            }
                        }
                    } header: {
                        Eyebrow("Saved Queries")
                    }
                }

                if !viewModel.attention.isEmpty {
                    ConvexSection("Needs Attention") {
                        ForEach(viewModel.attention) { item in
                            NavigationLink {
                                DeploymentDetailView(deployment: item.card.deployment, client: session.client)
                            } label: {
                                AttentionRow(item: item)
                            }
                        }
                    }
                }

                ConvexSection {
                    ForEach(viewModel.activeCards) { card in
                        DeploymentCardLink(card: card, client: session.client)
                    }
                    if !viewModel.idleCards.isEmpty {
                        DisclosureGroup {
                            ForEach(viewModel.idleCards) { card in
                                DeploymentCardLink(card: card, client: session.client)
                            }
                        } label: {
                            Label("\(viewModel.idleCards.count) idle deployments", systemImage: "moon.zzz")
                                .font(.convexMono(.subheadline, weight: .medium))
                                .foregroundStyle(Color.convexSecondaryText)
                        }
                    }
                } header: {
                    Eyebrow("Deployments")
                } footer: {
                    if let updated = viewModel.lastUpdated {
                        Text("Default prod and dev deployments. Updated \(updated, format: .relative(presentation: .named)).")
                    }
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.cards.isEmpty {
                    ProgressView("Loading projects…")
                } else if !viewModel.isLoading && viewModel.cards.isEmpty && viewModel.errorMessage == nil {
                    ContentUnavailableView("No Deployments", systemImage: "square.stack.3d.up.slash",
                                           description: Text("This token can't see any deployments."))
                }
            }
            .convexScreenBackground()
            .navigationTitle("Overview")
            .toolbar { LogoToolbarItem() }
            .refreshable { await viewModel.load(pulse: pulseSettings.client) }
            .task(id: pulseSettings.client?.deploymentURL) { await viewModel.autoRefresh(pulse: pulseSettings.client) }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        ConvexSection {
            if let error = viewModel.monitoringError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.convexYellow)
            } else if viewModel.monitoredCards.isEmpty && !viewModel.cards.isEmpty {
                Text("No monitored deployments yet. Open a deployment and turn on Enable Monitoring.")
                    .font(.callout)
                    .foregroundStyle(Color.convexSecondaryText)
            } else {
                let totals = viewModel.totals
                HStack {
                    StatTile(title: "Calls (24h)", value: MetricFormat.count(totals.calls))
                    StatTile(title: "Errors", value: MetricFormat.count(totals.errors), tint: totals.errors > 0 ? .convexRed : nil)
                    StatTile(title: "Error Rate", value: MetricFormat.percent(totals.errorRate),
                             tint: totals.errorRate > 0.01 ? .convexRed : nil)
                }
            }
        } header: {
            Eyebrow("Function Health")
        } footer: {
            if !viewModel.monitoredCards.isEmpty {
                Text("Across \(viewModel.monitoredCards.count) monitored deployment\(viewModel.monitoredCards.count == 1 ? "" : "s").")
            }
        }
    }
}

private struct DeploymentCardLink: View {
    let card: DeploymentOverview
    let client: ConvexAPIClient

    var body: some View {
        NavigationLink {
            DeploymentDetailView(deployment: card.deployment, client: client)
        } label: {
            DeploymentCardRow(card: card)
        }
    }
}

private struct AttentionRow: View {
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch item.kind {
        case .errors: "exclamationmark.octagon.fill"
        case .limit: "gauge.with.dots.needle.67percent"
        case .schedulerLag: "clock.badge.exclamationmark"
        }
    }

    private var color: Color {
        switch item.kind {
        case .errors: .convexRed
        case .limit: .convexYellow
        case .schedulerLag: .convexYellow
        }
    }
}

private struct DeploymentCardRow: View {
    let card: DeploymentOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DeploymentBadge(type: card.deployment.deploymentType)
                Text(card.project.name)
                    .font(.convexDisplay(.headline, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let health = card.health {
                    StatusDot(isHealthy: health.errors == 0)
                }
            }

            HStack(spacing: 14) {
                if let today = card.functionCallsToday {
                    metric("Calls today", MetricFormat.count(Int(today)))
                }
                if let month = card.functionCallsMonth {
                    metric("This month", MetricFormat.count(Int(month)))
                }
                if let health = card.health {
                    metric("24h errors", MetricFormat.percent(health.errorRate), tint: health.errors > 0 ? .convexRed : nil)
                    // Lite monitoring has no latency (0).
                    if health.p95Ms > 0 {
                        metric("p95", MetricFormat.duration(health.p95Ms))
                    }
                }
            }

            if let pressure = card.limitPressure {
                ProgressView(value: min(pressure.fraction, 1)) {
                    Text("\(UsageMetric.displayName(pressure.limit.metric)) limit · \(MetricFormat.percent(pressure.fraction))")
                        .font(.caption2)
                        .foregroundStyle(Color.convexSecondaryText)
                }
                .tint(pressure.fraction >= 0.8 ? Color.convexYellow : Color.convexAccent)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.convexMono(.subheadline, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.convexSecondaryText)
        }
    }
}
