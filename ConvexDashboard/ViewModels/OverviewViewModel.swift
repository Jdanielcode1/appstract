import Foundation
import Observation

/// One deployment card on the Overview screen: platform usage (token) + function health (backend).
struct DeploymentOverview: Identifiable, Sendable {
    let project: Project
    let deployment: Deployment
    let usage: CurrentUsage?
    let limits: [UsageLimit]
    /// nil when monitoring isn't enabled for this deployment (or no backend is configured).
    var health: DeploymentHealth?

    var id: String { deployment.name }

    /// No monitoring data and no function calls this month.
    var isIdle: Bool { health == nil && (functionCallsMonth ?? 0) == 0 }

    var functionCallsToday: Double? { usage?.metrics["functionCalls"]?.usage.currentDay }
    var functionCallsMonth: Double? { usage?.metrics["functionCalls"]?.usage.currentMonth }

    /// Highest usage ÷ limit across enabled limits (1.0 = at the limit).
    var limitPressure: (fraction: Double, limit: UsageLimit)? {
        guard let usage else { return nil }
        return limits
            .filter { $0.enabled && $0.limit > 0 }
            .compactMap { limit -> (Double, UsageLimit)? in
                guard let metric = usage.metrics[limit.metric] else { return nil }
                let used = limit.window == "day" ? metric.usage.currentDay : metric.usage.currentMonth
                return (used / Double(limit.limit), limit)
            }
            .max { $0.0 < $1.0 }
            .map { (fraction: $0.0, limit: $0.1) }
    }
}

/// Something worth looking at, surfaced at the top of the Overview.
struct AttentionItem: Identifiable {
    enum Kind { case errors, limit, schedulerLag }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let card: DeploymentOverview
}

@Observable @MainActor final class OverviewViewModel {
    private(set) var cards: [DeploymentOverview] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Error from the monitoring backend only; platform data may still be shown.
    private(set) var monitoringError: String?
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let session: SessionStore.Session

    init(session: SessionStore.Session) {
        self.session = session
    }

    var monitoredCards: [DeploymentOverview] { cards.filter { $0.health != nil } }
    var activeCards: [DeploymentOverview] { cards.filter { !$0.isIdle } }
    var idleCards: [DeploymentOverview] { cards.filter(\.isIdle) }

    var totals: (calls: Int, errors: Int, errorRate: Double) {
        let calls = monitoredCards.reduce(0) { $0 + ($1.health?.calls ?? 0) }
        let errors = monitoredCards.reduce(0) { $0 + ($1.health?.errors ?? 0) }
        return (calls, errors, calls > 0 ? Double(errors) / Double(calls) : 0)
    }

    var attention: [AttentionItem] {
        var items: [AttentionItem] = []
        for card in cards {
            let label = "\(card.project.name) · \(card.deployment.deploymentType)"
            if let health = card.health, health.errors > 0 {
                let top = health.failingFunctions.first.map { " · top: \($0.path)" } ?? ""
                items.append(AttentionItem(
                    id: "errors-\(card.id)", kind: .errors, title: label,
                    detail: "\(health.errors) error\(health.errors == 1 ? "" : "s") in 24h (\(MetricFormat.percent(health.errorRate)))\(top)",
                    card: card
                ))
            }
            if let pressure = card.limitPressure, pressure.fraction >= 0.8 {
                items.append(AttentionItem(
                    id: "limit-\(card.id)", kind: .limit, title: label,
                    detail: "\(MetricFormat.percent(pressure.fraction)) of \(UsageMetric.displayName(pressure.limit.metric)) \(pressure.limit.limitType) limit (per \(pressure.limit.window))",
                    card: card
                ))
            }
            if let lag = card.health?.schedulerLagSeconds, lag >= 60 {
                items.append(AttentionItem(
                    id: "lag-\(card.id)", kind: .schedulerLag, title: label,
                    detail: "Scheduled jobs are \(Int(lag))s behind",
                    card: card
                ))
            }
        }
        return items
    }

    func load(pulse: PulseClient?) async {
        isLoading = true
        defer { isLoading = false }

        let client = session.client
        do {
            async let healthResult = Self.loadHealth(pulse)
            let projects = try await client.projects(for: session.tokenDetails.scope)

            var loaded = try await withThrowingTaskGroup(of: [DeploymentOverview].self) { group in
                for project in projects {
                    group.addTask { try await Self.loadCards(for: project, client: client) }
                }
                var all: [DeploymentOverview] = []
                for try await cards in group { all += cards }
                return all
            }

            switch await healthResult {
            case .success(let health):
                let byName = Dictionary(health.map { ($0.deploymentName, $0) }, uniquingKeysWith: { a, _ in a })
                for index in loaded.indices { loaded[index].health = byName[loaded[index].deployment.name] }
                monitoringError = nil
            case .failure(let error):
                monitoringError = error.localizedDescription
            }

            // Monitored first, then busiest this month; name/type as tiebreakers for a stable order.
            cards = loaded.sorted {
                let lhs = ($0.health == nil ? 1 : 0, -($0.functionCallsMonth ?? 0))
                let rhs = ($1.health == nil ? 1 : 0, -($1.functionCallsMonth ?? 0))
                if lhs != rhs { return lhs < rhs }
                return ($0.project.name.localizedLowercase, $0.deployment.typeRank) < ($1.project.name.localizedLowercase, $1.deployment.typeRank)
            }
            errorMessage = nil
            lastUpdated = .now
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func autoRefresh(pulse: PulseClient?) async {
        while !Task.isCancelled {
            await load(pulse: pulse)
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private nonisolated static func loadHealth(_ pulse: PulseClient?) async -> Result<[DeploymentHealth], Error> {
        guard let pulse else { return .success([]) }
        do { return .success(try await pulse.overview()) } catch { return .failure(error) }
    }

    /// The project's default prod deployment and the token owner's default dev deployment.
    /// Usage/limit failures (e.g. missing permission) leave those fields empty rather than failing.
    private nonisolated static func loadCards(for project: Project, client: ConvexAPIClient) async throws -> [DeploymentOverview] {
        let wanted = Set([project.prodDeploymentName, project.devDeploymentName].compactMap { $0 })
        guard !wanted.isEmpty else { return [] }
        let deployments = try await client.deployments(projectId: project.id).filter { $0.isCloud && wanted.contains($0.name) }

        return await withTaskGroup(of: DeploymentOverview.self) { group in
            for deployment in deployments {
                group.addTask {
                    guard let url = deployment.deploymentUrl.flatMap(URL.init(string:)) else {
                        return DeploymentOverview(project: project, deployment: deployment, usage: nil, limits: [])
                    }
                    async let usage = try? client.currentUsage(deploymentURL: url)
                    async let limits = (try? client.usageLimits(deploymentURL: url)) ?? []
                    return await DeploymentOverview(project: project, deployment: deployment, usage: usage, limits: limits)
                }
            }
            var cards: [DeploymentOverview] = []
            for await card in group { cards.append(card) }
            return cards
        }
    }
}
