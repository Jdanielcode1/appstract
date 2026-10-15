import Foundation

// Read-only data browsing via the deployment's system queries — the same ones the dashboard's
// Data page and `npx convex data` call (get-convex/convex-backend
// npm-packages/system-udfs/convex/_system/frontend). Values arrive in Convex's JSON format.

/// Any JSON value. Convex-specific encodings (`{"$integer": …}`, `{"$bytes": …}`) stay objects
/// and are recognized when displayed.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses text typed into a filter: `true`/`false`/`null`, numbers, and JSON (e.g. `"42"` to
    /// match a string of digits) are typed; anything else is a plain string.
    init(userInput text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            self = value
        } else {
            self = .string(trimmed)
        }
    }

    var isContainer: Bool {
        switch self {
        case .array: true
        case .object: convexScalar == nil
        default: false
        }
    }

    /// `{"$integer": base64}` (little-endian Int64) or `{"$bytes": base64}`, as display text.
    private var convexScalar: String? {
        guard case .object(let object) = self, object.count == 1,
              let (key, value) = object.first, case .string(let base64) = value,
              let data = Data(base64Encoded: base64) else { return nil }
        switch key {
        case "$integer" where data.count == 8:
            let int = data.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return "\(Int64(bitPattern: int))n"
        case "$bytes":
            return "bytes(\(data.count))"
        default:
            return nil
        }
    }

    /// One line for list rows and field values.
    var preview: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return Self.format(value)
        case .string(let value): return value
        case .array(let items): return "[\(items.count) item\(items.count == 1 ? "" : "s")]"
        case .object(let object):
            return convexScalar ?? "{\(object.count) field\(object.count == 1 ? "" : "s")}"
        }
    }

    /// Short type label shown next to field names.
    var typeLabel: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: convexScalar.map { $0.hasPrefix("bytes") ? "bytes" : "int64" } ?? "object"
        }
    }

    /// Children of an array (indexed) or object (sorted by key).
    var children: [(key: String, value: JSONValue)] {
        switch self {
        case .array(let items): items.enumerated().map { ("\($0.offset)", $0.element) }
        case .object(let object) where convexScalar == nil: object.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        default: []
        }
    }

    /// A millisecond timestamp in a plausible range (2001–2286), for showing dates beside numbers.
    var timestampDate: Date? {
        guard case .number(let value) = self, value > 1e12, value < 1e13 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    /// Looks like a Convex document ID (base32 lowercase, ~32 chars), so it can be followed.
    var documentId: String? {
        guard case .string(let value) = self, (31...37).contains(value.count),
              value.allSatisfy({ $0.isLowercase || $0.isNumber }) else { return nil }
        return value
    }

    /// Pretty-printed JSON for copying/sharing.
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? preview
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

/// One document: `_id` and `_creationTime` first, then fields alphabetically (like the CLI).
struct ConvexDocument: Identifiable, Sendable {
    let id: String
    let creationTime: Date?
    let fields: [(key: String, value: JSONValue)]
    let raw: JSONValue

    init?(_ value: JSONValue) {
        guard case .object(let object) = value, case .string(let id)? = object["_id"] else { return nil }
        self.id = id
        self.raw = value
        if case .number(let ms)? = object["_creationTime"] {
            creationTime = Date(timeIntervalSince1970: ms / 1000)
        } else {
            creationTime = nil
        }
        let system = ["_id", "_creationTime"].compactMap { key in object[key].map { (key: key, value: $0) } }
        fields = system + object.filter { $0.key != "_id" && $0.key != "_creationTime" }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    /// Fields other than `_id` and `_creationTime`.
    var userFields: [(key: String, value: JSONValue)] {
        fields.filter { $0.key != "_id" && $0.key != "_creationTime" }
    }

    func value(for key: String) -> JSONValue? {
        fields.first { $0.key == key }?.value
    }
}

extension ConvexDocument: Hashable {
    static func == (lhs: ConvexDocument, rhs: ConvexDocument) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A single-clause filter, as the dashboard's filter bar encodes it.
struct DocumentFilter: Equatable, Sendable {
    enum Operator: String, CaseIterable, Identifiable, Sendable {
        case eq, neq, gt, gte, lt, lte
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .eq: "="
            case .neq: "≠"
            case .gt: ">"
            case .gte: "≥"
            case .lt: "<"
            case .lte: "≤"
            }
        }
    }

    var field: String
    var op: Operator
    var value: JSONValue

    var label: String {
        let shown = if case .string(let text) = value { "\"\(text)\"" } else { value.preview }
        return "\(field) \(op.symbol) \(shown)"
    }
}

enum DocumentOrder: String, Sendable {
    case desc, asc
}

/// Equality on the first field of an index: cheap, reads only matching documents.
struct IndexMatch: Equatable, Sendable {
    let index: String
    let field: String
    let value: String

    var label: String { "\(field) = \"\(value)\"" }
}

struct DocumentPage: Sendable {
    let documents: [ConvexDocument]
    let continueCursor: String?
    let isDone: Bool
    /// Filter problems reported by Convex (e.g. an invalid ID), returned in place of documents.
    let filterErrors: [String]
}

extension JSONValue {
    /// Single-line JSON with sorted keys.
    static func compactJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
