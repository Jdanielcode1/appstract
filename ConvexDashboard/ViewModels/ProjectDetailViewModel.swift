import Foundation
import Observation

@Observable @MainActor final class ProjectDetailViewModel {
    private(set) var deployments: [Deployment] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let client: ConvexAPIClient
    @ObservationIgnored let project: Project

    init(project: Project, client: ConvexAPIClient) {
        self.project = project
        self.client = client
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            deployments = try await client.deployments(projectId: project.id)
                .filter(\.isCloud)
                .sorted { ($0.typeRank, $0.name) < ($1.typeRank, $1.name) }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
