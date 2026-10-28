import Foundation

/// `GET <deploymentUrl>/api/stream_function_logs?cursor=<ms>` (undocumented; what the dashboard Logs
/// page, `npx convex logs` and Convex's MCP `logs` tool read). Returns the deployment's recent
/// in-memory log buffer (about the last 1,000 executions, cleared on Convex updates) after `cursor`.
/// Free on every plan and not billed as function calls; nothing is stored anywhere.
/// Schema: `convex` npm `dist/cjs-types/cli/lib/generatedFunctionLogsApi.d.ts`.
struct FunctionLogsPage: Decodable, Sendable {
    let entries: [FunctionExecution]
    let newCursor: Double
}

/// One function execution (`kind: Completion`) or log lines from one still running (`Progress`).
struct FunctionExecution: Decodable, Sendable {
    let kind: String
    let udfType: String
    let identifier: String
    let logLines: [FunctionLogLine]
    /// Seconds since epoch.
    let timestamp: Double
    /// Seconds. Completion only.
    let executionTime: Double?
    let error: String?
    let requestId: String
    let executionId: String
    let caller: String?
    let cachedResult: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, udfType, identifier, logLines, timestamp, executionTime, error, requestId, executionId, caller, cachedResult
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        udfType = try c.decode(String.self, forKey: .udfType)
        identifier = try c.decode(String.self, forKey: .identifier)
        // Skip lines in a shape we don't know rather than dropping the whole page.
        logLines = (try? c.decode([FailableLine].self, forKey: .logLines))?.compactMap(\.line) ?? []
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        executionTime = try c.decodeIfPresent(Double.self, forKey: .executionTime)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        requestId = try c.decode(String.self, forKey: .requestId)
        executionId = try c.decode(String.self, forKey: .executionId)
        caller = try c.decodeIfPresent(String.self, forKey: .caller)
        cachedResult = try c.decodeIfPresent(Bool.self, forKey: .cachedResult)
    }

    private struct FailableLine: Decodable {
        let line: FunctionLogLine?
        init(from decoder: Decoder) throws { line = try? FunctionLogLine(from: decoder) }
    }
}

/// Structured `{messages, level, timestamp (ms), isTruncated}`, or an older `"[LEVEL] message"` string.
struct FunctionLogLine: Decodable, Sendable {
    let level: String
    let message: String
    let timestamp: Double?
    let isTruncated: Bool

    private enum CodingKeys: String, CodingKey { case messages, level, timestamp, isTruncated }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            if let range = text.range(of: #"^\[\w+\] "#, options: .regularExpression) {
                level = String(text[range].dropFirst().dropLast(2))
                message = String(text[range.upperBound...])
            } else {
                level = "LOG"
                message = text
            }
            timestamp = nil
            isTruncated = false
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(String.self, forKey: .level)
        message = try c.decode([String].self, forKey: .messages).joined(separator: " ")
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        isTruncated = try c.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    }
}

/// A row in Live Logs: one execution with its console lines and outcome.
struct LiveLogItem: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable { case success, failure, running }

    struct Line: Hashable, Sendable {
        let level: String
        let message: String
        let isTruncated: Bool
    }

    let id: String
    let date: Date
    /// `"messages:send"` (file extension dropped, like the dashboard).
    let path: String
    /// `query`, `mutation`, `action`, `http_action` (as `FunctionTypeBadge` expects).
    let type: String
    let outcome: Outcome
    let durationMs: Double?
    let error: String?
    let lines: [Line]
    let requestId: String
    let caller: String?
    let isCached: Bool

    init(_ execution: FunctionExecution) {
        id = "\(execution.executionId)-\(execution.kind)-\(execution.timestamp)"
        date = Date(timeIntervalSince1970: execution.timestamp)
        path = Self.path(execution.identifier)
        type = Self.type(execution.udfType)
        outcome = execution.kind == "Progress" ? .running : (execution.error == nil ? .success : .failure)
        durationMs = execution.executionTime.map { $0 * 1000 }
        error = execution.error
        lines = execution.logLines.map { Line(level: $0.level, message: $0.message, isTruncated: $0.isTruncated) }
        requestId = execution.requestId
        caller = execution.caller
        isCached = execution.cachedResult ?? false
    }

    var hasLogs: Bool { !lines.isEmpty }

    /// Text the search box matches.
    var searchText: String {
        ([path, error ?? ""] + lines.map(\.message)).joined(separator: "\n")
    }

    static func path(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: #"\.(js|ts|mjs|cjs|jsx|tsx):"#, with: ":", options: .regularExpression)
    }

    static func type(_ udfType: String) -> String {
        switch udfType {
        case "Query": "query"
        case "Mutation": "mutation"
        case "Action": "action"
        case "HttpAction": "http_action"
        default: udfType.lowercased()
        }
    }
}
