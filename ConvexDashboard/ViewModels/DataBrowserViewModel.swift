import Foundation
import Observation

/// Shared by every data browser screen for one deployment: schema, table-number mapping, and
/// card layouts. Injected with `.environment` from `DataBrowserView`.
@Observable @MainActor final class DataContext {
    private(set) var schema: DeploymentSchema?
    private(set) var tableNames: [Int: String] = [:]

    @ObservationIgnored let deploymentURL: URL
    @ObservationIgnored let client: ConvexAPIClient
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var hintsTask: Task<String, Never>?

    init(deploymentURL: URL, client: ConvexAPIClient) {
        self.deploymentURL = deploymentURL
        self.client = client
    }

    /// Loads the schema and table mapping once; later calls wait for the same load.
    func loadMetadata() async {
        if metadataTask == nil {
            let client = client
            let url = deploymentURL
            metadataTask = Task {
                async let schema = try? client.schema(deploymentURL: url)
                async let mapping = try? client.tableMapping(deploymentURL: url)
                self.schema = await schema ?? nil
                self.tableNames = await mapping ?? [:]
            }
        }
        await metadataTask?.value
    }

    // MARK: AI prompt context

    /// Schema text for AI prompts: every table's fields and indexes plus reference hints.
    func promptSchema(tables: [String]) async -> String {
        await loadMetadata()
        var schema = self.schema?.promptDescription(extraTables: tables)
            ?? tables.map { "\($0): (no schema; any fields)" }.joined(separator: "\n")
        let hints = await referenceHints()
        if !hints.isEmpty { schema += "\n\n" + hints }
        return schema
    }

    // MARK: Reference hints (for AI queries)

    /// What string `…Id` fields actually hold (a users _id, a tokenIdentifier, plain text),
    /// detected by one read-only query over the newest document of each table. Only the
    /// classification goes into the AI prompt, never the values. Cached per deployment.
    func referenceHints() async -> String {
        if hintsTask == nil {
            await loadMetadata()
            guard let schema else { return "" }
            let client = client
            let url = deploymentURL
            let checks = schema.tables.values.reduce(into: [String: [String]]()) { result, table in
                let fields = table.fields.filter { field in
                    field.kind == .string && (field.name.hasSuffix("Id") || field.name.hasSuffix("ID"))
                }.map(\.name)
                if !fields.isEmpty { result[table.name] = fields.sorted() }
            }
            // Tables that store auth identities, e.g. users.tokenIdentifier with index by_token.
            let identity = schema.tables.values.sorted { $0.name < $1.name }.compactMap { table -> String? in
                guard table.field("tokenIdentifier") != nil else { return nil }
                let index = table.index(startingWith: "tokenIdentifier").map { "; join with \(table.name).\($0.name)" } ?? ""
                return "\(table.name).tokenIdentifier\(index)"
            }.first
            let tables = Array(Set(schema.tables.keys).union(tableNames.values)).sorted()
            hintsTask = Task {
                guard !checks.isEmpty,
                      let checksJSON = String(data: (try? JSONEncoder().encode(checks)) ?? Data(), encoding: .utf8),
                      let tablesJSON = String(data: (try? JSONEncoder().encode(tables)) ?? Data(), encoding: .utf8) else { return "" }
                let source = """
                const checks = \(checksJSON);
                const tables = \(tablesJSON);
                const out = {};
                for (const [table, fields] of Object.entries(checks)) {
                  const doc = await ctx.db.query(table).order("desc").first();
                  if (!doc) continue;
                  for (const field of fields) {
                    const value = doc[field];
                    if (typeof value !== "string" || value.length === 0) continue;
                    const target = tables.find((t) => ctx.db.normalizeId(t, value) !== null);
                    if (target) out[table + "." + field] = "id:" + target;
                    else if (/^https?:\\/\\/[^|]+\\|.+/.test(value)) out[table + "." + field] = "tokenIdentifier";
                    else if (/^user_[A-Za-z0-9]+$/.test(value)) out[table + "." + field] = "clerkUserId";
                    else out[table + "." + field] = "string";
                  }
                }
                return out;
                """
                let result = await client.runOneOffQuery(deploymentURL: url, source: source)
                return Self.describeHints(result.value, identity: identity)
            }
        }
        return await hintsTask?.value ?? ""
    }

    private static func describeHints(_ value: JSONValue?, identity: String?) -> String {
        guard case .object(let hints)? = value, !hints.isEmpty else { return "" }
        let fields: (String) -> [String] = { kind in hints.filter { $0.value.string == kind }.map(\.key).sorted() }
        var lines = ["Reference hints (detected from the newest document in each table):"]
        let tokens = fields("tokenIdentifier")
        if !tokens.isEmpty {
            let target = identity.map { "holds \($0)" } ?? "holds an auth tokenIdentifier"
            lines.append("- \(target) (an auth identity string, not an _id): \(tokens.joined(separator: ", "))")
        }
        let ids = hints.compactMap { key, kind -> String? in
            guard let kind = kind.string, kind.hasPrefix("id:") else { return nil }
            return "\(key) → \(kind.dropFirst(3)) _id"
        }.sorted()
        if !ids.isEmpty { lines.append("- holds a document _id: \(ids.joined(separator: ", "))") }
        let clerk = fields("clerkUserId")
        if !clerk.isEmpty { lines.append("- holds a Clerk user ID (user_…): \(clerk.joined(separator: ", "))") }
        let plain = fields("string")
        if !plain.isEmpty { lines.append("- plain strings, not IDs: \(plain.joined(separator: ", "))") }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    func tableName(forDocumentId id: String) -> String? {
        ConvexID.tableNumber(of: id).flatMap { tableNames[$0] }
    }

    // MARK: Card layouts

    func layout(for table: String, sample: [ConvexDocument]) -> CardLayout {
        savedLayout(for: table) ?? CardLayout.inferred(schema: schema?.tables[table], sample: sample)
    }

    func isCustomized(_ table: String) -> Bool {
        savedLayout(for: table) != nil
    }

    func saveLayout(_ layout: CardLayout?, for table: String) {
        let key = layoutKey(table)
        if let layout, let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func savedLayout(for table: String) -> CardLayout? {
        UserDefaults.standard.data(forKey: layoutKey(table)).flatMap { try? JSONDecoder().decode(CardLayout.self, from: $0) }
    }

    private func layoutKey(_ table: String) -> String {
        "cardLayout.\(deploymentURL.host() ?? "").\(table)"
    }

    // MARK: Related documents

    /// Fields that commonly hold a user's auth identity, which other tables store instead of `_id`.
    private static let identityFields = ["tokenIdentifier", "externalId", "clerkId", "clerkUserId", "authId", "subject"]
    private static let relatedLimit = 25

    /// Searches every indexed reference field for this document's `_id` (and identity values like
    /// `tokenIdentifier`). Each lookup is an index equality read, so it only reads matches.
    func relatedGroups(for document: ConvexDocument, in table: String?) async -> [RelatedGroup] {
        await loadMetadata()
        guard let schema else { return [] }
        let identityKeys = Self.identityFields.compactMap { field -> String? in
            if case .string(let value)? = document.value(for: field), !value.isEmpty { return value }
            return nil
        }
        var lookups: [(ReferenceField, String)] = []
        for reference in schema.referenceFields {
            if let target = reference.targetTable {
                if target == table { lookups.append((reference, document.id)) }
            } else {
                for key in [document.id] + identityKeys { lookups.append((reference, key)) }
            }
        }

        let client = client
        let url = deploymentURL
        let limit = Self.relatedLimit
        var groups: [RelatedGroup] = []
        await withTaskGroup(of: RelatedGroup?.self) { group in
            var pending = lookups[...]
            func addNext() {
                guard let (reference, key) = pending.popFirst() else { return }
                group.addTask {
                    let match = IndexMatch(index: reference.index, field: reference.field, value: key)
                    guard let page = try? await client.documents(deploymentURL: url, table: reference.table, filter: nil,
                                                                 indexMatch: match, order: .desc, cursor: nil,
                                                                 pageSize: limit + 1),
                          !page.documents.isEmpty else { return nil }
                    return RelatedGroup(reference: reference, key: key, count: min(page.documents.count, limit),
                                        hasMore: page.documents.count > limit)
                }
            }
            for _ in 0..<4 { addNext() }
            for await result in group {
                if let result { groups.append(result) }
                addNext()
            }
        }
        return groups.sorted { ($0.reference.table, $0.reference.field) < ($1.reference.table, $1.reference.field) }
    }
}

/// Tables of one deployment, with row counts.
@Observable @MainActor final class DataBrowserViewModel {
    struct Table: Identifiable, Sendable {
        let name: String
        var count: Int?
        var id: String { name }
    }

    private(set) var tables: [Table] = []
    private(set) var visibleTables: [Table] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    var searchText = "" {
        didSet { applySearch() }
    }

    @ObservationIgnored private let context: DataContext

    init(context: DataContext) {
        self.context = context
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        do {
            let names = try await context.client.tables(deploymentURL: context.deploymentURL)
            let counts = Dictionary(tables.map { ($0.name, $0.count) }, uniquingKeysWith: { first, _ in first })
            tables = names.map { Table(name: $0, count: counts[$0] ?? nil) }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = DataErrors.message(for: error)
        }
        hasLoaded = true
        applySearch()
        async let metadata: Void = context.loadMetadata()
        await loadCounts()
        await metadata
    }

    /// Row counts load after the list appears, a few at a time.
    private func loadCounts() async {
        let client = context.client
        let url = context.deploymentURL
        await withTaskGroup(of: (String, Int?).self) { group in
            var pending = tables.map(\.name)[...]
            func addNext() {
                guard let name = pending.popFirst() else { return }
                group.addTask { (name, try? await client.tableSize(deploymentURL: url, table: name)) }
            }
            for _ in 0..<4 { addNext() }
            for await (name, count) in group {
                addNext()
                guard let index = tables.firstIndex(where: { $0.name == name }), let count else { continue }
                tables[index].count = count
            }
        }
        applySearch()
    }

    private func applySearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        visibleTables = query.isEmpty ? tables : tables.filter { $0.name.localizedStandardContains(query) }
    }
}

/// Documents of one table: paging, sort order, a filter clause, and an optional fixed index match
/// (used for "related documents").
///
/// Paging follows the standard feed pattern: one load in flight at a time (the flag is set
/// before the first `await`), pages are de-duplicated by `_id`, and a generation counter drops
/// results from loads superseded by a new filter/sort/refresh.
@Observable @MainActor final class TableDocumentsViewModel {
    private(set) var documents: [ConvexDocument] = []
    private(set) var cards: [String: DocumentCard] = [:]
    private(set) var layout = CardLayout()
    /// Grid: the frozen first column's field, the scrolling columns, and precomputed cell text.
    private(set) var frozenColumn = "_id"
    private(set) var columns: [String] = []
    private(set) var gridRows: [DocumentGridRow] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var canLoadMore = false
    private(set) var errorMessage: String?
    private(set) var filterErrors: [String] = []
    private(set) var count: Int?
    /// Field names from the schema and loaded documents, for the filter and layout editors.
    private(set) var knownFields: [String] = ["_id", "_creationTime"]

    var filter: DocumentFilter? {
        didSet { if filter != oldValue { restart() } }
    }
    var order: DocumentOrder = .desc {
        didSet { if order != oldValue { restart() } }
    }

    /// Keeps memory and bandwidth bounded on huge tables; filter to find older documents.
    static let maximumLoaded = 500
    private static let pageSize = 25

    @ObservationIgnored let table: String
    @ObservationIgnored let indexMatch: IndexMatch?
    @ObservationIgnored let context: DataContext
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(table: String, indexMatch: IndexMatch? = nil, context: DataContext) {
        self.table = table
        self.indexMatch = indexMatch
        self.context = context
    }

    var isCustomized: Bool { context.isCustomized(table) }
    var reachedLimit: Bool { documents.count >= Self.maximumLoaded }

    /// First appearance only; `.task` runs again when navigating back, which must not reset the list.
    func loadIfNeeded() async {
        guard !hasLoaded, loadTask == nil else { return }
        restart()
        await loadTask?.value
    }

    /// Pull to refresh: start over from the first page.
    func refresh() async {
        restart()
        await loadTask?.value
    }

    /// Next page, triggered by the bottom row appearing. Ignored while another load is running.
    func loadMore() {
        guard hasLoaded, canLoadMore, !isLoading, !reachedLimit else { return }
        startLoad(replacing: false)
    }

    func saveLayout(_ layout: CardLayout?) {
        context.saveLayout(layout, for: table)
        refreshLayout()
    }

    private func restart() {
        loadTask?.cancel()
        generation += 1
        cursor = nil
        canLoadMore = false
        startLoad(replacing: true)
        if indexMatch == nil, filter == nil, count == nil {
            Task { [context, table] in
                let size = try? await context.client.tableSize(deploymentURL: context.deploymentURL, table: table)
                self.count = size
            }
        }
    }

    private func startLoad(replacing: Bool) {
        isLoading = true
        let generation = generation
        loadTask = Task {
            await fetch(replacing: replacing, generation: generation)
            if generation == self.generation {
                isLoading = false
                loadTask = nil
            }
        }
    }

    /// Unindexed filters can return empty pages before reaching matches, so keep reading
    /// (up to a few pages) until something turns up.
    private func fetch(replacing: Bool, generation: Int) async {
        var found: [ConvexDocument] = []
        var nextCursor = replacing ? nil : cursor
        var isDone = false
        var errors: [String] = []
        do {
            for _ in 0..<5 {
                let page = try await context.client.documents(deploymentURL: context.deploymentURL, table: table, filter: filter,
                                                              indexMatch: indexMatch, order: order, cursor: nextCursor,
                                                              pageSize: Self.pageSize)
                found += page.documents
                nextCursor = page.continueCursor
                isDone = page.isDone
                errors = page.filterErrors
                if !found.isEmpty || page.isDone || !page.filterErrors.isEmpty { break }
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            let known = replacing ? [] : Set(documents.map(\.id))
            var seen = known
            let fresh = found.filter { seen.insert($0.id).inserted }
            documents = replacing ? fresh : documents + fresh
            cursor = nextCursor
            canLoadMore = !isDone && nextCursor != nil
            filterErrors = errors
            errorMessage = nil
            hasLoaded = true
            await context.loadMetadata()
            guard generation == self.generation else { return }
            refreshLayout()
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            if (error as? URLError)?.code == .cancelled { return }
            if case APIError.transport(let underlying) = error, (underlying as? URLError)?.code == .cancelled { return }
            errorMessage = DataErrors.message(for: error)
            hasLoaded = true
        }
    }

    /// Recomputes the layout, card values, grid columns, and known fields.
    private func refreshLayout() {
        let schema = context.schema?.tables[table]
        layout = context.layout(for: table, sample: Array(documents.prefix(50)))
        cards = Dictionary(documents.map { ($0.id, DocumentCard(document: $0, layout: layout)) },
                           uniquingKeysWith: { first, _ in first })

        var fields = schema?.fields.map(\.name) ?? []
        var seenFields = Set(fields)
        for document in documents {
            for field in document.userFields where seenFields.insert(field.key).inserted {
                fields.append(field.key)
            }
        }
        frozenColumn = layout.title ?? "_id"
        let lead = ([layout.subtitle].compactMap { $0 } + layout.badges).filter { $0 != frozenColumn }
        let rest = fields.filter { !lead.contains($0) && $0 != frozenColumn && $0 != layout.image }.sorted()
        let newColumns = lead + rest + (frozenColumn == "_id" ? ["_creationTime"] : ["_id", "_creationTime"])
        if newColumns != columns { columns = newColumns }
        gridRows = documents.map { document in
            DocumentGridRow(document: document, frozen: DocumentGridRow.text(document.value(for: frozenColumn)),
                            cells: newColumns.map { DocumentGridRow.text(document.value(for: $0)) })
        }
        let known = ["_id", "_creationTime"] + fields.sorted()
        if known != knownFields { knownFields = known }
    }
}

struct DocumentGridRow: Identifiable {
    let document: ConvexDocument
    let frozen: String
    let cells: [String]
    var id: String { document.id }

    static func text(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let date = value.timestampDate { return date.formatted(date: .abbreviated, time: .shortened) }
        return String(value.preview.prefix(80))
    }
}

/// A document looked up by ID.
@Observable @MainActor final class DocumentLookupViewModel {
    enum State {
        case loading
        case found(ConvexDocument)
        case missing
        case failed(String)
    }

    private(set) var state: State = .loading

    @ObservationIgnored let id: String
    @ObservationIgnored private let context: DataContext

    init(id: String, context: DataContext) {
        self.id = id
        self.context = context
    }

    func load() async {
        do {
            async let metadata: Void = context.loadMetadata()
            let document = try await context.client.document(deploymentURL: context.deploymentURL, id: id)
            await metadata
            state = document.map(State.found) ?? .missing
        } catch is CancellationError {
            return
        } catch {
            state = .failed(DataErrors.message(for: error))
        }
    }
}

/// Grouped fields and related documents for the document screen.
@Observable @MainActor final class DocumentDetailViewModel {
    private(set) var related: [RelatedGroup] = []
    private(set) var isSearchingRelated = false
    private(set) var hasSearchedRelated = false

    @ObservationIgnored let document: ConvexDocument
    @ObservationIgnored let table: String?
    @ObservationIgnored let card: DocumentCard
    @ObservationIgnored let groups: [(title: String, fields: [(key: String, value: JSONValue)])]
    @ObservationIgnored let context: DataContext

    init(document: ConvexDocument, table: String?, context: DataContext) {
        self.document = document
        self.context = context
        let table = table ?? context.tableName(forDocumentId: document.id)
        self.table = table
        let layout = table.map { context.layout(for: $0, sample: [document]) } ?? CardLayout.inferred(schema: nil, sample: [document])
        card = DocumentCard(document: document, layout: layout)

        let schema = table.flatMap { context.schema?.tables[$0] }
        var details: [(key: String, value: JSONValue)] = []
        var references: [(key: String, value: JSONValue)] = []
        var dates: [(key: String, value: JSONValue)] = []
        var nested: [(key: String, value: JSONValue)] = []
        for field in document.userFields {
            let isReference = if case .id? = schema?.field(field.key)?.kind { true } else { field.key.hasSuffix("Id") || field.value.documentId != nil }
            if field.value.isContainer {
                nested.append(field)
            } else if isReference {
                references.append(field)
            } else if field.value.timestampDate != nil {
                dates.append(field)
            } else {
                details.append(field)
            }
        }
        groups = [("Fields", details), ("References", references), ("Dates", dates), ("Objects & Arrays", nested)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, fields: $0.1) }
    }

    var hasSchema: Bool { context.schema != nil }

    /// Number of index lookups a related search makes, shown before the user starts it.
    var relatedLookupCount: Int {
        guard let schema = context.schema else { return 0 }
        let keys = 1 + ["tokenIdentifier", "externalId", "clerkId", "clerkUserId", "authId", "subject"]
            .filter { if case .string? = document.value(for: $0) { true } else { false } }.count
        return schema.referenceFields.reduce(0) { total, reference in
            total + (reference.targetTable == nil ? keys : (reference.targetTable == table ? 1 : 0))
        }
    }

    func loadRelated() async {
        guard !hasSearchedRelated, !isSearchingRelated else { return }
        isSearchingRelated = true
        related = await context.relatedGroups(for: document, in: table)
        isSearchingRelated = false
        hasSearchedRelated = true
    }
}

enum DataErrors {
    static func message(for error: Error) -> String {
        switch error {
        case APIError.unauthorized, APIError.forbidden:
            "This token can't read this deployment's data. Its role may not allow viewing data."
        default:
            error.localizedDescription
        }
    }
}
