import Foundation
import Observation

/// The monitoring backend's own platform usage. Every event a monitored deployment streams runs a
/// function on the backend, so a noisy app shows up here first.
@Observable @MainActor final class BackendUsageViewModel {
    enum State {
        case loading
        case loaded(deployment: Deployment, usage: CurrentUsage?, limits: [UsageLimit]?)
        /// The token can't see the backend (e.g. it lives in another team).
        case unavailable(String)
    }

    private(set) var state: State = .loading

    @ObservationIgnored private let client: ConvexAPIClient
    @ObservationIgnored private let deploymentName: String

    init(client: ConvexAPIClient, deploymentName: String) {
        self.client = client
        self.deploymentName = deploymentName
    }

    func load() async {
        do {
            let deployment = try await client.deployment(name: deploymentName)
            guard let url = deployment.deploymentUrl.flatMap(URL.init(string:)) else {
                state = .loaded(deployment: deployment, usage: nil, limits: nil)
                return
            }
            async let usage = try? client.currentUsage(deploymentURL: url)
            async let limits = try? client.usageLimits(deploymentURL: url)
            state = .loaded(deployment: deployment, usage: await usage, limits: await limits)
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }
}
