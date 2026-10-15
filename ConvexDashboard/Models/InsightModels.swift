import Foundation

// Deployment health insights, as shown on the Convex dashboard's Health page. Fetched from the
// dashboard's own (undocumented) API — the same call `npx convex insights` makes. Row and
// detail shapes mirror get-convex/convex-backend npm-packages/dashboard/src/api/insights.ts.

struct Insight: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case documentsReadLimit, bytesReadLimit, occFailedPermanently
        case documentsReadThreshold, bytesReadThreshold, occRetried
    }

    struct HourlyCount: Decodable, Identifiable, Sendable {
        /// "YYYY-MM-DD HH:00:00" (UTC)
        let hour: String
        let count: Int

        var id: String { hour }
        var date: Date? { Self.parser.date(from: hour) }

        private static let parser: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }()
    }

    struct Event: Decodable, Identifiable, Sendable {
        struct TableRead: Decodable, Sendable {
            let tableName: String
            let bytesRead: Double
            let documentsRead: Int

            private enum CodingKeys: String, CodingKey {
                case tableName = "table_name", bytesRead = "bytes_read", documentsRead = "documents_read"
            }
        }

        let id: String
        let timestamp: String
        let requestId: String
        // Write conflicts
        let occDocumentId: String?
        let occWriteSource: String?
        let occRetryCount: Int?
        // Read limits
        let calls: [TableRead]?

        private enum CodingKeys: String, CodingKey {
            case id, timestamp, calls
            case requestId = "request_id"
            case occDocumentId = "occ_document_id"
            case occWriteSource = "occ_write_source"
            case occRetryCount = "occ_retry_count"
        }

        var date: Date? {
            ISO8601DateFormatter().date(from: timestamp) ?? Insight.HourlyCount(hour: timestamp, count: 0).date
        }
    }

    let kind: Kind
    let functionPath: String
    let componentPath: String?
    /// Read-limit insights: number of affected calls. Write conflicts: number of conflicting calls.
    let count: Int
    let occTableName: String?
    let hourlyCounts: [HourlyCount]
    let recentEvents: [Event]

    var id: String { "\(kind.rawValue)|\(componentPath ?? "")|\(functionPath)" }
    var isError: Bool { [.documentsReadLimit, .bytesReadLimit, .occFailedPermanently].contains(kind) }
    var isWriteConflict: Bool { kind == .occRetried || kind == .occFailedPermanently }

    var title: String {
        switch kind {
        case .documentsReadLimit: "Read too many documents"
        case .bytesReadLimit: "Read too much data"
        case .occFailedPermanently: "Write conflicts failed"
        case .documentsReadThreshold: "Nearing document read limit"
        case .bytesReadThreshold: "Nearing data read limit"
        case .occRetried: "Write conflicts retried"
        }
    }

    var summary: String {
        switch kind {
        case .documentsReadLimit, .bytesReadLimit:
            "\(count) call\(count == 1 ? "" : "s") failed by hitting the limit"
        case .documentsReadThreshold, .bytesReadThreshold:
            "\(count) call\(count == 1 ? "" : "s") came close to the limit"
        case .occFailedPermanently:
            "\(count) call\(count == 1 ? "" : "s") failed after retries\(occTableName.map { " · \($0)" } ?? "")"
        case .occRetried:
            "\(count) call\(count == 1 ? "" : "s") retried\(occTableName.map { " · \($0)" } ?? "")"
        }
    }

    var explanation: String {
        switch kind {
        case .documentsReadLimit, .documentsReadThreshold:
            "A single query or mutation can scan at most 32,000 documents. Documents skipped by `.filter()` still count. Use an index (`withIndex`) to narrow the range, or paginate."
        case .bytesReadLimit, .bytesReadThreshold:
            "A single query or mutation can read at most 16 MiB. Data skipped by `.filter()` still counts. Use an index to read less, paginate, or move large fields into separate documents."
        case .occRetried:
            "Two mutations wrote to the same documents at once. Convex retried automatically and they succeeded, but frequent conflicts slow things down. Reduce how often many calls write the same document (e.g. a shared counter)."
        case .occFailedPermanently:
            "Mutations kept conflicting with other writes and failed even after retries. Spread writes across documents (e.g. a sharded counter) or queue them (e.g. Workpool)."
        }
    }

    var learnMoreURL: URL {
        isWriteConflict
            ? URL(string: "https://docs.convex.dev/error#1")!
            : URL(string: "https://docs.convex.dev/production/state/limits#transactions")!
    }

    /// Dashboard API rows: `[kind, functionId, componentPath, detailsJSON]`.
    static func parse(rows: [[String]]) -> [Insight] {
        let decoder = JSONDecoder()
        struct Details: Decodable {
            let count: Int?
            let occCalls: Int?
            let occTableName: String?
            let hourlyCounts: [HourlyCount]?
            let recentEvents: [Event]?
        }
        let order: [Kind] = [.documentsReadLimit, .bytesReadLimit, .occFailedPermanently,
                             .documentsReadThreshold, .bytesReadThreshold, .occRetried]
        return rows.compactMap { row -> Insight? in
            guard row.count >= 4, let kind = Kind(rawValue: row[0]),
                  let details = try? decoder.decode(Details.self, from: Data(row[3].utf8)) else { return nil }
            return Insight(
                kind: kind,
                functionPath: row[1],
                componentPath: row[2] == "-root-component-" ? nil : row[2],
                count: details.count ?? details.occCalls ?? 0,
                occTableName: details.occTableName,
                hourlyCounts: details.hourlyCounts ?? [],
                recentEvents: details.recentEvents ?? []
            )
        }
        .sorted { (order.firstIndex(of: $0.kind) ?? 9, -$0.count) < (order.firstIndex(of: $1.kind) ?? 9, -$1.count) }
    }
}
