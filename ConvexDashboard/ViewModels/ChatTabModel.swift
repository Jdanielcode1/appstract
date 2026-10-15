import Foundation
import Observation

/// The Ask AI tab: which deployment the chat is about, chosen from the token's projects.
@Observable @MainActor final class ChatTabModel {
    struct ProjectGroup: Identifiable {
        let project: Project
        let deployments: [Deployment]
        var id: Int { project.id }
    }

    /// Projects ordered by activity (most recent deploy first), deployments likewise.
    private(set) var groups: [ProjectGroup] = []
    /// Deployments chatted with most recently (up to 5), shown above the projects.
    private(set) var recent: [Deployment] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var selected: Deployment?

    @ObservationIgnored private let session: SessionStore.Session
    private static let selectionKey = "chatDeploymentName"

    init(session: SessionStore.Session) {
        self.session = session
    }

    /// The selected project's name, for the toolbar.
    var selectedProjectName: String? {
        guard let selected else { return nil }
        return groups.first { $0.project.id == selected.projectId }?.project.name
    }

    /// The monitoring backend's own deployment. Its project is never chosen by default (it's
    /// this app's backend, not app data), though it can still be picked.
    @ObservationIgnored var backendDeploymentName: String?

    func loadIfNeeded() async {
        guard groups.isEmpty, !isLoading else { return }
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let client = session.client
        do {
            async let projectsResult = client.projects(for: session.tokenDetails.scope)
            let deployments: [Deployment]
            switch session.tokenDetails.scope {
            case .team(let teamId): deployments = try await client.allTeamDeployments(teamId: teamId)
            case .project(let projectId): deployments = try await client.deployments(projectId: projectId)
            }
            projects = try await projectsResult
            self.deployments = deployments.filter { $0.isCloud && $0.deploymentUrl != nil }
            regroup()
            refreshRecent()
            errorMessage = nil
            restoreSelection(from: deployments)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await loadActivity()
    }

    // MARK: Activity

    /// Function calls this month and today per deployment (the same signal Overview uses for
    /// active vs idle). Loaded once per session, 4 at a time.
    private(set) var callsThisMonth: [String: Double] = [:]
    @ObservationIgnored private var callsToday: [String: Double] = [:]
    @ObservationIgnored private var projects: [Project] = []
    @ObservationIgnored private var deployments: [Deployment] = []

    private func loadActivity() async {
        guard callsThisMonth.isEmpty else { return }
        let client = session.client
        let targets = deployments.compactMap { deployment in
            deployment.deploymentUrl.flatMap(URL.init(string:)).map { (deployment.name, $0) }
        }
        var month: [String: Double] = [:]
        var today: [String: Double] = [:]
        await withTaskGroup(of: (String, CurrentUsage?).self) { group in
            var pending = targets[...]
            func addNext() {
                guard let (name, url) = pending.popFirst() else { return }
                group.addTask { (name, try? await client.currentUsage(deploymentURL: url)) }
            }
            for _ in 0..<4 { addNext() }
            for await (name, usage) in group {
                if let calls = usage?.metrics["functionCalls"]?.usage {
                    month[name] = calls.currentMonth
                    today[name] = calls.currentDay
                }
                addNext()
            }
        }
        callsToday = today
        callsThisMonth = month
        regroup()
        // A default picked before activity was known becomes the most active app deployment.
        if isAutomaticSelection, let mostActive = mostActiveDeployment() { selected = mostActive }
    }

    /// The busiest deployment outside the monitoring backend's project.
    private func mostActiveDeployment() -> Deployment? {
        let backendProject = deployments.first { $0.name == backendDeploymentName }?.projectId
        return deployments
            .filter { $0.projectId != backendProject && (callsThisMonth[$0.name] ?? 0) > 0 }
            .max { (callsThisMonth[$0.name] ?? 0) < (callsThisMonth[$1.name] ?? 0) }
    }

    /// Most active first: calls this month, then today, then latest deploy. The monitoring
    /// backend's project goes last: it's this app's backend, not app data.
    private func regroup() {
        let rank: (Deployment) -> (Double, Double, Int64) = { [callsThisMonth, callsToday] deployment in
            (callsThisMonth[deployment.name] ?? 0, callsToday[deployment.name] ?? 0, deployment.lastDeployTime ?? deployment.createTime)
        }
        let byProject = Dictionary(grouping: deployments, by: \.projectId)
        groups = projects
            .compactMap { project in
                guard let list = byProject[project.id], !list.isEmpty else { return nil }
                return ProjectGroup(project: project, deployments: list.sorted { rank($0) > rank($1) })
            }
            .sorted { rank($0.deployments[0]) > rank($1.deployments[0]) }
        if let backend = deployments.first(where: { $0.name == backendDeploymentName })?.projectId,
           let index = groups.firstIndex(where: { $0.project.id == backend }) {
            groups.append(groups.remove(at: index))
        }
    }

    func projectName(for deployment: Deployment) -> String? {
        groups.first { $0.project.id == deployment.projectId }?.project.name
    }

    /// Re-reads recent chats (they change as you ask questions).
    func refreshRecent() {
        let all = groups.flatMap(\.deployments)
        recent = ChatRecents.ordered().prefix(5).compactMap { name in all.first { $0.name == name } }
    }

    /// True while the selection is a default rather than the developer's (or a recent chat's) choice.
    @ObservationIgnored private var isAutomaticSelection = false

    func select(_ deployment: Deployment) {
        isAutomaticSelection = false
        guard deployment.name != selected?.name else { return }
        selected = deployment
        UserDefaults.standard.set(deployment.name, forKey: Self.selectionKey)
    }

    /// The saved choice if it still exists, else the last one chatted with, else the most
    /// recently deployed one.
    private func restoreSelection(from deployments: [Deployment]) {
        let available = groups.flatMap(\.deployments)
        if let saved = UserDefaults.standard.string(forKey: Self.selectionKey),
           let match = available.first(where: { $0.name == saved }) {
            selected = match
        } else if let last = recent.first {
            selected = last
        } else {
            isAutomaticSelection = true
            let backendProject = available.first { $0.name == backendDeploymentName }?.projectId
            selected = available
                .filter { $0.projectId != backendProject }
                .max { ($0.lastDeployTime ?? 0) < ($1.lastDeployTime ?? 0) }
                ?? available.first
        }
    }
}

/// When each deployment was last asked about, on this device (orders the deployment picker).
enum ChatRecents {
    private static let key = "chatRecents"

    static func record(_ deploymentName: String) {
        var dates = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        dates[deploymentName] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: key)
    }

    /// Deployment names, most recently chatted first.
    static func ordered() -> [String] {
        let dates = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return dates.sorted { $0.value > $1.value }.map(\.key)
    }
}
