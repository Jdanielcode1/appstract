import Foundation

// Schema-aware display for the data browser: field types from `_system/frontend/getSchemas`,
// which table an ID belongs to, references between tables, and per-table card layouts.

/// One table's validator and indexes, from the deployment's active schema.
struct TableSchema: Sendable {
    enum Kind: Hashable, Sendable {
        case id(table: String)
        case string, number, boolean, int64, bytes, null
        /// A union of string literals, e.g. `v.union(v.literal("active"), v.literal("pending"))`.
        case enumeration([String])
        case object, array, record, any
    }

    struct Field: Identifiable, Sendable {
        let name: String
        let kind: Kind
        let isOptional: Bool
        var id: String { name }
    }

    struct Index: Sendable {
        let name: String
        let fields: [String]
    }

    let name: String
    let fields: [Field]
    let indexes: [Index]

    func field(_ name: String) -> Field? {
        fields.first { $0.name == name }
    }

    /// An index whose first field is `field`, for cheap equality lookups.
    func index(startingWith field: String) -> Index? {
        indexes.first { $0.fields.first == field }
    }
}

/// An indexed field in `table` that may hold a reference to another document.
struct ReferenceField: Hashable, Sendable {
    let table: String
    let field: String
    let index: String
    /// Set for `v.id("table")` fields; nil for string fields named like `…Id`.
    let targetTable: String?
}

struct DeploymentSchema: Sendable {
    let tables: [String: TableSchema]

    /// Parses the `active` schema JSON string returned by `getSchemas`.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let tables)? = root["tables"] else { return nil }
        var parsed: [String: TableSchema] = [:]
        for case .object(let table) in tables {
            guard case .string(let name)? = table["tableName"] else { continue }
            var indexes: [TableSchema.Index] = []
            if case .array(let list)? = table["indexes"] {
                for case .object(let index) in list {
                    guard case .string(let indexName)? = index["indexDescriptor"],
                          case .array(let fields)? = index["fields"] else { continue }
                    indexes.append(.init(name: indexName, fields: fields.compactMap { if case .string(let f) = $0 { f } else { nil } }))
                }
            }
            var fields: [TableSchema.Field] = []
            if case .object(let documentType)? = table["documentType"], case .string("object")? = documentType["type"],
               case .object(let properties)? = documentType["value"] {
                for (fieldName, property) in properties.sorted(by: { $0.key < $1.key }) {
                    guard case .object(let property) = property, let fieldType = property["fieldType"] else { continue }
                    let isOptional = property["optional"] == .bool(true)
                    fields.append(.init(name: fieldName, kind: Self.kind(of: fieldType), isOptional: isOptional))
                }
            }
            parsed[name] = TableSchema(name: name, fields: fields, indexes: indexes)
        }
        self.tables = parsed
    }

    private static func kind(of type: JSONValue) -> TableSchema.Kind {
        guard case .object(let object) = type, case .string(let name)? = object["type"] else { return .any }
        switch name {
        case "id":
            if case .string(let table)? = object["tableName"] { return .id(table: table) }
            return .string
        case "string": return .string
        case "number": return .number
        case "boolean": return .boolean
        case "bigint", "int64": return .int64
        case "bytes": return .bytes
        case "null": return .null
        case "object": return .object
        case "array": return .array
        case "record": return .record
        case "literal":
            if case .string(let literal)? = object["value"] { return .enumeration([literal]) }
            return .any
        case "union":
            guard case .array(let members)? = object["value"] else { return .any }
            let kinds = members.map(kind(of:)).filter { $0 != .null }
            let literals = kinds.flatMap { kind -> [String] in
                if case .enumeration(let values) = kind { return values }
                return []
            }
            if !literals.isEmpty, literals.count == kinds.count { return .enumeration(literals) }
            return kinds.count == 1 ? kinds[0] : .any
        default: return .any
        }
    }

    /// Compact text for an AI prompt: one line of fields per table, plus its indexes.
    /// e.g. `users: email: string, isPremium?: boolean, plan: "free" | "pro"` / `indexes: by_email(email)`
    func promptDescription(extraTables: [String] = []) -> String {
        let names = Set(tables.keys).union(extraTables).sorted()
        return names.map { name in
            guard let table = tables[name], !table.fields.isEmpty else { return "\(name): (no schema; any fields)" }
            let fields = table.fields.map { "\($0.name)\($0.isOptional ? "?" : ""): \(Self.describe($0.kind))" }.joined(separator: ", ")
            // Full field lists (Convex appends _creationTime to every index) plus the built-in index,
            // so the model ranges over the right field.
            let indexes = ["by_creation_time(_creationTime)"] + table.indexes.map { "\($0.name)(\($0.fields.joined(separator: ", ")))" }
            return "\(name): \(fields)\n  indexes: \(indexes.joined(separator: "; "))"
        }
        .joined(separator: "\n")
    }

    private static func describe(_ kind: TableSchema.Kind) -> String {
        switch kind {
        case .id(let table): "Id<\(table)>"
        case .enumeration(let values): values.map { "\"\($0)\"" }.joined(separator: " | ")
        case .string: "string"
        case .number: "number"
        case .boolean: "boolean"
        case .int64: "int64"
        case .bytes: "bytes"
        case .null: "null"
        case .object: "object"
        case .array: "array"
        case .record: "record"
        case .any: "any"
        }
    }

    /// Indexed fields that can point at a document: `v.id(...)` fields, plus string fields named
    /// `…Id` (apps often store a user's `tokenIdentifier` or an ID as a plain string).
    var referenceFields: [ReferenceField] {
        tables.values.flatMap { table in
            table.fields.compactMap { field -> ReferenceField? in
                guard let index = table.index(startingWith: field.name) else { return nil }
                switch field.kind {
                case .id(let target):
                    return ReferenceField(table: table.name, field: field.name, index: index.name, targetTable: target)
                case .string where field.name.hasSuffix("Id") || field.name.hasSuffix("ID"):
                    return ReferenceField(table: table.name, field: field.name, index: index.name, targetTable: nil)
                default:
                    return nil
                }
            }
        }
        .sorted { ($0.table, $0.field) < ($1.table, $1.field) }
    }
}

/// Convex document IDs are base32 (Crockford alphabet, lowercase) of a varint table number, the
/// internal ID, and a checksum. The table number maps to a name via `getTableMapping`.
enum ConvexID {
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    static func tableNumber(of id: String) -> Int? {
        var bytes: [UInt8] = []
        var buffer = 0
        var bits = 0
        for character in id {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5 | value) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
            }
            if bytes.count >= 4 { break }
        }
        var number = 0
        var shift = 0
        for byte in bytes {
            number |= Int(byte & 0x7F) << shift
            if byte < 0x80 { return number }
            shift += 7
        }
        return nil
    }
}

/// Which fields a table's cards show. Inferred from the schema and sample documents; the user can
/// override it per table (saved locally).
struct CardLayout: Codable, Equatable, Sendable {
    var title: String?
    var subtitle: String?
    var image: String?
    var badges: [String] = []

    private static let titleKeys = ["name", "displayName", "title", "fullName", "username", "label", "slug", "email", "text", "message", "body", "content"]
    private static let subtitleKeys = ["email", "username", "description", "status", "type", "kind", "slug"]
    private static let imageWords = ["picture", "avatar", "image", "photo", "thumbnail", "icon", "logo"]

    static func inferred(schema: TableSchema?, sample: [ConvexDocument]) -> CardLayout {
        // Field names and kinds from the schema, else from the documents themselves.
        var kinds: [(name: String, kind: TableSchema.Kind)] = schema?.fields.map { ($0.name, $0.kind) } ?? []
        if kinds.isEmpty {
            var seen = Set<String>()
            for document in sample {
                for field in document.userFields where seen.insert(field.key).inserted {
                    kinds.append((field.key, Self.kind(of: field.value)))
                }
            }
            kinds.sort { $0.name < $1.name }
        }
        // Prefer fields that actually have values in the loaded documents.
        let isFilled: (String) -> Bool = { name in
            guard !sample.isEmpty else { return true }
            let filled = sample.filter { document in
                switch document.value(for: name) {
                case .string(let text)?: !text.trimmingCharacters(in: .whitespaces).isEmpty
                case nil, .null?: false
                default: true
                }
            }.count
            return filled * 2 >= sample.count
        }
        let names = kinds.map(\.name).filter(isFilled)
        let strings = kinds.filter { $0.kind == .string && !$0.name.hasSuffix("Id") && !$0.name.lowercased().hasSuffix("url") }
            .map(\.name).filter(isFilled)
        // Exact keys first, then suffix matches like `partnerName` or `ownerUsername`.
        let ranked: ([String]) -> [String] = { keys in
            keys.compactMap { key in names.first { $0 == key } }
                + keys.flatMap { key in names.filter { $0 != key && $0.lowercased().hasSuffix(key.lowercased()) } }
        }

        let title = ranked(titleKeys).first ?? strings.first
        let subtitle = ranked(subtitleKeys).first { $0 != title } ?? strings.first { $0 != title }
        let image = names.first { name in
            let lower = name.lowercased()
            return lower.hasSuffix("url") && imageWords.contains { lower.contains($0) }
        }
        let enums = kinds.filter { if case .enumeration = $0.kind { true } else { false } }.map(\.name)
        let booleans = kinds.filter { $0.kind == .boolean }.map(\.name)
        let badges = Array((enums + booleans).filter { $0 != title && $0 != subtitle }.prefix(3))
        return CardLayout(title: title, subtitle: subtitle, image: image, badges: badges)
    }

    private static func kind(of value: JSONValue) -> TableSchema.Kind {
        switch value {
        case .string: .string
        case .number: .number
        case .bool: .boolean
        case .array: .array
        case .object: .object
        case .null: .null
        }
    }
}

/// Precomputed display values for one card, so rows don't do work in `body`.
struct DocumentCard: Sendable {
    struct Badge: Hashable, Sendable {
        let text: String
        let isFlag: Bool
    }

    let title: String
    let subtitle: String
    let imageURL: URL?
    let initials: String
    let badges: [Badge]

    init(document: ConvexDocument, layout: CardLayout) {
        let value: (String?) -> JSONValue? = { key in key.flatMap { document.value(for: $0) } }
        let text: (JSONValue?) -> String? = { value in
            guard let value, value != .null else { return nil }
            let text = String(value.preview.prefix(120))
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        }
        title = text(value(layout.title)) ?? document.id
        subtitle = text(value(layout.subtitle)) ?? ""
        if case .string(let urlString)? = value(layout.image), urlString.hasPrefix("http") {
            imageURL = URL(string: urlString)
        } else {
            imageURL = nil
        }
        initials = title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        badges = layout.badges.compactMap { key -> Badge? in
            switch document.value(for: key) {
            case .bool(true)?: Badge(text: key, isFlag: true)
            case .string(let value)? where !value.isEmpty: Badge(text: String(value.prefix(24)), isFlag: false)
            case .number(let number)?: Badge(text: "\(key) \(JSONValue.number(number).preview)", isFlag: false)
            default: nil
            }
        }
    }
}

/// Documents in `table` whose indexed `field` equals one of a document's keys.
struct RelatedGroup: Identifiable, Sendable {
    let reference: ReferenceField
    let key: String
    let count: Int
    let hasMore: Bool
    var id: String { "\(reference.table).\(reference.field)" }
}
