import Foundation

// Running queries from the phone: sandboxed, read-only one-off queries via
// `POST /api/run_test_function` (what `npx convex data --query` and the Convex MCP's
// runOneoffQuery use). The sandbox has no write methods, so this can't change data.

/// Outcome of running a query: value or error, plus console output and timing.
struct QueryRunResult: Sendable {
    let value: JSONValue?
    let errorMessage: String?
    let errorData: JSONValue?
    let logLines: [String]
    let duration: TimeInterval
    /// Documents the query read, when it ran with a read budget (AI queries).
    var documentsRead: Int? = nil

    var succeeded: Bool { errorMessage == nil }

    /// "Array of 10 items", "Object with 3 fields", "number".
    var shapeDescription: String {
        guard let value else { return "No value" }
        switch value {
        case .array(let items): return "Array of \(items.count) item\(items.count == 1 ? "" : "s")"
        case .object(let object) where value.isContainer: return "Object with \(object.count) field\(object.count == 1 ? "" : "s")"
        default: return value.typeLabel
        }
    }
}

/// Turns what the user typed into a query module, the same way the Convex CLI does:
/// a single expression is returned, statements become the handler body, and a full module
/// (`export default query(...)`) is used as is.
enum OneOffQuerySource {
    private static let preamble = #"import { query, internalQuery } from "convex:/_system/repl/wrappers.js";"#

    static func module(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("export default"), trimmed.range(of: #"\b(?:query|internalQuery)\s*\("#, options: .regularExpression) != nil {
            return trimmed.contains("convex:/_system/repl/wrappers.js") ? trimmed : "\(preamble)\n\n\(trimmed)"
        }
        return "\(preamble)\n\nexport default query({\n  handler: async (ctx) => {\n\(indent(body(from: trimmed), 4))\n  },\n});"
    }

    /// The handler body: a single expression is returned, statements are used as is. Code written
    /// as a whole handler (`async (ctx) => { ... }`, as models sometimes send it) is called with
    /// `ctx`; used as statements it would just define a function and return nothing.
    static func body(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^(async\s*)?(\(\s*ctx\s*\)|ctx)\s*=>|^async\s+function\s*\w*\s*\(\s*ctx\s*\)"#, options: .regularExpression) != nil {
            let function = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
            return "return await (\(function))(ctx);"
        }
        let isExpression = !trimmed.contains("\n")
            && trimmed.range(of: #"^(const|let|var|if|for|while|switch|try|throw|return)\b"#, options: .regularExpression) == nil
        return isExpression ? "return (\(trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed));" : trimmed
    }

    /// Wraps an AI query with a read budget enforced in code: every document returned by
    /// take/first/unique/collect/paginate/get/async iteration is counted, and the query throws
    /// past `limit` so the model rewrites it. Returns `{ value, documentsRead }`; `undefined`
    /// inside the value becomes null (Convex can't return it). A top-level `undefined` (missing
    /// `return`) or function throws instead, so the model gets an error to fix rather than null.
    static func budgetedModule(from text: String, limit: Int) -> String {
        """
        \(preamble)

        const LIMIT = \(limit);

        export default query({
          handler: async (rawCtx) => {
            let read = 0;
            const count = (n) => {
              read += n;
              if (read > LIMIT) {
                throw new Error(`Read budget exceeded: this query read more than ${LIMIT} documents (the app's limit for this deployment). Narrow it with withIndex, a time range, or a smaller .take().`);
              }
            };
            const size = (r) => (Array.isArray(r) ? r.length : r && Array.isArray(r.page) ? r.page.length : r ? 1 : 0);
            const terminal = new Set(["take", "first", "unique", "collect", "paginate"]);
            const wrapQuery = (q) =>
              new Proxy(q, {
                get(target, prop) {
                  if (prop === Symbol.asyncIterator) {
                    return () => {
                      const it = target[Symbol.asyncIterator]();
                      return {
                        next: async () => {
                          const r = await it.next();
                          if (!r.done) count(1);
                          return r;
                        },
                        [Symbol.asyncIterator]() { return this; },
                      };
                    };
                  }
                  const value = target[prop];
                  if (typeof value !== "function") return value;
                  return (...args) => {
                    const result = value.apply(target, args);
                    if (terminal.has(prop)) return Promise.resolve(result).then((r) => { count(size(r)); return r; });
                    return result && typeof result === "object" && typeof result.then !== "function" ? wrapQuery(result) : result;
                  };
                },
              });
            const db = new Proxy(rawCtx.db, {
              get(target, prop) {
                const value = target[prop];
                if (prop === "query") return (...args) => wrapQuery(value.apply(target, args));
                if (prop === "get") return async (...args) => { const r = await value.apply(target, args); if (r) count(1); return r; };
                return typeof value === "function" ? value.bind(target) : value;
              },
            });
            const clean = (v) =>
              v === undefined ? null
              : Array.isArray(v) ? v.map(clean)
              : v && typeof v === "object" && Object.getPrototypeOf(v) === Object.prototype
                ? Object.fromEntries(Object.entries(v).filter(([, x]) => x !== undefined).map(([k, x]) => [k, clean(x)]))
              : v;
            const ctx = Object.create(rawCtx);
            Object.defineProperty(ctx, "db", { value: db });
            const value = await (async (ctx) => {
        \(indent(body(from: text), 6))
            })(ctx);
            if (value === undefined) {
              throw new Error("The query returned nothing (undefined). End the code with an explicit `return`, and send only the handler body, not a function.");
            }
            if (typeof value === "function") {
              throw new Error("The query returned a function. Send only the handler body (statements ending in `return`), not a function.");
            }
            return { value: clean(value), documentsRead: read };
          },
        });
        """
    }

    private static func indent(_ text: String, _ spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    /// Starter queries; `TABLE` is replaced with the chosen table.
    static let templates: [(title: String, source: String)] = [
        ("Latest 10", #"await ctx.db.query("TABLE").order("desc").take(10)"#),
        ("Count (up to 10k)", #"(await ctx.db.query("TABLE").take(10000)).length"#),
        ("First match", "await ctx.db.query(\"TABLE\")\n  .filter((q) => q.eq(q.field(\"email\"), \"someone@example.com\"))\n  .first()"),
        ("Created today", "const start = new Date().setHours(0, 0, 0, 0);\nconst docs = await ctx.db.query(\"TABLE\")\n  .filter((q) => q.gte(q.field(\"_creationTime\"), start))\n  .collect();\nreturn docs.length;"),
    ]
}

/// A query saved for one-tap runs (stored on this device).
struct SavedQuery: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var deploymentName: String
    var deploymentURL: URL
    var source: String
    /// For queries written by Ask: the question, and how to present the answer.
    var question: String?
    var display: AnswerDisplay?

    var subtitle: String {
        source.replacingOccurrences(of: "\n", with: " ")
    }

    init(name: String, deploymentName: String, deploymentURL: URL, source: String, question: String? = nil, display: AnswerDisplay? = nil) {
        self.name = name
        self.deploymentName = deploymentName
        self.deploymentURL = deploymentURL
        self.source = source
        self.question = question
        self.display = display
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, deploymentName, deploymentURL, source, kind, question, display
    }

    /// Also reads the earlier format, `"kind": {"oneOff": {"source": …}}`.
    init(from decoder: Decoder) throws {
        struct Legacy: Decodable {
            struct OneOff: Decodable { let source: String }
            let oneOff: OneOff?
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        deploymentName = try container.decode(String.self, forKey: .deploymentName)
        deploymentURL = try container.decode(URL.self, forKey: .deploymentURL)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        display = try? container.decodeIfPresent(AnswerDisplay.self, forKey: .display)
        if let source = try container.decodeIfPresent(String.self, forKey: .source) {
            self.source = source
        } else if let source = try container.decodeIfPresent(Legacy.self, forKey: .kind)?.oneOff?.source {
            self.source = source
        } else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "Not a one-off query")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(deploymentName, forKey: .deploymentName)
        try container.encode(deploymentURL, forKey: .deploymentURL)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(question, forKey: .question)
        try container.encodeIfPresent(display, forKey: .display)
    }
}
