import Foundation

// MARK: - Management API (https://api.convex.dev/v1)

/// Response of `GET /token_details`. A token is scoped to either a team or a single project.
struct TokenDetails: Decodable, Sendable {
    enum Scope: Sendable {
        case team(id: Int)
        case project(id: Int)
    }

    let id: Int
    let name: String
    let createTime: Int64
    let scope: Scope

    private enum CodingKeys: String, CodingKey {
        case id, name, createTime, type, teamId, projectId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createTime = try c.decode(Int64.self, forKey: .createTime)
        switch try c.decode(String.self, forKey: .type) {
        case "projectToken":
            scope = .project(id: try c.decode(Int.self, forKey: .projectId))
        default:
            scope = .team(id: try c.decode(Int.self, forKey: .teamId))
        }
    }
}

struct Project: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let slug: String
    let teamId: Int
    let teamSlug: String
    let createTime: Int64
    let prodDeploymentName: String?
    let devDeploymentName: String?
}

struct PaginatedProjects: Decodable, Sendable {
    struct Pagination: Decodable, Sendable {
        let hasMore: Bool
        let nextCursor: String?
    }

    let items: [Project]
    let pagination: Pagination
}

/// A deployment from `GET /projects/{id}/list_deployments`. The API returns both cloud and
/// local deployments; local ones lack most fields, so everything not shared is optional.
struct Deployment: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let kind: String
    let deploymentType: String
    let projectId: Int
    let createTime: Int64
    let lastDeployTime: Int64?
    let region: String?
    let deploymentUrl: String?
    let isDefault: Bool?
    let reference: String?
    let `class`: String?
    /// Team member who created it (dev deployments belong to their creator).
    let creator: Int?

    var id: String { name }

    /// "aws-us-east-1" → "us-east-1"
    var shortRegion: String? { region.map { $0.hasPrefix("aws-") ? String($0.dropFirst(4)) : $0 } }
    var isCloud: Bool { kind == "cloud" }

    var typeLabel: String {
        switch deploymentType {
        case "prod": "Production"
        case "dev": "Development"
        case "preview": "Preview"
        default: deploymentType.capitalized
        }
    }

    /// Sort order: prod first, then dev, preview, everything else.
    var typeRank: Int {
        ["prod", "dev", "preview"].firstIndex(of: deploymentType) ?? 3
    }
}

// MARK: - Deployment API (https://<deployment>.convex.cloud/api/v1)

/// Response of `GET /get_current_usage`, keyed by metric name (e.g. `functionCalls`).
struct CurrentUsage: Decodable, Sendable {
    struct Metric: Decodable, Sendable {
        struct Window: Decodable, Sendable {
            let currentDay: Double
            let currentMonth: Double

            private enum CodingKeys: String, CodingKey {
                case currentDay = "current_day"
                case currentMonth = "current_month"
            }
        }

        let unit: String
        let usage: Window
    }

    /// `pending` / `partial` mean the backfill is still running and totals may be understated.
    let seedStatus: String
    let metrics: [String: Metric]
}

struct UsageLimit: Decodable, Identifiable, Sendable {
    let id: String
    let metric: String
    let window: String
    let limitType: String
    let limit: Int64
    let enabled: Bool
}

struct UsageLimitsResponse: Decodable, Sendable {
    let usageLimits: [UsageLimit]
}

struct UsageLimitResponse: Decodable, Sendable {
    let usageLimit: UsageLimit
}

/// Body of `create_usage_limit` / `update_usage_limit/{id}`. `limit` is in the metric's usage unit
/// (calls, GB, GB-hours, dollars), the same unit `get_current_usage` reports.
struct UsageLimitConfig: Encodable, Hashable, Sendable {
    var metric: String
    var window: String
    var limitType: String
    var limit: Int64
    var enabled: Bool

    static let metrics = ["functionCalls", "databaseIoGb", "dataEgressGb", "searchQueryGb", "queryMutationComputeGbHours",
                          "actionComputeConvexGbHours", "actionComputeNodeJsGbHours", "actionComputeCpuGbHours", "aiGatewayCostDollars"]

    static let new = UsageLimitConfig(metric: "functionCalls", window: "month", limitType: "warning", limit: 1_000_000, enabled: true)

    init(metric: String, window: String, limitType: String, limit: Int64, enabled: Bool) {
        self.metric = metric
        self.window = window
        self.limitType = limitType
        self.limit = limit
        self.enabled = enabled
    }

    init(_ limit: UsageLimit) {
        self.init(metric: limit.metric, window: limit.window, limitType: limit.limitType, limit: limit.limit, enabled: limit.enabled)
    }

    /// "calls", "GB", "GB-hours", or "USD".
    static func unit(of metric: String) -> String {
        if metric.hasSuffix("GbHours") { return "GB-hours" }
        if metric.hasSuffix("Gb") { return "GB" }
        if metric.hasSuffix("Dollars") { return "USD" }
        return "calls"
    }
}

struct EnvironmentVariablesResponse: Decodable, Sendable {
    let environmentVariables: [String: String]
}

struct PaginatedDeployments: Decodable, Sendable {
    let items: [Deployment]
    let pagination: PaginatedProjects.Pagination
}

/// Response item of `GET /teams/{id}/list_members`.
struct TeamMember: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let email: String
    let role: String

    var displayName: String { name?.isEmpty == false ? name! : email }
}

struct TeamMembersResponse: Decodable, Sendable {
    let items: [TeamMember]
}

/// One entry from `GET /list_log_streams`. Only webhook streams carry `url` and `hmacSecret`.
struct LogStream: Decodable, Identifiable, Sendable {
    struct Status: Decodable, Sendable {
        /// `pending`, `restarting`, `failed`, `active`, …
        let type: String
        /// Present when `type == "failed"`, e.g. "endpoint rejected the request with 404 Not Found".
        let reason: String?
    }

    let id: String
    let logStreamType: String
    let url: String?
    let hmacSecret: String?
    let status: Status?

    var isWebhook: Bool { logStreamType == "webhook" }
    var isFailed: Bool { status?.type == "failed" }
}

/// Response of `POST /create_log_stream` for a webhook stream.
struct CreatedWebhookLogStream: Decodable, Sendable {
    let id: String
    let hmacSecret: String
}

// MARK: - Display helpers

enum UsageMetric {
    static func displayName(_ key: String) -> String {
        switch key {
        case "functionCalls": "Function Calls"
        case "databaseIoGb": "Database I/O"
        case "dataEgressGb": "Data Egress"
        case "searchQueryGb": "Search Queries"
        case "queryMutationComputeGbHours": "Query & Mutation Compute"
        case "actionComputeConvexGbHours": "Action Compute (Convex)"
        case "actionComputeNodeJsGbHours": "Action Compute (Node.js)"
        case "actionComputeCpuGbHours": "Action Compute (CPU)"
        case "aiGatewayCostDollars": "AI Gateway Cost"
        default: key
        }
    }

    static func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "calls":
            value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case "dollars":
            value.formatted(.currency(code: "USD"))
        default:
            "\(value.formatted(.number.precision(.fractionLength(0...3)))) \(unit)"
        }
    }
}

extension Int64 {
    /// Convex timestamps are milliseconds since the epoch.
    var dateFromMillis: Date { Date(timeIntervalSince1970: TimeInterval(self) / 1000) }
}
