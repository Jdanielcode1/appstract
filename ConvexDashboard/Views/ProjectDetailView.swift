import SwiftUI

struct ProjectDetailView: View {
    @State private var viewModel: ProjectDetailViewModel
    private let client: ConvexAPIClient

    init(project: Project, client: ConvexAPIClient) {
        self.client = client
        _viewModel = State(initialValue: ProjectDetailViewModel(project: project, client: client))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
            }

            ConvexSection("Deployments") {
                ForEach(viewModel.deployments) { deployment in
                    NavigationLink(value: deployment) {
                        DeploymentRow(deployment: deployment)
                    }
                }
            }

            ConvexSection("Project") {
                LabeledContent("Slug", value: viewModel.project.slug)
                LabeledContent("Team", value: viewModel.project.teamSlug)
                LabeledContent("Created", value: viewModel.project.createTime.dateFromMillis.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.deployments.isEmpty {
                ProgressView()
            }
        }
        .convexScreenBackground()
        .navigationTitle(viewModel.project.name)
        .navigationDestination(for: Deployment.self) { deployment in
            DeploymentDetailView(deployment: deployment, client: client)
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }
}

private struct DeploymentRow: View {
    let deployment: Deployment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DeploymentBadge(type: deployment.deploymentType)
                Text(deployment.name)
                    .font(.convexMono(.body))
            }
            if let lastDeploy = deployment.lastDeployTime {
                Text("Deployed \(lastDeploy.dateFromMillis, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}
