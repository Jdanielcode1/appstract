import Foundation

// Chat about a deployment's data and its data catalog (backend/convex/chat.ts, catalog.ts).
// The backend talks to the model; this app runs every query with its own token, so the backend
// never touches the deployment's data.

/// One query the model asked the app to run.
struct ChatQuery: Codable, Hashable, Sendable {
    let id: String
    let code: String
    let purpose: String
}

struct ChatAnswer: Codable, Hashable, Sendable {
    let text: String
    /// Which query's result to show under the text.
    let resultOf: String?
    let display: AnswerDisplay?
    let followups: [String]
}

/// One `chat:send` step: either queries to run or the answer.
struct ChatStepResponse: Decodable, Sendable {
    let threadId: String
    let status: String
    let queries: [ChatQuery]
    let answer: ChatAnswer?
}

/// A past question with the queries run and the answer (`chat:turns`).
struct ChatTurnRecord: Decodable, Sendable {
    let question: String
    let queries: [ChatQuery]
    let answer: ChatAnswer?
}

struct ChatThreadSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Double

    private enum CodingKeys: String, CodingKey {
        case id = "_id", title, updatedAt
    }

    var date: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

struct ChatToolResult: Sendable {
    let id: String
    let content: String
    let isError: Bool

    var arguments: [String: any Sendable] { ["id": id, "content": content, "isError": isError] }

    /// The developer chose not to run this query (Run AI queries asks first).
    init(declined id: String) {
        self.id = id
        content = "The developer chose not to run this query. Answer from what you already know, or suggest a narrower question."
        isError = true
    }

    /// What the model sees of a query's result: the first 20 rows (trimmed), or with results
    /// hidden only the row count and field names, so data never reaches the model.
    init(id: String, result: QueryRunResult, shareResults: Bool) {
        self.id = id
        if let error = result.errorMessage {
            content = String(error.prefix(3_000))
            isError = true
            return
        }
        isError = false
        let value = result.value ?? .null
        switch value {
        case .array(let items):
            if shareResults {
                let preview = JSONValue.object(["rows": .number(Double(items.count)), "preview": .array(Array(items.prefix(20)))])
                content = String(JSONValue.compactJSON(preview).prefix(6_000))
            } else {
                let fields = Set(items.prefix(50).flatMap { $0.children.map(\.key) }).sorted()
                content = #"{"rows": \#(items.count), "fields": \#(JSONValue.compactJSON(.array(fields.map(JSONValue.string)))), "note": "contents hidden by the developer's privacy setting"}"#
            }
        default:
            content = shareResults
                ? String(JSONValue.compactJSON(value).prefix(6_000))
                : #"{"type": "\#(value.typeLabel)", "note": "value hidden by the developer's privacy setting"}"#
        }
    }
}

struct CatalogInfo: Decodable, Sendable {
    let builtAt: Double
    let tableCount: Int
    let notes: [String]
    let text: String?

    var date: Date { Date(timeIntervalSince1970: builtAt / 1000) }
}

/// The read-only query that profiles a batch of tables for the catalog: per field, how often it's
/// set, its type and format, and (only when allowed) the values of status-like fields.
enum CatalogProfiler {
    static func source(tables: [String], allTables: [String], shareValues: Bool) -> String {
        let tablesJSON = JSONValue.compactJSON(.array(tables.map(JSONValue.string)))
        let allJSON = JSONValue.compactJSON(.array(allTables.map(JSONValue.string)))
        return #"""
        const tables = \#(tablesJSON);
        const allTables = \#(allJSON);
        const shareValues = \#(shareValues ? "true" : "false");
        const out = {};
        for (const table of tables) {
          const docs = await ctx.db.query(table).order("desc").take(100);
          const byField = {};
          for (const doc of docs) for (const [key, value] of Object.entries(doc)) {
            if (key === "_id" || key === "_creationTime") continue;
            (byField[key] ??= []).push(value);
          }
          const fields = [];
          for (const [name, values] of Object.entries(byField)) {
            const kinds = [...new Set(values.map((v) => (v === null ? "null" : Array.isArray(v) ? "array" : typeof v)))];
            const field = { name, type: kinds.join("|"), fill: docs.length ? values.length / docs.length : 0 };
            const numbers = values.filter((v) => typeof v === "number");
            const strings = values.filter((v) => typeof v === "string");
            if (numbers.length && numbers.every((n) => n > 1e12 && n < 1e13)) field.format = "date";
            if (strings.length) {
              const sample = strings[0];
              const target = allTables.find((t) => ctx.db.normalizeId(t, sample) !== null);
              if (target) field.format = "id:" + target;
              else if (/^https?:\/\/[^|]+\|.+/.test(sample)) field.format = "tokenIdentifier";
              else if (/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(sample)) field.format = "email";
              else if (/^https?:\/\//.test(sample)) field.format = "url";
              else if (strings.every((s) => /^\d{4}-\d{2}-\d{2}/.test(s))) field.format = "date string";
              const counts = new Map();
              for (const s of strings) if (s.trim()) counts.set(s, (counts.get(s) ?? 0) + 1);
              const avg = strings.reduce((n, s) => n + s.length, 0) / strings.length;
              // Only status-like fields: few values that repeat a lot, short, never names or free text.
              const personal = /(name|email|title|text|body|message|bio|description|note|url|picture|image|avatar|key|token|code|id)$/i.test(name);
              if (shareValues && !field.format && !personal && counts.size > 0 && counts.size <= 12 && counts.size * 3 <= strings.length && avg <= 32) {
                field.values = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([s]) => s);
              }
            }
            fields.push(field);
          }
          out[table] = { sampled: docs.length, fields };
        }
        return out;
        """#
    }
}
