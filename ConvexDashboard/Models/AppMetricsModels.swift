import Foundation

// Deployment health charts, from `<deploymentUrl>/api/app_metrics/*` (undocumented; the same
// endpoints the Convex dashboard's Health page uses, `npm-packages/dashboard-common/src/lib/appMetrics.ts`).
// Every endpoint takes `window` = JSON `{start, end, num_buckets}` with Rust-style dates and returns
// per-bucket values (`null` = no data in that bucket). The last bucket is the current, unfinished
// minute: when it has no data yet it's dropped, so lines don't dip to zero at the right edge.

/// The `window` query parameter: the last `duration`, split into `buckets`.
struct MetricsWindow: Sendable {
    let start: Date
    let end: Date
    let buckets: Int

    static func lastHour(now: Date = .now) -> MetricsWindow {
        MetricsWindow(start: now.addingTimeInterval(-3600), end: now, buckets: 60)
    }

    var queryValue: String {
        func serialize(_ date: Date) -> String {
            let seconds = date.timeIntervalSince1970.rounded(.down)
            let nanos = Int((date.timeIntervalSince1970 - seconds) * 1e9)
            return #"{"secs_since_epoch":\#(Int(seconds)),"nanos_since_epoch":\#(nanos)}"#
        }
        return #"{"start":\#(serialize(start)),"end":\#(serialize(end)),"num_buckets":\#(buckets)}"#
    }
}

/// `[{secs_since_epoch, nanos_since_epoch}, number | null]`
struct MetricBucket: Decodable, Sendable {
    let date: Date
    let value: Double?

    init(from decoder: Decoder) throws {
        struct SerializedDate: Decodable {
            let secs_since_epoch: Int64
            let nanos_since_epoch: Int64
        }
        var container = try decoder.unkeyedContainer()
        let serialized = try container.decode(SerializedDate.self)
        date = Date(timeIntervalSince1970: Double(serialized.secs_since_epoch) + Double(serialized.nanos_since_epoch) / 1e9)
        value = try container.decodeNil() ? nil : container.decode(Double.self)
    }
}

/// Top-K responses: `[[functionKey, [bucket]]]`, where `_rest` aggregates everything outside the top K.
struct TopKEntry: Decodable, Sendable {
    let key: String
    let buckets: [MetricBucket]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        key = try container.decode(String.self)
        buckets = try container.decode([MetricBucket].self)
    }
}

struct MetricPoint: Identifiable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// One line on a chart.
struct MetricSeries: Identifiable, Sendable {
    let name: String
    let points: [MetricPoint]
    /// Catch-all line (`_rest`) — drawn in a neutral color, listed last.
    let isRest: Bool
    var id: String { name }

    var total: Double { points.reduce(0) { $0 + $1.value } }
    var latest: Double? { points.last?.value }
    var peak: Double { points.map(\.value).max() ?? 0 }
}

/// Everything the Health charts screen shows.
struct DeploymentMetrics: Sendable {
    var functionCalls: [MetricSeries]
    var failureRate: [MetricSeries]
    var cacheHitRate: [MetricSeries]
    var running: [MetricSeries]
    var queued: [MetricSeries]
    /// Minutes.
    var schedulerLag: [MetricSeries]
}

enum AppMetricsParser {
    /// `"alerts.js:checkThresholds"` → `"alerts:checkThresholds"`; components keep their prefix.
    static func functionName(_ key: String) -> String {
        guard let colon = key.lastIndex(of: ":") else { return key }
        var module = String(key[..<colon])
        for suffix in [".js", ".ts"] where module.hasSuffix(suffix) {
            module.removeLast(suffix.count)
        }
        return module + key[colon...]
    }

    /// Like the dashboard: buckets before the first data point are dropped; later empty buckets
    /// mean "idle" (`idleValue`: 0 calls/failures, 100% cache hits). The fill threshold is shared so
    /// all lines start together.
    static func series(_ entries: [TopKEntry], idleValue: Double, restName: String) -> [MetricSeries] {
        guard let firstData = entries.compactMap({ $0.buckets.firstIndex { $0.value != nil } }).min() else { return [] }
        // The current minute is still filling in; an empty last bucket would read as a drop to idle.
        let bucketCount = entries.map(\.buckets.count).max() ?? 0
        let lastIsEmpty = entries.allSatisfy { $0.buckets.last?.value == nil }
        let dropLast = lastIsEmpty && bucketCount - firstData > 1 ? 1 : 0
        let named = entries.map { entry in
            MetricSeries(
                name: entry.key == "_rest" ? restName : functionName(entry.key),
                points: entry.buckets.dropFirst(firstData).dropLast(dropLast).map { MetricPoint(date: $0.date, value: $0.value ?? idleValue) },
                isRest: entry.key == "_rest"
            )
        }
        // A lone `_rest` line covers every function.
        if named.count == 1, named[0].isRest {
            return [MetricSeries(name: "All functions", points: named[0].points, isRest: true)]
        }
        return named.filter { !$0.isRest } + named.filter(\.isRest)
    }

    /// `function_concurrency`: keys `outstanding_functions:<isolate|node>:<UdfType>:<running|queued>`.
    static func concurrency(_ raw: [String: [MetricBucket]]) -> (running: [MetricSeries], queued: [MetricSeries]) {
        var running: [MetricSeries] = []
        var queued: [MetricSeries] = []
        let dropLast = raw.values.allSatisfy { $0.count > 1 && $0.last?.value == nil } ? 1 : 0
        for (key, buckets) in raw {
            let buckets = buckets.dropLast(dropLast)
            let parts = key.split(separator: ":").map(String.init)
            guard parts.count == 4, parts[0] == "outstanding_functions", let name = typeName(env: parts[1], udfType: parts[2]) else { continue }
            let series = MetricSeries(name: name, points: buckets.map { MetricPoint(date: $0.date, value: $0.value ?? 0) }, isRest: false)
            if parts[3] == "running" { running.append(series) } else if parts[3] == "queued" { queued.append(series) }
        }
        let order = concurrencyTypes
        let sort: (MetricSeries, MetricSeries) -> Bool = { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
        return (running.sorted(by: sort), queued.sorted(by: sort))
    }

    static let concurrencyTypes = ["Queries", "Mutations", "Actions", "Actions (Node)", "HTTP Actions"]

    private static func typeName(env: String, udfType: String) -> String? {
        switch (env, udfType) {
        case ("isolate", "Query"): "Queries"
        case ("isolate", "Mutation"): "Mutations"
        case ("isolate", "Action"): "Actions"
        case ("node", "Action"): "Actions (Node)"
        case ("isolate", "HttpAction"): "HTTP Actions"
        default: nil
        }
    }

    /// `scheduled_job_lag` reports seconds; shown in minutes like the dashboard.
    static func schedulerLag(_ buckets: [MetricBucket]) -> [MetricSeries] {
        guard !buckets.isEmpty else { return [] }
        let buckets = buckets.count > 1 && buckets.last?.value == nil ? buckets.dropLast() : buckets[...]
        return [MetricSeries(name: "Lag", points: buckets.map { MetricPoint(date: $0.date, value: ($0.value ?? 0) / 60) }, isRest: false)]
    }
}
