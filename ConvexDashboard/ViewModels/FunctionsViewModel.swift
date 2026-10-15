import Foundation
import Observation

/// How often monitoring screens re-fetch while visible.
let monitoringRefreshInterval: Duration = .seconds(15)

@Observable @MainActor final class FunctionsViewModel {
    enum Sort: String, CaseIterable, Identifiable {
        case calls = "Most Called"
        case slowest = "Slowest"
        case errors = "Most Errors"

        var id: String { rawValue }
    }

    var window: StatWindow = .day
    var sort: Sort = .calls
    var searchText = ""

    private(set) var summary: FunctionSummary?
    private(set) var timeseries: [TimeseriesPoint] = []
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?

    @ObservationIgnored let deploymentName: String
    @ObservationIgnored private let source: any MonitoringSource

    init(deploymentName: String, source: any MonitoringSource) {
        self.deploymentName = deploymentName
        self.source = source
    }

    var functions: [FunctionStat] {
        let all = summary?.functions ?? []
        let filtered = searchText.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        return switch sort {
        case .calls: filtered.sorted { $0.calls > $1.calls }
        case .slowest: filtered.sorted { $0.p95Ms > $1.p95Ms }
        case .errors: filtered.sorted { ($0.errors, $0.errorRate) > ($1.errors, $1.errorRate) }
        }
    }

    func load() async {
        do {
            async let summary = source.functionSummary(deploymentName: deploymentName, window: window)
            async let points = source.timeseries(deploymentName: deploymentName, window: window, path: nil)
            self.summary = try await summary
            self.timeseries = try await points
            errorMessage = nil
            lastUpdated = .now
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads immediately, then keeps refreshing until the calling task is cancelled.
    func autoRefresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: monitoringRefreshInterval)
        }
    }
}

@Observable @MainActor final class FunctionDetailViewModel {
    var window: StatWindow

    private(set) var stat: FunctionStat
    private(set) var timeseries: [TimeseriesPoint] = []
    private(set) var errors: [FunctionError] = []
    private(set) var errorMessage: String?

    @ObservationIgnored let deploymentName: String
    @ObservationIgnored private let source: any MonitoringSource

    init(stat: FunctionStat, window: StatWindow, deploymentName: String, source: any MonitoringSource) {
        self.stat = stat
        self.window = window
        self.deploymentName = deploymentName
        self.source = source
    }

    func load() async {
        do {
            async let summary = source.functionSummary(deploymentName: deploymentName, window: window)
            async let points = source.timeseries(deploymentName: deploymentName, window: window, path: stat.path)
            async let recent = source.recentErrors(deploymentName: deploymentName, path: stat.path, limit: 25)
            if let updated = try await summary.functions.first(where: { $0.path == stat.path }) {
                stat = updated
            }
            timeseries = try await points
            errors = try await recent
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func autoRefresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: monitoringRefreshInterval)
        }
    }
}

@Observable @MainActor final class RecentErrorsViewModel {
    private(set) var errors: [FunctionError] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    @ObservationIgnored let deploymentName: String
    @ObservationIgnored private let source: any MonitoringSource

    init(deploymentName: String, source: any MonitoringSource) {
        self.deploymentName = deploymentName
        self.source = source
    }

    func load() async {
        do {
            errors = try await source.recentErrors(deploymentName: deploymentName, path: nil, limit: 100)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    func autoRefresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: monitoringRefreshInterval)
        }
    }
}
