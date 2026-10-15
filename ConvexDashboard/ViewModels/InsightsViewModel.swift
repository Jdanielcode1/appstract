import Foundation
import Observation

/// Official Convex health insights for one deployment (last 72 hours).
@Observable @MainActor final class InsightsViewModel {
    private(set) var insights: [Insight] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    @ObservationIgnored let deployment: Deployment
    @ObservationIgnored private let client: ConvexAPIClient
    @ObservationIgnored private var teamId: Int?

    init(deployment: Deployment, client: ConvexAPIClient) {
        self.deployment = deployment
        self.client = client
    }

    var errorCount: Int { insights.filter(\.isError).count }
    var warningCount: Int { insights.count - errorCount }

    func load() async {
        do {
            let teamId = try await resolveTeamId()
            insights = try await client.insights(teamId: teamId, deploymentName: deployment.name)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch APIError.unauthorized, APIError.forbidden {
            errorMessage = "Convex didn't accept this token for insights. Insights come from the Convex dashboard's API, which may need a personal access token."
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// The insights API is per team; look the team up from the deployment's project (cached).
    private func resolveTeamId() async throws -> Int {
        if let teamId { return teamId }
        let id = try await client.project(id: deployment.projectId).teamId
        teamId = id
        return id
    }
}
