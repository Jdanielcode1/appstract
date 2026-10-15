import Foundation
import Observation

/// Last-hour health charts for one deployment (function calls, failure rate, cache hit rate,
/// concurrency, scheduler lag) from the deployment's own metrics. No monitoring backend needed.
@Observable @MainActor final class DeploymentMetricsViewModel {
    /// Each chart loads independently: one failing endpoint shouldn't blank the screen.
    enum Chart: Sendable {
        case loading
        case loaded([MetricSeries])
        case failed(String)

        var series: [MetricSeries] {
            if case .loaded(let series) = self { return series }
            return []
        }
    }

    private(set) var functionCalls: Chart = .loading
    private(set) var failureRate: Chart = .loading
    private(set) var cacheHitRate: Chart = .loading
    private(set) var running: Chart = .loading
    private(set) var queued: Chart = .loading
    private(set) var schedulerLag: Chart = .loading
    private(set) var lastUpdated: Date?

    /// Fixed last-hour x axis so charts line up and don't jump as data arrives.
    var domain: ClosedRange<Date> {
        let end = lastUpdated ?? .now
        return end.addingTimeInterval(-3600)...end
    }

    @ObservationIgnored let deployment: Deployment
    @ObservationIgnored private let deploymentURL: URL
    @ObservationIgnored private let client: ConvexAPIClient

    init(deployment: Deployment, deploymentURL: URL, client: ConvexAPIClient) {
        self.deployment = deployment
        self.deploymentURL = deploymentURL
        self.client = client
    }

    func load() async {
        let window = MetricsWindow.lastHour()
        let client = client
        let url = deploymentURL
        async let calls = Self.chart { AppMetricsParser.series(try await client.functionCallCounts(deploymentURL: url, window: window), idleValue: 0, restName: "Other functions") }
        async let failures = Self.chart { AppMetricsParser.series(try await client.failurePercentages(deploymentURL: url, window: window), idleValue: 0, restName: "Other functions") }
        async let cache = Self.chart { AppMetricsParser.series(try await client.cacheHitPercentages(deploymentURL: url, window: window), idleValue: 100, restName: "Other queries") }
        async let concurrency = Self.result { AppMetricsParser.concurrency(try await client.functionConcurrency(deploymentURL: url, window: window)) }
        async let lag = Self.chart { AppMetricsParser.schedulerLag(try await client.schedulerLag(deploymentURL: url, window: window)) }

        let results = await (calls, failures, cache, concurrency, lag)
        if Task.isCancelled { return }
        functionCalls = results.0
        failureRate = results.1
        cacheHitRate = results.2
        switch results.3 {
        case .success(let value):
            running = .loaded(value.running)
            queued = .loaded(value.queued)
        case .failure(let error):
            running = .failed(Self.message(for: error))
            queued = .failed(Self.message(for: error))
        }
        schedulerLag = results.4
        lastUpdated = .now
    }

    /// Loads immediately, then keeps refreshing until the calling task is cancelled.
    func autoRefresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: monitoringRefreshInterval)
        }
    }

    private nonisolated static func chart(_ work: @Sendable () async throws -> [MetricSeries]) async -> Chart {
        switch await result(work) {
        case .success(let series): .loaded(series)
        case .failure(let error): .failed(message(for: error))
        }
    }

    private nonisolated static func result<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case APIError.unauthorized, APIError.forbidden:
            "This token can't read metrics for this deployment."
        default:
            error.localizedDescription
        }
    }
}
