import Foundation
import Observation

@Observable @MainActor final class LogsViewModel {
    enum LevelFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case errors = "Errors"
        case warnings = "Warnings"

        var id: String { rawValue }

        var level: LogLevel? {
            switch self {
            case .all: nil
            case .errors: .error
            case .warnings: .warn
            }
        }
    }

    var levelFilter: LevelFilter = .all
    var searchText = ""
    var isPaused = false

    private(set) var entries: [LogEntry] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    @ObservationIgnored let deploymentName: String
    @ObservationIgnored private let source: any MonitoringSource

    init(deploymentName: String, source: any MonitoringSource) {
        self.deploymentName = deploymentName
        self.source = source
    }

    /// Search matches the message or the function path.
    var visibleEntries: [LogEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.message.localizedCaseInsensitiveContains(searchText) || $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() async {
        do {
            entries = try await source.recentLogs(
                deploymentName: deploymentName, level: levelFilter.level?.rawValue, limit: 300
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Polls every 5s while visible and not paused. Logs are kept 24h by the backend.
    func autoRefresh() async {
        while !Task.isCancelled {
            if !isPaused { await load() }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
