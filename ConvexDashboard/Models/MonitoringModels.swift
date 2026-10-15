import Foundation

/// Anything that can answer "how are this deployment's functions doing?". Screens depend only on
/// this, so new sources (e.g. Axiom's query API) can be added without touching the UI.
protocol MonitoringSource: Sendable {
    func functionSummary(deploymentName: String, window: StatWindow) async throws -> FunctionSummary
    func timeseries(deploymentName: String, window: StatWindow, path: String?) async throws -> [TimeseriesPoint]
    func recentErrors(deploymentName: String, path: String?, limit: Int) async throws -> [FunctionError]
    /// 24h health for every monitored deployment.
    func overview() async throws -> [DeploymentHealth]
    /// Newest first. `level` is one of `LogLevel` raw values, or nil for all.
    func recentLogs(deploymentName: String, level: String?, limit: Int) async throws -> [LogEntry]
}

struct DeploymentHealth: Decodable, Identifiable, Sendable {
    struct FailingFunction: Decodable, Identifiable, Sendable {
        let path: String
        let errors: Int
        let calls: Int
        var id: String { path }
    }

    let deploymentName: String
    let projectName: String?
    let deploymentType: String?
    let lastEventAt: Int64
    let calls: Int
    let errors: Int
    let errorRate: Double
    let p95Ms: Double
    let failingFunctions: [FailingFunction]
    let schedulerLagSeconds: Double?

    var id: String { deploymentName }
}

enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    case error = "ERROR"
    case warn = "WARN"
    case info = "INFO"
    case log = "LOG"
    case debug = "DEBUG"

    var id: String { rawValue }
}

struct LogEntry: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: Int64
    let level: String
    let path: String
    let requestId: String
    let message: String
    let isTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "_id", timestamp, level, path, requestId, message, isTruncated
    }
}

enum StatWindow: String, CaseIterable, Identifiable, Sendable {
    case hour = "1h"
    case day = "24h"
    case week = "7d"

    var id: String { rawValue }
    var label: String { rawValue }
}

struct FunctionStat: Decodable, Identifiable, Hashable, Sendable {
    let path: String
    let type: String
    let calls: Int
    let errors: Int
    let errorRate: Double
    let cachedCalls: Int
    let avgMs: Double
    let p95Ms: Double
    let maxMs: Double
    let dbReadBytes: Double
    let dbWriteBytes: Double
    let docsRead: Int
    let docsWritten: Int
    let egressBytes: Double

    var id: String { path }

    /// `"goals:list"` → module `goals`, name `list`.
    var module: String { path.split(separator: ":").first.map(String.init) ?? path }
    var name: String { path.split(separator: ":").dropFirst().first.map(String.init) ?? path }
}

struct FunctionSummary: Decodable, Sendable {
    struct Totals: Decodable, Sendable {
        let calls: Int
        let errors: Int
        let errorRate: Double
    }

    let functions: [FunctionStat]
    let totals: Totals
}

struct TimeseriesPoint: Decodable, Identifiable, Sendable {
    let bucketStart: Int64
    let calls: Int
    let errors: Int
    let p95Ms: Double

    var id: Int64 { bucketStart }
    var date: Date { bucketStart.dateFromMillis }
}

struct FunctionError: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: Int64
    let path: String
    let type: String
    let requestId: String
    let message: String

    private enum CodingKeys: String, CodingKey {
        case id = "_id", timestamp, path, type, requestId, message
    }

    /// First meaningful line, skipping Convex's "[Request ID: …] Server Error" wrapper.
    var headline: String {
        let lines = message
            .split(separator: "\n")
            .map {
                $0.replacingOccurrences(of: #"^\[Request ID: [^\]]+\] ?"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
        return lines.first { !$0.isEmpty && $0 != "Server Error" } ?? lines.first ?? message
    }
}

enum MetricFormat {
    static func duration(_ ms: Double) -> String {
        ms >= 1000 ? "\((ms / 1000).formatted(.number.precision(.fractionLength(0...1))))s" : "\(Int(ms.rounded()))ms"
    }

    static func percent(_ rate: Double) -> String {
        rate.formatted(.percent.precision(.fractionLength(rate > 0 && rate < 0.01 ? 2...2 : 0...1)))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func bytes(_ value: Double) -> String {
        // The byte formatter renders 0 as "Zero kB".
        guard value >= 1 else { return "0 B" }
        return Int64(value).formatted(.byteCount(style: .binary))
    }
}
