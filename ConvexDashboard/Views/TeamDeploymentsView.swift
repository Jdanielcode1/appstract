import SwiftUI

/// All cloud deployments across the team, grouped by how recently they were deployed.
struct TeamDeploymentsList: View {
    @Environment(PulseSettings.self) private var pulseSettings
    @State private var viewModel: TeamDeploymentsViewModel
    private let client: ConvexAPIClient
    /// Owned by ProjectsView so both modes share one search field.
    let searchText: String

    init(session: SessionStore.Session, searchText: String) {
        client = session.client
        self.searchText = searchText
        _viewModel = State(initialValue: TeamDeploymentsViewModel(session: session))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            ChipBar(items: viewModel.availableFilters.map { ChipBar.Item(id: $0.filter, title: $0.filter.rawValue, count: $0.count) },
                    selection: $viewModel.filter)

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
                    .listRowBackground(Color.convexSurface)
            }

            ForEach(viewModel.sections) { section in
                ConvexSection(section.title) {
                    ForEach(section.rows) { row in
                        NavigationLink {
                            DeploymentDetailView(deployment: row.deployment, client: client)
                        } label: {
                            TeamDeploymentRow(row: row)
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
            } else if viewModel.isEmpty && viewModel.errorMessage == nil {
                EmptyDeploymentsView(searchText: viewModel.searchText)
            }
        }
        .onChange(of: searchText, initial: true) { _, text in viewModel.searchText = text }
        .refreshable { await viewModel.load(pulse: pulseSettings.client) }
        .task(id: pulseSettings.client?.deploymentURL) { await viewModel.load(pulse: pulseSettings.client) }
    }
}

private struct TeamDeploymentRow: View {
    let row: TeamDeploymentsViewModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DeploymentBadge(type: row.deployment.deploymentType)
                Text(row.projectName)
                    .font(.convexDisplay(.headline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                LastDeployText(timestamp: row.deployment.lastDeployTime)
            }

            HStack(spacing: 6) {
                Text(row.deployment.name)
                    .font(.convexMono(.subheadline))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Image(systemName: "waveform.path.ecg")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.convexGreen)
                    .opacity(row.isMonitored == true ? 1 : 0)
                    .accessibilityLabel("Monitored")
                    .accessibilityHidden(row.isMonitored != true)
            }

            Text(row.details)
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexSecondaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct LastDeployText: View {
    let timestamp: Int64?

    var body: some View {
        Group {
            if let timestamp {
                Text(timestamp.dateFromMillis, format: .relative(presentation: .numeric, unitsStyle: .narrow))
            } else {
                Text("—")
            }
        }
        .font(.convexMono(.caption, weight: .medium))
        .foregroundStyle(Color.convexSecondaryText)
    }
}

private struct EmptyDeploymentsView: View {
    let searchText: String

    var body: some View {
        if searchText.isEmpty {
            ContentUnavailableView("No Deployments", systemImage: "square.stack.3d.up.slash",
                                   description: Text("Nothing matches this filter."))
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }
}
