import Foundation
import Observation

/// Live Logs straight from Convex (`ConvexAPIClient.functionLogs`), like the dashboard Logs page.
/// Works on every plan with no monitoring backend; entries live only in memory while the screen is open.
@Observable @MainActor final class LiveLogsViewModel {
    enum Filter: Hashable {
        case all, errors, logs
    }

    var filter: Filter = .all { didSet { applyFilter() } }
    var searchText = "" { didSet { applyFilter() } }
    var isPaused = false

    private(set) var visibleItems: [LiveLogItem] = []
    private(set) var errorCount = 0
    private(set) var logCount = 0
    private(set) var totalCount = 0
    private(set) var errorMessage: String?

    /// Newest first.
    @ObservationIgnored private var items: [LiveLogItem] = []
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var cursor: Double = 0
    @ObservationIgnored private let deploymentURL: URL
    @ObservationIgnored private let client: ConvexAPIClient

    private static let maxItems = 1000

    init(deploymentURL: URL, client: ConvexAPIClient) {
        self.deploymentURL = deploymentURL
        self.client = client
    }

    /// Fetches what Convex still holds, then waits for anything newer while visible and not paused.
    /// The request long-polls: it returns only when there's something new.
    func stream() async {
        while !Task.isCancelled {
            if isPaused {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            do {
                let page = try await client.functionLogs(deploymentURL: deploymentURL, cursor: cursor)
                cursor = max(cursor, page.newCursor)
                append(page.entries)
                errorMessage = nil
                try? await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func clear() {
        items = []
        applyFilter()
    }

    private func append(_ entries: [FunctionExecution]) {
        let new = entries.map(LiveLogItem.init).filter { seen.insert($0.id).inserted }
        guard !new.isEmpty else { return }
        items = (new.sorted { $0.date > $1.date } + items).prefix(Self.maxItems).map { $0 }
        if seen.count > Self.maxItems * 4 { seen = Set(items.map(\.id)) }
        applyFilter()
    }

    private func applyFilter() {
        totalCount = items.count
        errorCount = items.count { $0.outcome == .failure }
        logCount = items.count { $0.hasLogs }
        visibleItems = items.filter { item in
            let matchesFilter = switch filter {
            case .all: true
            case .errors: item.outcome == .failure
            case .logs: item.hasLogs
            }
            return matchesFilter && (searchText.isEmpty || item.searchText.localizedCaseInsensitiveContains(searchText))
        }
    }
}
