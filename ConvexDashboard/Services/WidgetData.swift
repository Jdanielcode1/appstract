import Foundation
import WidgetKit

// Compiled into both the app and the widget extension (ConvexWidgets). The widget reads the
// access token (and the monitoring backend's URL + APP_KEY) from the shared keychain group and
// loads its own data, so it stays fresh without the app running.

/// Everything a widget shows for one deployment.
struct DeploymentSnapshot: Sendable {
    let name: String
    let projectName: String?
    let deploymentType: String
    /// "running", "paused", or "disabled"; nil when it couldn't be read.
    let state: String?
    let callsToday: Double?
    let callsMonth: Double?
    /// Last 24h from the monitoring backend; nil when the deployment isn't monitored.
    let errors24h: Int?
    let calls24h: Int?
    /// Highest usage ÷ limit across enabled usage limits.
    let limitFraction: Double?
    let limitName: String?
    let lastDeploy: Date?
    /// Function calls over time; nil when neither source answered.
    let callsChart: WidgetCallsChart?

    var isPaused: Bool { state.map { $0 != "running" } ?? false }
    var title: String { projectName ?? name }

    static let sample = DeploymentSnapshot(
        name: "happy-otter-123", projectName: "my-app", deploymentType: "prod", state: "running",
        callsToday: 12_400, callsMonth: 310_000, errors24h: 3, calls24h: 14_100,
        limitFraction: 0.42, limitName: "Function Calls", lastDeploy: .now.addingTimeInterval(-7_200),
        callsChart: .sample
    )
}

/// Function calls per bucket for the widget chart: hourly for 24h from the monitoring backend, or
/// 5-minute buckets for the last hour from Convex's own metrics (which only keep about an hour).
struct WidgetCallsChart: Sendable {
    struct Bar: Identifiable, Sendable {
        let start: Date
        let calls: Double
        /// Only the monitoring backend counts errors.
        let errors: Double?
        var id: Date { start }
    }

    enum Span: Sendable {
        case day, hour
    }

    let bars: [Bar]
    let span: Span

    var label: String { span == .day ? "Calls · 24h" : "Calls · last hour" }
    var total: Double { bars.reduce(0) { $0 + $1.calls } }

    static let sample: WidgetCallsChart = {
        let hour = Date.now.addingTimeInterval(-23 * 3600)
        let shape: [Double] = [3, 2, 2, 1, 1, 2, 4, 7, 10, 12, 14, 13, 15, 16, 14, 12, 13, 15, 17, 14, 11, 9, 7, 6]
        return WidgetCallsChart(bars: shape.enumerated().map { index, value in
            Bar(start: hour.addingTimeInterval(Double(index) * 3600), calls: value * 40, errors: index == 13 ? 30 : 0)
        }, span: .day)
    }()
}

enum WidgetRefresher {
    /// Call after changing something a widget shows (pause, limits) or the token.
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// A deployment the widget can be configured with.
struct WidgetDeploymentOption: Sendable {
    let name: String
    let projectName: String?
    let deploymentType: String
}

enum WidgetDataError: LocalizedError {
    case signedOut
    case notFound

    var errorDescription: String? {
        switch self {
        case .signedOut: "Open the app and add your access token."
        case .notFound: "This deployment isn't available to your token."
        }
    }
}

/// Talks to the Management and Deployment APIs directly (the widget can't use the app's client,
/// which pulls in the data browser and query runner).
struct WidgetDataSource: Sendable {
    private let token: String
    private let pulse: (url: URL, appKey: String)?
    private let session: URLSession

    init?() {
        guard let token = KeychainStore.load(.convexAccessToken) else { return nil }
        self.token = token
        if let url = KeychainStore.load(.pulseURL).flatMap(URL.init(string:)), let key = KeychainStore.load(.pulseAppKey) {
            pulse = (url, key)
        } else {
            pulse = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    // MARK: Choosing a deployment

    /// Every cloud deployment the token can see, prod first, grouped by project.
    func deploymentOptions() async throws -> [WidgetDeploymentOption] {
        let (deployments, projects) = try await allDeployments()
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return deployments
            .sorted { (names[$0.projectId] ?? "", $0.typeRank) < (names[$1.projectId] ?? "", $1.typeRank) }
            .map { WidgetDeploymentOption(name: $0.name, projectName: names[$0.projectId], deploymentType: $0.deploymentType) }
    }

    /// The production deployment with the most function calls this month (what a new widget shows).
    func mostActiveOption() async throws -> WidgetDeploymentOption? {
        let (deployments, projects) = try await allDeployments()
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // The monitoring backend's own project is busy with webhook traffic, not app data.
        let backendName = pulse?.url.host()?.components(separatedBy: ".").first
        let backendProject = deployments.first { $0.name == backendName }?.projectId
        let candidates = Array(deployments.filter { $0.deploymentType == "prod" && $0.projectId != backendProject }.prefix(8))
        var best: (Deployment, Double)?
        await withTaskGroup(of: (Deployment, Double).self) { group in
            for deployment in candidates {
                guard let url = deployment.deploymentUrl.flatMap(URL.init(string:)) else { continue }
                group.addTask {
                    let usage: CurrentUsage? = try? await self.deploymentGet(url, "get_current_usage")
                    return (deployment, usage?.metrics["functionCalls"]?.usage.currentMonth ?? 0)
                }
            }
            for await result in group where result.1 > (best?.1 ?? -1) {
                best = result
            }
        }
        guard let deployment = best?.0 ?? deployments.first else { return nil }
        return WidgetDeploymentOption(name: deployment.name, projectName: names[deployment.projectId], deploymentType: deployment.deploymentType)
    }

    private func allDeployments() async throws -> ([Deployment], [Project]) {
        let details: TokenDetails = try await management("token_details")
        switch details.scope {
        case .team(let teamId):
            async let projectsPage: PaginatedProjects = management("teams/\(teamId)/projects", query: [URLQueryItem(name: "limit", value: "100")])
            let page: PaginatedDeployments = try await management("teams/\(teamId)/list_deployments", query: [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "sortBy", value: "lastDeployTime"),
                URLQueryItem(name: "sortOrder", value: "desc"),
            ])
            return (page.items.filter { $0.isCloud && $0.deploymentUrl != nil }, try await projectsPage.items)
        case .project(let projectId):
            async let project: Project = management("projects/\(projectId)")
            let deployments: [Deployment] = try await management("projects/\(projectId)/list_deployments")
            return (deployments.filter { $0.isCloud && $0.deploymentUrl != nil }, [try await project])
        }
    }

    // MARK: Snapshot

    func snapshot(name: String, projectName: String?) async throws -> DeploymentSnapshot {
        let deployment: Deployment
        do {
            deployment = try await management("deployments/\(name)")
        } catch WidgetHTTPError.status(404) {
            throw WidgetDataError.notFound
        }
        guard let url = deployment.deploymentUrl.flatMap(URL.init(string:)) else { throw WidgetDataError.notFound }

        // Each piece is optional: a role may allow some endpoints and not others.
        async let usage: CurrentUsage? = try? deploymentGet(url, "get_current_usage")
        async let limits: UsageLimitsResponse? = try? deploymentGet(url, "list_usage_limits")
        async let stateResult = try? deploymentState(url)
        async let healthResult = try? health(name: name)
        async let chartResult = callsChart(name: name, url: url)

        let usageValue = await usage
        let calls = usageValue?.metrics["functionCalls"]?.usage
        let pressure = await limits.flatMap { limitPressure($0.usageLimits, usage: usageValue) }
        let healthValue = await healthResult

        return DeploymentSnapshot(
            name: name,
            projectName: projectName,
            deploymentType: deployment.deploymentType,
            state: await stateResult,
            callsToday: calls?.currentDay,
            callsMonth: calls?.currentMonth,
            errors24h: healthValue?.errors,
            calls24h: healthValue?.calls,
            limitFraction: pressure?.fraction,
            limitName: pressure.map { UsageMetric.displayName($0.metric) },
            lastDeploy: deployment.lastDeployTime?.dateFromMillis,
            callsChart: await chartResult
        )
    }

    private func limitPressure(_ limits: [UsageLimit], usage: CurrentUsage?) -> (fraction: Double, metric: String)? {
        guard let usage else { return nil }
        return limits
            .filter { $0.enabled && $0.limit > 0 }
            .compactMap { limit -> (Double, String)? in
                guard let metric = usage.metrics[limit.metric] else { return nil }
                let used = limit.window == "day" ? metric.usage.currentDay : metric.usage.currentMonth
                return (used / Double(limit.limit), limit.metric)
            }
            .max { $0.0 < $1.0 }
            .map { (fraction: $0.0, metric: $0.1) }
    }

    // MARK: Requests

    private struct Health: Decodable {
        let deploymentName: String
        let calls: Int
        let errors: Int
    }

    private func health(name: String) async throws -> Health? {
        guard let pulse else { return nil }
        let rows: [Health] = try await convexFunction(pulse.url, path: "dashboard:overview", args: ["appKey": pulse.appKey], authorization: nil)
        return rows.first { $0.deploymentName == name }
    }

    private struct TimeseriesRow: Decodable {
        let bucketStart: Double
        let calls: Double
        let errors: Double
    }

    /// 24 hourly bars when the deployment is monitored and had calls, otherwise the last hour.
    private func callsChart(name: String, url: URL) async -> WidgetCallsChart? {
        if let day = try? await hourlyCalls(name: name), day.total > 0 { return day }
        return try? await lastHourCalls(url)
    }

    private func hourlyCalls(name: String) async throws -> WidgetCallsChart? {
        guard let pulse else { return nil }
        let rows: [TimeseriesRow] = try await convexFunction(
            pulse.url, path: "dashboard:timeseries",
            args: ["appKey": pulse.appKey, "deploymentName": name, "window": "24h"], authorization: nil
        )
        // The backend only has rows for hours with traffic; fill the gaps with zero.
        let byStart = Dictionary(rows.map { ($0.bucketStart, $0) }, uniquingKeysWith: { first, _ in first })
        let hourMs = 3_600_000.0
        let currentHour = (Date.now.timeIntervalSince1970 * 1000 / hourMs).rounded(.down) * hourMs
        let bars = (0..<24).map { index in
            let start = currentHour - Double(23 - index) * hourMs
            let row = byStart[start]
            return WidgetCallsChart.Bar(start: Date(timeIntervalSince1970: start / 1000), calls: row?.calls ?? 0, errors: row?.errors ?? 0)
        }
        return WidgetCallsChart(bars: bars, span: .day)
    }

    /// `function_call_count_top_k` in 5-minute buckets; the top functions plus `_rest` add up to all calls.
    private func lastHourCalls(_ base: URL) async throws -> WidgetCallsChart? {
        let now = Date.now
        let window = MetricsWindow(start: now.addingTimeInterval(-3600), end: now, buckets: 12)
        var url = base.appending(path: "api/app_metrics/function_call_count_top_k")
        url.append(queryItems: [URLQueryItem(name: "window", value: window.queryValue), URLQueryItem(name: "k", value: "10")])
        let entries: [TopKEntry] = try await send(URLRequest(url: url), authorization: "Convex \(token)")
        guard let longest = entries.max(by: { $0.buckets.count < $1.buckets.count }), !longest.buckets.isEmpty else { return nil }
        let bars = longest.buckets.indices.map { index in
            WidgetCallsChart.Bar(
                start: longest.buckets[index].date,
                calls: entries.reduce(0) { $0 + (index < $1.buckets.count ? $1.buckets[index].value ?? 0 : 0) },
                errors: nil
            )
        }
        return WidgetCallsChart(bars: bars, span: .hour)
    }

    private func deploymentState(_ url: URL) async throws -> String {
        struct State: Decodable { let state: String }
        let value: State = try await convexFunction(url, path: "_system/frontend/deploymentState:deploymentState", args: [:],
                                                    authorization: "Convex \(token)")
        return value.state
    }

    private func management<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = URL(string: "https://api.convex.dev/v1")!.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        return try await send(URLRequest(url: url), authorization: "Bearer \(token)")
    }

    private func deploymentGet<T: Decodable>(_ base: URL, _ path: String) async throws -> T {
        try await send(URLRequest(url: base.appending(path: "api/v1/\(path)")), authorization: "Convex \(token)")
    }

    /// Convex HTTP API query: `{status, value}` envelope.
    private func convexFunction<T: Decodable>(_ base: URL, path: String, args: [String: String], authorization: String?) async throws -> T {
        var request = URLRequest(url: base.appending(path: "api/query"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "args": args, "format": "json"] as [String: Any])
        let envelope: WidgetEnvelope<T> = try await send(request, authorization: authorization)
        guard envelope.status == "success", let value = envelope.value else { throw WidgetHTTPError.function }
        return value
    }

    private func send<T: Decodable>(_ request: URLRequest, authorization: String?) async throws -> T {
        var request = request
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw WidgetHTTPError.status(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct WidgetEnvelope<T: Decodable>: Decodable {
    let status: String
    let value: T?
}

private enum WidgetHTTPError: Error {
    case status(Int)
    case function
}
