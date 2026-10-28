import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "This token is invalid or has been revoked."
        case .forbidden:
            "This token doesn't have permission for that action."
        case .notFound:
            "Not found."
        case .server(let status, let message):
            message ?? "Convex returned an error (HTTP \(status))."
        case .decoding:
            "Unexpected response from Convex."
        case .transport(let error):
            error.localizedDescription
        }
    }
}

/// Single entry point for all Convex Platform API calls. Views and view models never build
/// requests themselves. Read-only: only GET endpoints are used.
struct ConvexAPIClient: Sendable {
    static let managementBaseURL = URL(string: "https://api.convex.dev/v1")!

    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Handed only to the user's own monitoring backend, which polls metrics with it (Lite monitoring).
    var tokenForMonitoringBackend: String { token }

    // MARK: Management API (Authorization: Bearer)

    func tokenDetails() async throws -> TokenDetails {
        try await management("token_details")
    }

    func project(id: Int) async throws -> Project {
        try await management("projects/\(id)")
    }

    /// Follows pagination until every project on the team is loaded.
    func allProjects(teamId: Int) async throws -> [Project] {
        var projects: [Project] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: PaginatedProjects = try await management("teams/\(teamId)/projects", query: query)
            projects += page.items
            cursor = page.pagination.hasMore ? page.pagination.nextCursor : nil
        } while cursor != nil
        return projects
    }

    /// Every project the token can see: the whole team, or the single project of a project token.
    func projects(for scope: TokenDetails.Scope) async throws -> [Project] {
        switch scope {
        case .team(let teamId): try await allProjects(teamId: teamId)
        case .project(let projectId): [try await project(id: projectId)]
        }
    }

    /// Every deployment on the team, most recently deployed first (follows pagination).
    func allTeamDeployments(teamId: Int) async throws -> [Deployment] {
        var deployments: [Deployment] = []
        var cursor: String?
        repeat {
            var query = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "sortBy", value: "lastDeployTime"),
                URLQueryItem(name: "sortOrder", value: "desc"),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: PaginatedDeployments = try await management("teams/\(teamId)/list_deployments", query: query)
            deployments += page.items
            cursor = page.pagination.hasMore ? page.pagination.nextCursor : nil
        } while cursor != nil
        return deployments
    }

    func teamMembers(teamId: Int) async throws -> [TeamMember] {
        let response: TeamMembersResponse = try await management("teams/\(teamId)/list_members")
        return response.items
    }

    func deployment(name: String) async throws -> Deployment {
        try await management("deployments/\(name)")
    }

    func deployments(projectId: Int) async throws -> [Deployment] {
        try await management("projects/\(projectId)/list_deployments")
    }

    // MARK: Dashboard API (undocumented; what the Convex dashboard and `npx convex insights` use)

    static let dashboardBaseURL = URL(string: "https://api.convex.dev/api")!
    private static let insightsQueryId = "9ab3b74e-a725-480b-88a6-43e6bd70bd82"

    /// Health insights (read limits, write conflicts) for the last 72 hours.
    func insights(teamId: Int, deploymentName: String) async throws -> [Insight] {
        // "yyyy-MM-dd" in UTC, matching the CLI.
        let utcDay: (Date) -> String = { date in
            date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        }
        let now = Date.now
        var url = Self.dashboardBaseURL.appending(path: "dashboard/teams/\(teamId)/usage/query")
        url.append(queryItems: [
            URLQueryItem(name: "queryId", value: Self.insightsQueryId),
            URLQueryItem(name: "deploymentName", value: deploymentName),
            URLQueryItem(name: "from", value: utcDay(now.addingTimeInterval(-72 * 3600))),
            URLQueryItem(name: "to", value: utcDay(now)),
        ])
        var request = URLRequest(url: url)
        request.setValue("https://api.convex.dev", forHTTPHeaderField: "Origin")
        let rows: [[String]] = try await send(request, authorization: "Bearer \(token)")
        return Insight.parse(rows: rows)
    }

    // MARK: Deployment API (Authorization: Convex)

    func currentUsage(deploymentURL: URL) async throws -> CurrentUsage {
        try await deployment(deploymentURL, "get_current_usage")
    }

    func usageLimits(deploymentURL: URL) async throws -> [UsageLimit] {
        let response: UsageLimitsResponse = try await deployment(deploymentURL, "list_usage_limits")
        return response.usageLimits
    }

    func createUsageLimit(deploymentURL: URL, _ config: UsageLimitConfig) async throws -> UsageLimit {
        let response: UsageLimitResponse = try await deploymentPost(deploymentURL, "create_usage_limit", body: config)
        return response.usageLimit
    }

    func updateUsageLimit(deploymentURL: URL, id: String, _ config: UsageLimitConfig) async throws -> UsageLimit {
        let response: UsageLimitResponse = try await deploymentPost(deploymentURL, "update_usage_limit/\(id)", body: config)
        return response.usageLimit
    }

    func deleteUsageLimit(deploymentURL: URL, id: String) async throws {
        let _: EmptyResponse = try await deploymentPost(deploymentURL, "delete_usage_limit/\(id)", body: EmptyBody())
    }

    /// Pausing stops new function calls (they error), queues scheduled jobs, and skips crons.
    /// Data is kept and no calls or bandwidth are billed while paused.
    func setPaused(_ paused: Bool, deploymentURL: URL) async throws {
        let _: EmptyResponse = try await deploymentPost(deploymentURL, paused ? "pause_deployment" : "unpause_deployment", body: EmptyBody())
    }

    /// "running", "paused", or "disabled" (the system query the dashboard reads).
    func deploymentState(deploymentURL: URL) async throws -> String {
        struct State: Decodable { let state: String }
        let value: State = try await systemQuery(deploymentURL, "_system/frontend/deploymentState:deploymentState", args: [:])
        return value.state
    }

    func environmentVariables(deploymentURL: URL) async throws -> [String: String] {
        let response: EnvironmentVariablesResponse = try await deployment(deploymentURL, "list_environment_variables")
        return response.environmentVariables
    }

    func logStreams(deploymentURL: URL) async throws -> [LogStream] {
        try await deployment(deploymentURL, "list_log_streams")
    }

    /// Creates a JSON webhook log stream subscribed to all topics. Convex allows only one webhook
    /// stream per deployment, so this fails if one already exists.
    func createWebhookLogStream(deploymentURL: URL, webhookURL: URL) async throws -> CreatedWebhookLogStream {
        struct Body: Encodable {
            let logStreamType = "webhook"
            let url: String
            let format = "json"
        }
        return try await deploymentPost(deploymentURL, "create_log_stream", body: Body(url: webhookURL.absoluteString))
    }

    func deleteLogStream(deploymentURL: URL, id: String) async throws {
        let _: EmptyResponse = try await deploymentPost(deploymentURL, "delete_log_stream/\(id)", body: EmptyBody())
    }

    /// Recent function executions after `cursor` (ms; 0 = everything Convex still holds). See
    /// `FunctionLogsPage`. Long-polls: Convex holds the request until something newer runs, so a
    /// timeout just means "nothing new" and returns an empty page.
    func functionLogs(deploymentURL: URL, cursor: Double) async throws -> FunctionLogsPage {
        var url = deploymentURL.appending(path: "api/stream_function_logs")
        url.append(queryItems: [URLQueryItem(name: "cursor", value: String(cursor))])
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        do {
            return try await send(request, authorization: "Convex \(token)")
        } catch APIError.transport(let error as URLError) where error.code == .timedOut {
            return FunctionLogsPage(entries: [], newCursor: cursor)
        }
    }

    // MARK: App metrics (undocumented; the Convex dashboard's Health charts)

    /// Calls per function (top `k` + `_rest`) per bucket.
    func functionCallCounts(deploymentURL: URL, window: MetricsWindow, k: Int = 5) async throws -> [TopKEntry] {
        try await appMetric(deploymentURL, "function_call_count_top_k", window: window, extra: [URLQueryItem(name: "k", value: "\(k)")])
    }

    /// Failure % (0–100) per function (top `k` + `_rest`).
    func failurePercentages(deploymentURL: URL, window: MetricsWindow, k: Int = 3) async throws -> [TopKEntry] {
        try await appMetric(deploymentURL, "failure_percentage_top_k", window: window, extra: [URLQueryItem(name: "k", value: "\(k)")])
    }

    /// Query cache hit % (0–100) per function (top `k` + `_rest`).
    func cacheHitPercentages(deploymentURL: URL, window: MetricsWindow, k: Int = 3) async throws -> [TopKEntry] {
        try await appMetric(deploymentURL, "cache_hit_percentage_top_k", window: window, extra: [URLQueryItem(name: "k", value: "\(k)")])
    }

    /// Running/queued functions by type, keyed `outstanding_functions:<env>:<type>:<state>`.
    func functionConcurrency(deploymentURL: URL, window: MetricsWindow) async throws -> [String: [MetricBucket]] {
        try await appMetric(deploymentURL, "function_concurrency", window: window)
    }

    /// Scheduled job lag in seconds.
    func schedulerLag(deploymentURL: URL, window: MetricsWindow) async throws -> [MetricBucket] {
        try await appMetric(deploymentURL, "scheduled_job_lag", window: window)
    }

    // MARK: Data (read-only system queries; what the dashboard's Data page and `npx convex data` use)

    /// Table names in the root component, sorted.
    func tables(deploymentURL: URL) async throws -> [String] {
        struct Table: Decodable { let name: String }
        struct Page: Decodable { let page: [Table]; let isDone: Bool; let continueCursor: String }
        var names: [String] = []
        var cursor: JSONValue = .null
        while true {
            let page: Page = try await systemQuery(deploymentURL, "_system/cli/tables", args: [
                "paginationOpts": .object(["cursor": cursor, "numItems": .number(1000)]),
            ])
            names += page.page.map(\.name)
            if page.isDone { break }
            cursor = .string(page.continueCursor)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func tableSize(deploymentURL: URL, table: String) async throws -> Int {
        let size: Double = try await systemQuery(deploymentURL, "_system/frontend/tableSize", args: [
            "tableName": .string(table), "componentId": .null,
        ])
        return Int(size)
    }

    /// One page of a table, newest or oldest first, optionally filtered. Filtering without an
    /// index scans the table, so a page can come back empty while `isDone` is still false.
    func documents(deploymentURL: URL, table: String, filter: DocumentFilter?, indexMatch: IndexMatch? = nil,
                   order: DocumentOrder, cursor: String?, pageSize: Int = 25) async throws -> DocumentPage {
        struct Page: Decodable { let page: [JSONValue]; let isDone: Bool; let continueCursor: String }
        let clauses: [JSONValue] = filter.map { filter in
            [.object([
                "id": .string("0"), "enabled": .bool(true), "field": .string(filter.field),
                "op": .string(filter.op.rawValue), "value": filter.value,
            ])]
        } ?? []
        var expression: [String: JSONValue] = ["clauses": .array(clauses), "order": .string(order.rawValue)]
        if let indexMatch {
            expression["index"] = .object([
                "name": .string(indexMatch.index),
                "clauses": .array([.object(["type": .string("indexEq"), "enabled": .bool(true), "value": .string(indexMatch.value)])]),
            ])
        }
        let page: Page = try await systemQuery(deploymentURL, "_system/frontend/paginatedTableDocuments", args: [
            "table": .string(table),
            "filters": .string(try JSONEncoder().encode(JSONValue.object(expression)).base64EncodedString()),
            "componentId": .null,
            "paginationOpts": .object(["cursor": cursor.map(JSONValue.string) ?? .null, "numItems": .number(Double(pageSize))]),
        ])
        let documents = page.page.compactMap(ConvexDocument.init)
        let errors = page.page.compactMap { value -> String? in
            guard case .object(let object) = value, object["_id"] == nil, case .string(let error)? = object["error"] else { return nil }
            return error
        }
        return DocumentPage(documents: documents, continueCursor: page.isDone ? nil : page.continueCursor,
                            isDone: page.isDone, filterErrors: errors)
    }

    /// Function names by file, e.g. ["orders": ["place (mutation)", "list (query)"]]: hints
    /// about what the data is for, used when building the data catalog.
    func functionNames(deploymentURL: URL) async throws -> [String: [String]] {
        let value: JSONValue = try await systemQuery(deploymentURL, "_system/cli/modules:apiSpec", args: [:])
        var names: [String: [String]] = [:]
        for function in value.array {
            guard let identifier = function["identifier"]?.string, let type = function["functionType"]?.string,
                  ["Query", "Mutation", "Action"].contains(type) else { continue }
            let path = FunctionPath.display(identifier)
            let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
            names[parts[0], default: []].append("\(parts.count > 1 ? parts[1] : "default") (\(type.lowercased()))")
        }
        return names
    }

    /// The active schema (field types and indexes), or nil if the deployment has no schema.
    func schema(deploymentURL: URL) async throws -> DeploymentSchema? {
        struct Schemas: Decodable { let active: String? }
        let schemas: Schemas = try await systemQuery(deploymentURL, "_system/frontend/getSchemas", args: [:])
        return schemas.active.flatMap(DeploymentSchema.init(json:))
    }

    /// Table number → table name, for finding which table a document ID belongs to.
    func tableMapping(deploymentURL: URL) async throws -> [Int: String] {
        let mapping: [String: String] = try await systemQuery(deploymentURL, "_system/frontend/getTableMapping", args: [:])
        return Dictionary(mapping.compactMap { key, name in Int(key).map { ($0, name) } }, uniquingKeysWith: { first, _ in first })
    }

    /// A document by ID from any table, or nil if it doesn't exist.
    func document(deploymentURL: URL, id: String) async throws -> ConvexDocument? {
        let value: JSONValue = try await systemQuery(deploymentURL, "_system/frontend/getById", args: [
            "id": .string(id), "componentId": .null,
        ])
        return ConvexDocument(value)
    }

    // MARK: Schedules & History (read-only system queries; the dashboard's Schedules and History pages)

    /// Every cron job with its last run and next run.
    func cronJobs(deploymentURL: URL) async throws -> [CronJob] {
        let value: JSONValue = try await systemQuery(deploymentURL, "_system/frontend/listCronJobs", args: ["componentId": .null])
        return value.array.compactMap(CronJob.init)
    }

    /// Recent runs of every cron job (Convex keeps the last few per job), newest first.
    func cronRuns(deploymentURL: URL) async throws -> [CronRun] {
        let value: JSONValue = try await systemQuery(deploymentURL, "_system/frontend/listCronJobRuns", args: ["componentId": .null])
        return value.array.compactMap(CronRun.init).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Pending and running scheduled functions, soonest first.
    func scheduledJobs(deploymentURL: URL, cursor: String?, pageSize: Int = 50) async throws -> (jobs: [ScheduledJob], cursor: String?) {
        let value: JSONValue = try await systemQuery(deploymentURL, "_system/frontend/paginatedScheduledJobs", args: [
            "componentId": .null,
            "paginationOpts": .object(["cursor": cursor.map(JSONValue.string) ?? .null, "numItems": .number(Double(pageSize))]),
        ])
        let isDone = value["isDone"] == .bool(true)
        return (value["page"]?.array.compactMap(ScheduledJob.init) ?? [], isDone ? nil : value["continueCursor"]?.string)
    }

    /// The deployment audit log, newest first. Requires the Professional plan.
    func deploymentEvents(deploymentURL: URL, cursor: String?, pageSize: Int = 30) async throws -> (events: [DeploymentEvent], cursor: String?) {
        let value: JSONValue = try await systemQuery(deploymentURL, "_system/frontend/paginatedDeploymentEvents", args: [
            "filters": .object(["minDate": .number(0)]),
            "paginationOpts": .object(["cursor": cursor.map(JSONValue.string) ?? .null, "numItems": .number(Double(pageSize))]),
        ])
        let isDone = value["isDone"] == .bool(true)
        return (value["page"]?.array.compactMap(DeploymentEvent.init) ?? [], isDone ? nil : value["continueCursor"]?.string)
    }

    // MARK: Running queries (sandboxed and read-only)

    /// Runs JavaScript as a sandboxed, read-only query (it can't write or use the network).
    /// With `readBudget`, the query is wrapped to count documents read and fail past the budget
    /// (`OneOffQuerySource.budgetedModule`); `documentsRead` is filled in.
    func runOneOffQuery(deploymentURL: URL, source: String, readBudget: Int? = nil) async -> QueryRunResult {
        var request = URLRequest(url: deploymentURL.appending(path: "api/run_test_function"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(JSONValue.object([
            "adminKey": .string(token),
            "args": .object([:]),
            "bundle": .object(["path": .string("testQuery.js"), "source": .string(
                readBudget.map { OneOffQuerySource.budgetedModule(from: source, limit: $0) } ?? OneOffQuerySource.module(from: source))]),
            "format": .string("convex_encoded_json"),
        ]))
        let result = await run(request, authorization: "Convex \(token)")
        guard readBudget != nil, result.succeeded, let wrapped = result.value else { return result }
        var unwrapped = QueryRunResult(value: wrapped["value"] ?? .null, errorMessage: nil, errorData: nil,
                                       logLines: result.logLines, duration: result.duration)
        unwrapped.documentsRead = wrapped["documentsRead"]?.int64.map(Int.init)
        return unwrapped
    }

    private func run(_ request: URLRequest, authorization: String) async -> QueryRunResult {
        let start = Date()
        do {
            let response: JSONValue = try await send(request, authorization: authorization)
            let duration = Date().timeIntervalSince(start)
            let logs = response["logLines"]?.array.compactMap(\.string) ?? []
            if response["status"]?.string == "success" {
                return QueryRunResult(value: response["value"] ?? .null, errorMessage: nil, errorData: nil, logLines: logs, duration: duration)
            }
            let message = response["errorMessage"]?.string ?? "The query failed."
            return QueryRunResult(value: nil, errorMessage: Self.cleanError(message), errorData: response["errorData"],
                                  logLines: logs, duration: duration)
        } catch {
            return QueryRunResult(value: nil, errorMessage: error.localizedDescription, errorData: nil, logLines: [],
                                  duration: Date().timeIntervalSince(start))
        }
    }

    /// Drops the "[Request ID: …] Server Error" prefix Convex puts on uncaught errors.
    private static func cleanError(_ message: String) -> String {
        var lines = message.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("[Request ID:") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Plumbing

    /// Convex HTTP API query with admin auth. Failures come back as HTTP 200 + `status: "error"`.
    private func systemQuery<T: Decodable>(_ base: URL, _ path: String, args: [String: JSONValue]) async throws -> T {
        var request = URLRequest(url: base.appending(path: "api/query"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "path": .string(path), "args": .object(args), "format": .string("json"),
        ]))
        let response: QueryResponse<T> = try await send(request, authorization: "Convex \(token)")
        guard response.status == "success" else {
            throw APIError.server(status: 200, message: response.errorMessage ?? "The query failed.")
        }
        if let value = response.value { return value }
        if let null = JSONValue.null as? T { return null }
        throw APIError.server(status: 200, message: "The query returned nothing.")
    }

    private func management<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = Self.managementBaseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        return try await get(url, authorization: "Bearer \(token)")
    }

    private func deployment<T: Decodable>(_ base: URL, _ path: String) async throws -> T {
        try await get(base.appending(path: "api/v1/\(path)"), authorization: "Convex \(token)")
    }

    private func appMetric<T: Decodable>(_ base: URL, _ endpoint: String, window: MetricsWindow, extra: [URLQueryItem] = []) async throws -> T {
        var url = base.appending(path: "api/app_metrics/\(endpoint)")
        url.append(queryItems: [URLQueryItem(name: "window", value: window.queryValue)] + extra)
        return try await get(url, authorization: "Convex \(token)")
    }

    private func deploymentPost<T: Decodable>(_ base: URL, _ path: String, body: some Encodable) async throws -> T {
        var request = URLRequest(url: base.appending(path: "api/v1/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, authorization: "Convex \(token)")
    }

    private func get<T: Decodable>(_ url: URL, authorization: String) async throws -> T {
        try await send(URLRequest(url: url), authorization: authorization)
    }

    private func send<T: Decodable>(_ request: URLRequest, authorization: String) async throws -> T {
        var request = request
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            break
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        default:
            throw APIError.server(status: status, message: Self.errorMessage(from: data))
        }

        if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private struct EmptyBody: Encodable {}
    private struct EmptyResponse: Decodable {}

    /// Convex error bodies look like `{"code": "...", "message": "..."}`.
    private static func errorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable { let message: String? }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
    }
}

/// Convex HTTP API response: `{status: "success", value}` or `{status: "error", errorMessage}`.
private struct QueryResponse<T: Decodable>: Decodable {
    let status: String
    let value: T?
    let errorMessage: String?
}

