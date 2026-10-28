import Foundation

/// Calls the user's self-hosted monitoring backend (`backend/`) over the Convex HTTP API
/// (`POST /api/query|mutation`). Every function takes the backend's APP_KEY as `appKey`.
struct PulseClient: Sendable {
    /// e.g. `https://happy-otter-123.convex.cloud`
    let deploymentURL: URL
    private let appKey: String
    private let session: URLSession

    init(deploymentURL: URL, appKey: String, session: URLSession = .shared) {
        self.deploymentURL = deploymentURL
        self.appKey = appKey
        self.session = session
    }

    /// HTTP actions are served from `.convex.site` instead of `.convex.cloud`.
    var siteURL: URL? {
        guard var components = URLComponents(url: deploymentURL, resolvingAgainstBaseURL: false),
              let host = components.host, host.hasSuffix(".convex.cloud") else { return nil }
        components.host = String(host.dropLast(".convex.cloud".count)) + ".convex.site"
        return components.url
    }

    /// The URL a monitored deployment's webhook log stream should post to.
    func webhookURL(forDeployment name: String) -> URL? {
        siteURL?.appending(path: "logs/\(name)")
    }

    func isSameDeployment(as url: URL) -> Bool {
        url.host() == deploymentURL.host()
    }

    // MARK: Functions (backend/convex/streams.ts)

    struct RegisteredStream: Decodable, Sendable {
        let deploymentName: String
        let logStreamId: String
        let createdAt: Double
    }

    func registeredStreams() async throws -> [RegisteredStream] {
        try await call(.query, "streams:list", args: [:])
    }

    func registerStream(deploymentName: String, logStreamId: String, hmacSecret: String) async throws {
        let _: EmptyValue = try await call(.mutation, "streams:register", args: [
            "deploymentName": deploymentName,
            "logStreamId": logStreamId,
            "hmacSecret": hmacSecret,
        ])
    }

    func unregisterStream(deploymentName: String, deleteData: Bool) async throws {
        let _: EmptyValue = try await call(.mutation, "streams:unregister", args: [
            "deploymentName": deploymentName,
            "deleteData": deleteData,
        ])
    }

    // MARK: Lite monitoring (backend/convex/lite.ts)

    struct LiteTarget: Decodable, Sendable {
        let deploymentName: String
        let createdAt: Double
        let lastPolledAt: Double?
        /// Why the last poll failed (e.g. the access token was rejected).
        let lastError: String?
    }

    func liteTargets() async throws -> [LiteTarget] {
        try await call(.query, "lite:list", args: [:])
    }

    /// The backend pulls this deployment's metrics every 5 minutes with `accessToken`.
    func enableLite(deployment: Deployment, deploymentURL: URL, project: Project?, accessToken: String) async throws {
        var args: [String: any Sendable] = [
            "accessToken": accessToken,
            "deploymentName": deployment.name,
            "deploymentUrl": deploymentURL.absoluteString,
            "deploymentType": deployment.deploymentType,
        ]
        if let project {
            args["projectName"] = project.name
            args["projectSlug"] = project.slug
        }
        do {
            let _: EmptyValue = try await call(.mutation, "lite:enable", args: args)
        } catch PulseError.function(let message) where message.contains("Could not find public function") || message.hasSuffix("Server Error") {
            throw PulseError.function("Your monitoring backend needs an update for this. Redeploy it (cd backend && npx convex deploy).")
        }
    }

    func disableLite(deploymentName: String, deleteData: Bool) async throws {
        let _: EmptyValue = try await call(.mutation, "lite:disable", args: [
            "deploymentName": deploymentName,
            "deleteData": deleteData,
        ])
    }

    // MARK: Plumbing

    enum PulseError: LocalizedError {
        case wrongAppKey
        case function(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .wrongAppKey: "The monitoring backend rejected the app key."
            case .function(let message): message
            case .invalidResponse: "Unexpected response from the monitoring backend."
            }
        }
    }

    fileprivate enum Kind: String { case query, mutation, action }

    /// Success: `{"status":"success","value":...}`.
    /// Failure: `{"status":"error","errorMessage":"...","errorData":"Unauthorized"}` (still HTTP 200).
    private struct Envelope<Value: Decodable>: Decodable {
        let status: String
        let value: Value?
        let errorMessage: String?
        let errorData: String?
    }

    /// Convex returns `null` for mutations that return nothing.
    fileprivate struct EmptyValue: Decodable {
        init(from decoder: Decoder) throws {}
    }

    fileprivate func call<T: Decodable>(_ kind: Kind, _ path: String, args: [String: any Sendable]) async throws -> T {
        var allArgs = args
        allArgs["appKey"] = appKey

        var request = URLRequest(url: deploymentURL.appending(path: "api/\(kind.rawValue)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "args": allArgs,
            "format": "json",
        ] as [String: Any])

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw PulseError.invalidResponse
        }

        guard envelope.status == "success" else {
            if envelope.errorData == "Unauthorized" { throw PulseError.wrongAppKey }
            throw PulseError.function(envelope.errorData ?? envelope.errorMessage ?? "Unknown error")
        }
        if let value = envelope.value { return value }
        // `value` is null (mutation returning nothing): decode T from JSON null.
        return try JSONDecoder().decode(T.self, from: Data("null".utf8))
    }
}

// MARK: - Ask AI (backend/convex/ai.ts)

struct GeneratedQuery: Decodable, Sendable {
    let query: String
    let explanation: String
    let display: AnswerDisplay?
}

extension PulseClient {
    /// Plain English → read-only query code, via the backend's Convex AI Gateway action.
    /// Pass `previousQuery` and `error` to have the model fix a failed query.
    func generateQuery(question: String, schema: String, deploymentName: String? = nil, previousQuery: String? = nil,
                       error: String? = nil) async throws -> GeneratedQuery {
        var args: [String: any Sendable] = ["question": question, "schema": schema]
        if let deploymentName { args["deploymentName"] = deploymentName }
        if let previousQuery { args["previousQuery"] = previousQuery }
        if let error { args["error"] = error }
        do {
            return try await call(.action, "ai:generateQuery", args: args)
        } catch PulseError.function(let message) where message.hasSuffix("Server Error") {
            // Production backends hide details; the usual cause is a backend deployed before ai.ts existed.
            throw PulseError.function("The monitoring backend couldn't answer. If you haven't since updating the app, redeploy it (cd backend && npx convex deploy).")
        }
    }
}

// MARK: - Chat and data catalog (backend/convex/chat.ts, catalog.ts)

extension PulseClient {
    /// One chat step: a new question (optionally in an existing thread) or results of the queries
    /// the previous step asked for.
    func chatSend(deploymentName: String, schema: String, threadId: String?, question: String?,
                  toolResults: [ChatToolResult]) async throws -> ChatStepResponse {
        var args: [String: any Sendable] = ["deploymentName": deploymentName, "schema": schema]
        if let threadId { args["threadId"] = threadId }
        if let question { args["question"] = question }
        if !toolResults.isEmpty { args["toolResults"] = toolResults.map(\.arguments) }
        do {
            return try await call(.action, "chat:send", args: args)
        } catch PulseError.function(let message) where message.hasSuffix("Server Error") {
            throw PulseError.function("The monitoring backend couldn't answer. If you haven't since updating the app, redeploy it (cd backend && npx convex deploy).")
        }
    }

    func chatThreads(deploymentName: String) async throws -> [ChatThreadSummary] {
        try await call(.query, "chat:threads", args: ["deploymentName": deploymentName])
    }

    func chatTurns(threadId: String) async throws -> [ChatTurnRecord] {
        try await call(.query, "chat:turns", args: ["threadId": threadId])
    }

    func deleteChatThread(threadId: String) async throws {
        let _: EmptyValue = try await call(.mutation, "chat:deleteThread", args: ["threadId": threadId])
    }

    func catalog(deploymentName: String) async throws -> CatalogInfo? {
        try await call(.query, "catalog:get", args: ["deploymentName": deploymentName])
    }

    /// Sends the app's data profile; the backend writes descriptions with AI and stores the catalog.
    func buildCatalog(deploymentName: String, profile: String) async throws -> CatalogInfo {
        try await call(.action, "catalog:build", args: ["deploymentName": deploymentName, "profile": profile])
    }
}

// MARK: - MonitoringSource (backend/convex/dashboard.ts)

extension PulseClient: MonitoringSource {
    func functionSummary(deploymentName: String, window: StatWindow) async throws -> FunctionSummary {
        try await call(.query, "dashboard:functionSummary", args: [
            "deploymentName": deploymentName,
            "window": window.rawValue,
        ])
    }

    func timeseries(deploymentName: String, window: StatWindow, path: String?) async throws -> [TimeseriesPoint] {
        var args: [String: any Sendable] = ["deploymentName": deploymentName, "window": window.rawValue]
        if let path { args["path"] = path }
        return try await call(.query, "dashboard:timeseries", args: args)
    }

    func recentErrors(deploymentName: String, path: String?, limit: Int) async throws -> [FunctionError] {
        var args: [String: any Sendable] = ["deploymentName": deploymentName, "limit": limit]
        if let path { args["path"] = path }
        return try await call(.query, "dashboard:recentErrors", args: args)
    }

    func overview() async throws -> [DeploymentHealth] {
        try await call(.query, "dashboard:overview", args: [:])
    }

    func recentLogs(deploymentName: String, level: String?, limit: Int) async throws -> [LogEntry] {
        var args: [String: any Sendable] = ["deploymentName": deploymentName, "limit": limit]
        if let level { args["level"] = level }
        return try await call(.query, "dashboard:recentLogs", args: args)
    }
}

// MARK: - Alerts (backend/convex/alerts.ts)

extension PulseClient {
    func alertRules() async throws -> [AlertRule] {
        try await call(.query, "alerts:listRules", args: [:])
    }

    func saveAlertRule(_ rule: AlertRule) async throws {
        let _: String = try await call(.mutation, "alerts:saveRule", args: rule.saveArguments)
    }

    func setAlertRule(id: String, enabled: Bool) async throws {
        let _: EmptyValue = try await call(.mutation, "alerts:setRuleEnabled", args: ["id": id, "enabled": enabled])
    }

    func deleteAlertRule(id: String) async throws {
        let _: EmptyValue = try await call(.mutation, "alerts:deleteRule", args: ["id": id])
    }

    func createDefaultAlertRules() async throws {
        let _: EmptyValue = try await call(.mutation, "alerts:createDefaultRules", args: [:])
    }

    func alertEvents(limit: Int = 50) async throws -> [AlertEvent] {
        try await call(.query, "alerts:recentEvents", args: ["limit": limit])
    }

    func alertStatus() async throws -> AlertStatus {
        try await call(.query, "alerts:status", args: [:])
    }

    func registerDevice(token: String, sandbox: Bool) async throws {
        let _: EmptyValue = try await call(.mutation, "alerts:registerDevice", args: ["token": token, "sandbox": sandbox])
    }

    func sendTestAlert() async throws {
        let _: String = try await call(.mutation, "alerts:sendTest", args: [:])
    }

    func monitoredDeployments() async throws -> [MonitoredDeployment] {
        try await call(.query, "dashboard:deployments", args: [:])
    }
}
