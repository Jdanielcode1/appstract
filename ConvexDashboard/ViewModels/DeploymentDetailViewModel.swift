import Foundation
import Observation

@Observable @MainActor final class DeploymentDetailViewModel {
    /// Each section loads independently: a custom role may allow some endpoints and deny others.
    enum Section<Value: Sendable>: Sendable {
        case loading
        case loaded(Value)
        case failed(String)
    }

    private(set) var usage: Section<CurrentUsage> = .loading
    private(set) var limits: Section<[UsageLimit]> = .loading
    private(set) var envVars: Section<[(name: String, value: String)]> = .loading
    /// "running", "paused", or "disabled".
    private(set) var state: Section<String> = .loading
    /// A pause/unpause or usage limit change in flight.
    private(set) var isChanging = false
    /// Why the last change failed (shown in an alert).
    var changeError: String?

    var isPaused: Bool {
        if case .loaded(let state) = state { return state != "running" }
        return false
    }

    @ObservationIgnored private let client: ConvexAPIClient
    @ObservationIgnored let deployment: Deployment

    init(deployment: Deployment, client: ConvexAPIClient) {
        self.deployment = deployment
        self.client = client
    }

    func load() async {
        guard let urlString = deployment.deploymentUrl, let url = URL(string: urlString) else {
            let message = "This deployment has no URL."
            usage = .failed(message)
            limits = .failed(message)
            envVars = .failed(message)
            state = .failed(message)
            return
        }

        let client = client
        async let usageResult = Self.capture { try await client.currentUsage(deploymentURL: url) }
        async let limitsResult = Self.capture { try await client.usageLimits(deploymentURL: url) }
        async let envResult = Self.capture { try await client.environmentVariables(deploymentURL: url) }
        async let stateResult = Self.capture { try await client.deploymentState(deploymentURL: url) }

        state = await stateResult
        usage = await usageResult
        limits = await limitsResult
        envVars = switch await envResult {
        case .loaded(let vars): .loaded(vars.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) })
        case .failed(let message): .failed(message)
        case .loading: .loading
        }
    }

    // MARK: Changes (official Deployment API writes; every one is confirmed in the UI first)

    func setPaused(_ paused: Bool) async {
        await change { client, url in
            try await client.setPaused(paused, deploymentURL: url)
            // Pausing takes effect right away; read the state back rather than assuming it.
            self.state = .loaded((try? await client.deploymentState(deploymentURL: url)) ?? (paused ? "paused" : "running"))
        }
    }

    /// Creates a limit, or replaces the limit with `id`.
    func saveLimit(id: String?, _ config: UsageLimitConfig) async -> Bool {
        await change { client, url in
            let saved = if let id {
                try await client.updateUsageLimit(deploymentURL: url, id: id, config)
            } else {
                try await client.createUsageLimit(deploymentURL: url, config)
            }
            var list = if case .loaded(let current) = self.limits { current } else { [UsageLimit]() }
            if let index = list.firstIndex(where: { $0.id == saved.id }) { list[index] = saved } else { list.append(saved) }
            self.limits = .loaded(list)
        }
    }

    func deleteLimit(id: String) async -> Bool {
        await change { client, url in
            try await client.deleteUsageLimit(deploymentURL: url, id: id)
            if case .loaded(let current) = self.limits { self.limits = .loaded(current.filter { $0.id != id }) }
        }
    }

    @discardableResult
    private func change(_ work: (ConvexAPIClient, URL) async throws -> Void) async -> Bool {
        guard let url = deployment.deploymentUrl.flatMap(URL.init(string:)), !isChanging else { return false }
        isChanging = true
        defer { isChanging = false }
        do {
            try await work(client, url)
            WidgetRefresher.reload()
            return true
        } catch APIError.forbidden {
            changeError = "Your access token's role isn't allowed to change this deployment."
        } catch {
            changeError = error.localizedDescription
        }
        return false
    }

    nonisolated private static func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Section<T> {
        do {
            return .loaded(try await work())
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
