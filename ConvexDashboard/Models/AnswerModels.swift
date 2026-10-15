import Foundation

// Presenting AI answers: the model suggests a display ("ranking of username by orderCount"),
// and the app checks it against the actual result shape, falling back to its own inference.

/// The model's display suggestion (backend/convex/lib/ai.ts `AnswerDisplay`).
struct AnswerDisplay: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case number, ranking, list, text
    }

    let type: Kind
    let title: String?
    let label: String?
    let value: String?
    let unit: String?
}

/// What the app shows for a result.
enum AnswerPresentation {
    struct RankRow: Identifiable {
        let id: Int
        let documentId: String?
        let label: String
        let value: Double
        let valueText: String
        /// Other short fields, e.g. "email: a@b.com".
        let detail: String
    }

    struct ListRow: Identifiable {
        let id: Int
        let documentId: String?
        let title: String
        let subtitle: String
    }

    case number(text: String, unit: String?)
    case text(String)
    case ranking(rows: [RankRow], metric: String, unit: String?)
    case list(rows: [ListRow])
    case record(fields: [(key: String, value: String)])
    case empty

    private static let labelKeys = ["name", "username", "displayName", "fullName", "title", "email", "label", "slug"]

    init(value: JSONValue?, display: AnswerDisplay?) {
        guard let value, value != .null else {
            self = .empty
            return
        }
        switch value {
        case .number(let number):
            self = .number(text: Self.format(number), unit: display?.unit)
        case .object where !value.isContainer:
            self = .number(text: value.preview, unit: display?.unit)  // int64
        case .string(let text):
            self = .text(text)
        case .bool(let flag):
            self = .text(flag ? "Yes" : "No")
        case .array(let items) where items.isEmpty:
            self = .empty
        case .array(let items):
            let objects = items.compactMap { item -> [String: JSONValue]? in
                if case .object(let object) = item, item.isContainer { return object }
                return nil
            }
            guard objects.count == items.count else {
                // An array of scalars: a simple list.
                self = .list(rows: items.enumerated().map { ListRow(id: $0.offset, documentId: nil, title: $0.element.preview, subtitle: "") })
                return
            }
            let label = Self.labelField(display?.label, in: objects)
            if display?.type != .list, let metric = Self.metricField(display?.value, in: objects, sortedHint: display?.type == .ranking) {
                self = .ranking(rows: Self.rankRows(objects, label: label, metric: metric), metric: metric, unit: display?.unit)
            } else {
                self = .list(rows: Self.listRows(objects, label: label))
            }
        case .object(let object):
            // A single number in a one-field object reads better as a number.
            let numbers = object.filter { if case .number = $0.value { true } else { false } }
            if object.count == 1, let (_, only) = numbers.first, case .number(let number) = only {
                self = .number(text: Self.format(number), unit: display?.unit)
            } else {
                self = .record(fields: object.sorted { $0.key < $1.key }.map { ($0.key, Self.text($0.value)) })
            }
        default:
            self = .text(value.preview)
        }
    }

    /// The model's label field if present, else the first name-like string field.
    private static func labelField(_ hint: String?, in objects: [[String: JSONValue]]) -> String? {
        let keys = Set(objects.flatMap(\.keys))
        if let hint, keys.contains(hint) { return hint }
        return labelKeys.first(where: keys.contains)
            ?? keys.sorted().first { key in !key.hasPrefix("_") && objects.contains { if case .string = $0[key] { true } else { false } } }
    }

    /// The model's value field if numeric, else (for rows sorted by a number) the first numeric
    /// field that isn't a timestamp.
    private static func metricField(_ hint: String?, in objects: [[String: JSONValue]], sortedHint: Bool) -> String? {
        let isNumeric: (String) -> Bool = { key in
            objects.allSatisfy { object in
                switch object[key] {
                case .number?, nil, .null?: true
                default: false
                }
            } && objects.contains { if case .number = $0[key] { true } else { false } }
        }
        if let hint, isNumeric(hint) { return hint }
        let candidates = Set(objects.flatMap(\.keys)).sorted().filter { key in
            !key.hasPrefix("_") && isNumeric(key) && !objects.contains { $0[key]?.timestampDate != nil }
        }
        guard let first = candidates.first else { return nil }
        if sortedHint { return first }
        // Without a hint, only call it a ranking when rows are already sorted high → low.
        let values = objects.map { number($0[first]) }
        return zip(values, values.dropFirst()).allSatisfy { $0 >= $1 } && objects.count > 1 ? first : nil
    }

    private static func rankRows(_ objects: [[String: JSONValue]], label: String?, metric: String) -> [RankRow] {
        // Sort first so `id` is the rank.
        objects.sorted { number($0[metric]) > number($1[metric]) }
            .enumerated()
            .map { index, object in
                let value = number(object[metric])
                let detail = object.keys.sorted()
                    .filter { $0 != metric && $0 != label && !$0.hasPrefix("_") }
                    .prefix(2)
                    .compactMap { key in object[key].map { "\(key): \(text($0).prefix(40))" } }
                    .joined(separator: " · ")
                return RankRow(id: index, documentId: documentId(object), label: rowLabel(object, label: label, index: index),
                               value: value, valueText: format(value), detail: detail)
            }
    }

    private static func listRows(_ objects: [[String: JSONValue]], label: String?) -> [ListRow] {
        objects.enumerated().map { index, object in
            let subtitle = object.keys.sorted()
                .filter { $0 != label && !$0.hasPrefix("_") }
                .prefix(3)
                .compactMap { key in object[key].map { "\(key): \(text($0).prefix(40))" } }
                .joined(separator: " · ")
            return ListRow(id: index, documentId: documentId(object), title: rowLabel(object, label: label, index: index), subtitle: subtitle)
        }
    }

    private static func rowLabel(_ object: [String: JSONValue], label: String?, index: Int) -> String {
        if let label, let value = object[label], value != .null, !text(value).isEmpty { return readable(text(value)) }
        if let id = documentId(object) { return id }
        return "Row \(index + 1)"
    }

    /// Auth identities ("https://issuer|subject") are unreadable as names; happens when a join
    /// found no user, so show the subject only.
    private static func readable(_ label: String) -> String {
        guard label.hasPrefix("http"), let bar = label.firstIndex(of: "|") else { return label }
        return "unknown user · \(label[label.index(after: bar)...].prefix(24))"
    }

    /// A Convex document ID in `_id` (or `id`), so the row can open that document.
    private static func documentId(_ object: [String: JSONValue]) -> String? {
        (object["_id"] ?? object["id"])?.documentId
    }

    private static func number(_ value: JSONValue?) -> Double {
        if case .number(let number)? = value { return number }
        return 0
    }

    private static func text(_ value: JSONValue) -> String {
        if let date = value.timestampDate { return date.formatted(date: .abbreviated, time: .shortened) }
        return value.preview
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15
            ? Int64(number).formatted()
            : number.formatted(.number.precision(.fractionLength(0...2)))
    }
}
