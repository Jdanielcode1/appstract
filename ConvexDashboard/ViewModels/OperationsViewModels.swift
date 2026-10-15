import Foundation
import Observation

/// Crons and scheduled functions for one deployment (deployment screen → Schedules).
@Observable @MainActor final class SchedulesViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case crons = "Crons"
        case scheduled = "Scheduled"
        var id: String { rawValue }
    }

    private(set) var crons: [CronJob] = []
    private(set) var runsByCron: [String: [CronRun]] = [:]
    private(set) var scheduled: [ScheduledJob] = []
    private(set) var hasMoreScheduled = false
    private(set) var failingCount = 0
    private(set) var hasLoaded = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    var tab: Tab = .crons

    @ObservationIgnored private let deploymentURL: URL
    @ObservationIgnored private let client: ConvexAPIClient
    @ObservationIgnored private var scheduledCursor: String?

    init(deploymentURL: URL, client: ConvexAPIClient) {
        self.deploymentURL = deploymentURL
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        async let cronsResult = asyncResult { [client, deploymentURL] in try await client.cronJobs(deploymentURL: deploymentURL) }
        async let runsResult = asyncResult { [client, deploymentURL] in try await client.cronRuns(deploymentURL: deploymentURL) }
        async let scheduledResult = asyncResult { [client, deploymentURL] in try await client.scheduledJobs(deploymentURL: deploymentURL, cursor: nil) }
        let (cronsValue, runsValue, scheduledValue) = await (cronsResult, runsResult, scheduledResult)
        guard !Task.isCancelled else { return }

        do {
            let runs = (try? runsValue.get()) ?? []
            runsByCron = Dictionary(grouping: runs, by: \.name)
            // Failing crons first, then by next run.
            crons = try cronsValue.get().sorted { lhs, rhs in
                let lhsFailing = lhs.lastRun?.isFailure ?? false
                let rhsFailing = rhs.lastRun?.isFailure ?? false
                if lhsFailing != rhsFailing { return lhsFailing }
                return (lhs.nextRun ?? .distantFuture) < (rhs.nextRun ?? .distantFuture)
            }
            failingCount = crons.filter { $0.lastRun?.isFailure ?? false }.count
            let page = try scheduledValue.get()
            scheduled = page.jobs
            scheduledCursor = page.cursor
            hasMoreScheduled = page.cursor != nil
            errorMessage = nil
        } catch {
            errorMessage = DataErrors.message(for: error)
        }
        hasLoaded = true
    }

    func loadMoreScheduled() {
        guard hasLoaded, hasMoreScheduled, !isLoadingMore, let cursor = scheduledCursor else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await client.scheduledJobs(deploymentURL: deploymentURL, cursor: cursor) else { return }
            var seen = Set(scheduled.map(\.id))
            scheduled += page.jobs.filter { seen.insert($0.id).inserted }
            scheduledCursor = page.cursor
            hasMoreScheduled = page.cursor != nil
        }
    }
}

/// The deployment audit log (deployment screen → History).
@Observable @MainActor final class HistoryViewModel {
    struct DaySection: Identifiable {
        let day: Date
        let events: [DeploymentEvent]
        var id: Date { day }
    }

    private(set) var events: [DeploymentEvent] = []
    private(set) var sections: [DaySection] = []
    /// Filter chips for categories that have events ("All" first).
    private(set) var chipItems: [ChipBar<DeploymentEvent.Category>.Item] = []
    private(set) var memberNames: [String: String] = [:]
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    var category: DeploymentEvent.Category = .all {
        didSet { rebuildSections() }
    }

    @ObservationIgnored private let deployment: Deployment
    @ObservationIgnored private let deploymentURL: URL
    @ObservationIgnored private let client: ConvexAPIClient
    @ObservationIgnored private var cursor: String?

    init(deployment: Deployment, deploymentURL: URL, client: ConvexAPIClient) {
        self.deployment = deployment
        self.deploymentURL = deploymentURL
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        do {
            let page = try await client.deploymentEvents(deploymentURL: deploymentURL, cursor: nil)
            events = page.events
            cursor = page.cursor
            hasMore = page.cursor != nil
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch APIError.server(_, let message?) where message.localizedCaseInsensitiveContains("plan")
            || message.localizedCaseInsensitiveContains("professional") {
            errorMessage = "History needs the Convex Professional plan."
        } catch {
            errorMessage = DataErrors.message(for: error)
        }
        hasLoaded = true
        rebuildSections()
        await loadMemberNames()
    }

    func loadMore() {
        guard hasLoaded, hasMore, !isLoadingMore, let cursor else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await client.deploymentEvents(deploymentURL: deploymentURL, cursor: cursor) else { return }
            var seen = Set(events.map(\.id))
            events += page.events.filter { seen.insert($0.id).inserted }
            self.cursor = page.cursor
            hasMore = page.cursor != nil
            rebuildSections()
        }
    }

    func author(of event: DeploymentEvent) -> String {
        guard let memberId = event.memberId else { return event.source }
        let name = memberNames[memberId] ?? "Member \(memberId)"
        return "\(name) · \(event.source)"
    }

    /// Names come from the team's member list. Team access tokens usually can't list members
    /// (403), so fall back to recognizing the token owner, who created this project's default dev
    /// deployment.
    private func loadMemberNames() async {
        guard memberNames.isEmpty, let project = try? await client.project(id: deployment.projectId) else { return }
        if let members = try? await client.teamMembers(teamId: project.teamId) {
            memberNames = Dictionary(members.map { (String($0.id), $0.displayName) }, uniquingKeysWith: { first, _ in first })
        } else if let devName = project.devDeploymentName,
                  let creator = try? await client.deployment(name: devName).creator {
            memberNames = [String(creator): "You"]
        }
    }

    private func rebuildSections() {
        var counts: [DeploymentEvent.Category: Int] = [.all: events.count]
        for event in events { counts[event.category, default: 0] += 1 }
        chipItems = DeploymentEvent.Category.allCases.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            return ChipBar.Item(id: category, title: category.rawValue, count: count)
        }
        let visible = category == .all ? events : events.filter { $0.category == category }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        sections = grouped.keys.sorted(by: >).map { DaySection(day: $0, events: grouped[$0] ?? []) }
    }
}

/// `Result(catching:)` for async work, so several loads can run with `async let` and fail independently.
private func asyncResult<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await work()) } catch { return .failure(error) }
}
