import Foundation
import Observation

/// Every cloud deployment the token can see, across all projects, with filters.
@Observable @MainActor final class TeamDeploymentsViewModel {
    /// Single-select filter chips.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case prod = "Prod"
        case dev = "Dev"
        case preview = "Preview"
        case mine = "Mine"

        var id: String { rawValue }

        func matches(_ row: Row) -> Bool {
            switch self {
            case .all: true
            case .prod: row.deployment.deploymentType == "prod"
            case .dev: row.deployment.deploymentType == "dev"
            case .preview: row.deployment.deploymentType == "preview"
            case .mine: row.isMine
            }
        }
    }

    struct Row: Identifiable {
        let deployment: Deployment
        let project: Project?
        let creatorName: String?
        let isMine: Bool
        /// nil when no monitoring backend is connected.
        let isMonitored: Bool?

        var id: String { deployment.name }
        var projectName: String { project?.name ?? "Unknown project" }

        /// "us-east-1 · S256 · you", precomputed so rows render a single Text.
        let details: String

        init(deployment: Deployment, project: Project?, creatorName: String?, isMine: Bool, isMonitored: Bool?) {
            self.deployment = deployment
            self.project = project
            self.creatorName = creatorName
            self.isMine = isMine
            self.isMonitored = isMonitored
            var parts = [deployment.shortRegion, deployment.class?.uppercased()].compactMap { $0 }
            if deployment.deploymentType == "dev", let owner = isMine ? "you" : creatorName {
                parts.append(owner)
            }
            details = parts.joined(separator: " · ")
        }
    }

    /// Rows grouped by how recently they were deployed.
    struct RecencySection: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    var filter: Filter = .all { didSet { rebuildSections() } }
    var searchText = "" { didSet { rebuildSections() } }

    private(set) var rows: [Row] = [] { didSet { rebuildSections() } }
    /// Filtered + grouped once per change, not on every body evaluation.
    private(set) var sections: [RecencySection] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    /// False when the current member couldn't be identified, so "Mine" isn't offered.
    private(set) var canFilterMine = false

    /// Chips to show, with their counts.
    var availableFilters: [(filter: Filter, count: Int)] {
        Filter.allCases
            .filter { $0 != .mine || canFilterMine }
            .map { filter in (filter, rows.filter(filter.matches).count) }
            // Hide empty chips, and "Mine" when it's everything (a one-person team).
            .filter { $0.filter == .all || ($0.count > 0 && !($0.filter == .mine && $0.count == rows.count)) }
    }

    var isEmpty: Bool { sections.isEmpty }

    @ObservationIgnored private let session: SessionStore.Session

    init(session: SessionStore.Session) {
        self.session = session
    }

    func load(pulse: PulseClient?) async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let client = session.client

        do {
            async let projectsResult = client.projects(for: session.tokenDetails.scope)
            async let monitoredResult = Self.monitoredNames(pulse)

            let projects = try await projectsResult
            let deployments: [Deployment]
            var members: [TeamMember] = []
            switch session.tokenDetails.scope {
            case .team(let teamId):
                async let deploymentsResult = client.allTeamDeployments(teamId: teamId)
                // Member names are a nice-to-have; a token may lack permission to list members.
                async let membersResult = try? client.teamMembers(teamId: teamId)
                deployments = try await deploymentsResult
                members = await membersResult ?? []
            case .project(let projectId):
                deployments = try await client.deployments(projectId: projectId)
                    .sorted { ($0.lastDeployTime ?? 0) > ($1.lastDeployTime ?? 0) }
            }

            let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let membersById = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let myMemberId = Self.currentMemberId(projects: projects, deployments: deployments)
            let monitored = await monitoredResult

            canFilterMine = myMemberId != nil
            if !canFilterMine && filter == .mine { filter = .all }
            rows = deployments.filter(\.isCloud).map { deployment in
                Row(
                    deployment: deployment,
                    project: projectsById[deployment.projectId],
                    creatorName: deployment.creator.flatMap { membersById[$0]?.displayName },
                    isMine: myMemberId != nil && deployment.creator == myMemberId,
                    isMonitored: monitored.map { $0.contains(deployment.name) }
                )
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildSections() {
        let matching = rows.filter { row in
            guard filter.matches(row) else { return false }
            guard !searchText.isEmpty else { return true }
            return row.deployment.name.localizedStandardContains(searchText)
                || row.projectName.localizedStandardContains(searchText)
                || (row.creatorName?.localizedStandardContains(searchText) ?? false)
        }
        let now = Date.now
        let buckets: [(title: String, maxAge: TimeInterval)] = [
            ("Last 24 hours", 86_400), ("This week", 7 * 86_400), ("This month", 30 * 86_400), ("Older", .infinity),
        ]
        var grouped: [String: [Row]] = [:]
        for row in matching {
            let title: String
            if let lastDeploy = row.deployment.lastDeployTime {
                let age = now.timeIntervalSince(lastDeploy.dateFromMillis)
                title = buckets.first { age <= $0.maxAge }?.title ?? "Older"
            } else {
                title = "Never deployed"
            }
            grouped[title, default: []].append(row)
        }
        sections = (buckets.map(\.title) + ["Never deployed"]).compactMap { title in
            grouped[title].map { RecencySection(title: title, rows: $0) }
        }
    }

    /// Each project reports the token owner's own default dev deployment; its creator is "me".
    private nonisolated static func currentMemberId(projects: [Project], deployments: [Deployment]) -> Int? {
        let myDevNames = Set(projects.compactMap(\.devDeploymentName))
        return deployments.first { myDevNames.contains($0.name) && $0.creator != nil }?.creator
    }

    private nonisolated static func monitoredNames(_ pulse: PulseClient?) async -> Set<String>? {
        guard let pulse, let streams = try? await pulse.registeredStreams() else { return nil }
        return Set(streams.map(\.deploymentName))
    }
}
