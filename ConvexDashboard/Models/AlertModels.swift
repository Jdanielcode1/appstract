import Foundation

/// Mirrors `alertRules` in backend/convex/schema.ts.
struct AlertRule: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable, Decodable {
        case newError
        case errorRate
        case schedulerLag
        case logMatch
        case deploy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newError: "New error"
            case .errorRate: "Error rate"
            case .schedulerLag: "Scheduler lag"
            case .logMatch: "Log match"
            case .deploy: "Deploy"
            }
        }

        var summary: String {
            switch self {
            case .newError: "When a function fails with an error not seen before."
            case .errorRate: "When the share of failing calls crosses a threshold."
            case .schedulerLag: "When scheduled jobs fall behind."
            case .logMatch: "When a console log matches a level, text, or function."
            case .deploy: "When new code is pushed, with what changed (files, indexes, crons, schema)."
            }
        }

        var systemImage: String {
            switch self {
            case .newError: "exclamationmark.octagon"
            case .errorRate: "chart.line.uptrend.xyaxis"
            case .schedulerLag: "clock.badge.exclamationmark"
            case .logMatch: "text.magnifyingglass"
            case .deploy: "arrow.up.circle"
            }
        }
    }

    /// nil for a rule that hasn't been saved yet.
    var id: String?
    var kind: Kind
    var deploymentName: String?
    var enabled: Bool
    var cooldownMinutes: Double
    var threshold: Double?
    var minCalls: Double?
    var windowMinutes: Double?
    var lagSeconds: Double?
    var level: String?
    var pattern: String?
    var path: String?
    /// Deploy rules: skip dev deployments (`npx convex dev` pushes on every save).
    var prodOnly: Bool?

    private enum CodingKeys: String, CodingKey {
        case id = "_id", kind, deploymentName, enabled, cooldownMinutes, threshold, minCalls, windowMinutes
        case lagSeconds, level, pattern, path, prodOnly
    }

    /// A new rule with sensible defaults for its kind.
    static func new(_ kind: Kind) -> AlertRule {
        switch kind {
        case .newError:
            AlertRule(kind: kind, enabled: true, cooldownMinutes: 0)
        case .errorRate:
            AlertRule(kind: kind, enabled: true, cooldownMinutes: 30, threshold: 0.05, minCalls: 20, windowMinutes: 5)
        case .schedulerLag:
            AlertRule(kind: kind, enabled: true, cooldownMinutes: 30, lagSeconds: 60)
        case .logMatch:
            AlertRule(kind: kind, enabled: true, cooldownMinutes: 5, level: "ERROR")
        case .deploy:
            AlertRule(kind: kind, enabled: true, cooldownMinutes: 5, prodOnly: true)
        }
    }

    /// One-line description of what this rule watches.
    var detail: String {
        let scope = deploymentName ?? "all deployments"
        switch kind {
        case .newError:
            return "Any new error · \(scope)"
        case .errorRate:
            return "≥ \(MetricFormat.percent(threshold ?? 0.05)) over \(Int(windowMinutes ?? 5)) min · \(scope)"
        case .schedulerLag:
            return "≥ \(Int(lagSeconds ?? 60))s behind · \(scope)"
        case .logMatch:
            let conditions = [
                level.map { "level \($0)" },
                pattern.flatMap { $0.isEmpty ? nil : "“\($0)”" },
                path.flatMap { $0.isEmpty ? nil : "in \($0)" },
            ].compactMap { $0 }
            return "\(conditions.joined(separator: ", ")) · \(scope)"
        case .deploy:
            return "\(prodOnly == true ? "Production deploys" : "Every push") · \(scope)"
        }
    }

    /// Arguments for `alerts:saveRule` (omitting unset optionals, as Convex validators expect).
    var saveArguments: [String: any Sendable] {
        var args: [String: any Sendable] = [
            "kind": kind.rawValue,
            "enabled": enabled,
            "cooldownMinutes": cooldownMinutes,
        ]
        if let id { args["id"] = id }
        if let deploymentName { args["deploymentName"] = deploymentName }
        if let threshold { args["threshold"] = threshold }
        if let minCalls { args["minCalls"] = minCalls }
        if let windowMinutes { args["windowMinutes"] = windowMinutes }
        if let lagSeconds { args["lagSeconds"] = lagSeconds }
        if let level, !level.isEmpty { args["level"] = level }
        if let pattern, !pattern.isEmpty { args["pattern"] = pattern }
        if let path, !path.isEmpty { args["path"] = path }
        if kind == .deploy, let prodOnly { args["prodOnly"] = prodOnly }
        return args
    }
}

struct AlertEvent: Decodable, Identifiable, Sendable {
    let id: String
    let kind: String
    let deploymentName: String
    let title: String
    let body: String
    let path: String?
    let firedAt: Int64
    let deliveredCount: Int?
    let deliveryError: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id", kind, deploymentName, title, body, path, firedAt, deliveredCount, deliveryError
    }

    var systemImage: String {
        AlertRule.Kind(rawValue: kind)?.systemImage ?? "bell"
    }

    var isTest: Bool { kind == "test" }
    var date: Date { firedAt.dateFromMillis }

    /// Filter bucket on the Alerts tab.
    var category: AlertCategory {
        switch AlertRule.Kind(rawValue: kind) {
        case .newError, .errorRate: .errors
        case .logMatch: .logs
        case .schedulerLag: .scheduler
        case .deploy: .deploys
        case nil: .tests
        }
    }
}

enum AlertCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case errors = "Errors"
    case logs = "Logs"
    case scheduler = "Scheduler"
    case deploys = "Deploys"
    case tests = "Tests"

    var id: String { rawValue }
}

struct AlertStatus: Decodable, Sendable {
    let pushConfigured: Bool
    let deviceCount: Int
}

struct MonitoredDeployment: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let projectName: String?
    let deploymentType: String?

    var id: String { name }
    var label: String {
        guard let projectName else { return name }
        return deploymentType.map { "\(projectName) (\($0))" } ?? projectName
    }
}
