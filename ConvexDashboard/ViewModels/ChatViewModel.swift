import Foundation
import Observation

/// When AI queries need the developer's OK before running (Settings → Run AI queries).
enum AIRunMode: String, CaseIterable, Identifiable {
    case automatic, askOnProduction, alwaysAsk
    static let storageKey = "aiRunMode"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatically"
        case .askOnProduction: "Ask on production"
        case .alwaysAsk: "Always ask"
        }
    }

    func requiresApproval(isProduction: Bool) -> Bool {
        switch self {
        case .automatic: false
        case .askOnProduction: isProduction
        case .alwaysAsk: true
        }
    }
}

/// Chat about one deployment's data. Each question is a loop: ask the backend for the next step,
/// run any queries it requests here (with this device's token, in the read-only sandbox, under a
/// read budget), send the results back, until it answers.
@Observable @MainActor final class ChatViewModel {
    struct Step: Identifiable {
        let query: ChatQuery
        var result: QueryRunResult?
        /// When the result was produced (results of past chats come from the on-device cache).
        var ranAt: Date?
        var id: String { query.id }
    }

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var steps: [Step] = []
        var answer: ChatAnswer?
        var error: String?
        var isWorking = false
        /// Queries waiting for the developer's OK (Run AI queries ≠ Automatically).
        var pendingQueries: [ChatQuery]?

        var shownStep: Step? {
            if let id = answer?.resultOf, let step = steps.first(where: { $0.id == id }) { return step }
            return steps.last(where: { $0.result?.succeeded == true }) ?? steps.last
        }

        var shownResult: QueryRunResult? {
            guard let result = shownStep?.result, result.succeeded else { return nil }
            return result
        }

        var shownQuery: ChatQuery? { shownStep?.query }

        var documentsRead: Int {
            steps.compactMap { $0.result?.documentsRead }.reduce(0, +)
        }
    }

    private(set) var turns: [Turn] = []
    private(set) var threadId: String?
    private(set) var threads: [ChatThreadSummary] = []
    var draft = ""

    @ObservationIgnored let deploymentName: String
    @ObservationIgnored let context: DataContext
    @ObservationIgnored let isProduction: Bool
    @ObservationIgnored private var schemaText: String?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?

    /// Safety cap on model steps per question (the backend also caps queries per question).
    private static let maxSteps = 8

    init(deploymentName: String, isProduction: Bool, context: DataContext) {
        self.deploymentName = deploymentName
        self.isProduction = isProduction
        self.context = context
    }

    /// Max documents one AI query may read, enforced in code (Convex's own cap is 32,000).
    var readBudget: Int { isProduction ? 10_000 : 25_000 }

    var isWorking: Bool { turns.last?.isWorking ?? false }

    func send(_ text: String? = nil, pulse: PulseClient, shareResults: Bool, runMode: AIRunMode) async {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isWorking else { return }
        draft = ""
        ChatRecents.record(deploymentName)
        turns.append(Turn(question: question, isWorking: true))
        let index = turns.count - 1
        let needsApproval = runMode.requiresApproval(isProduction: isProduction)

        do {
            let schema = await promptSchema()
            var response = try await pulse.chatSend(deploymentName: deploymentName, schema: schema, threadId: threadId,
                                                    question: question, toolResults: [])
            threadId = response.threadId
            var stepCount = 1
            while response.status == "run", stepCount < Self.maxSteps {
                var approved = true
                if needsApproval {
                    turns[index].pendingQueries = response.queries
                    approved = await withCheckedContinuation { approval = $0 }
                    turns[index].pendingQueries = nil
                }
                var results: [ChatToolResult] = []
                for query in response.queries {
                    guard approved else {
                        results.append(ChatToolResult(declined: query.id))
                        continue
                    }
                    turns[index].steps.append(Step(query: query))
                    let result = await context.client.runOneOffQuery(deploymentURL: context.deploymentURL, source: query.code,
                                                                     readBudget: readBudget)
                    if let stepIndex = turns[index].steps.firstIndex(where: { $0.id == query.id }) {
                        turns[index].steps[stepIndex].result = result
                        turns[index].steps[stepIndex].ranAt = .now
                    }
                    if let threadId { ChatResultCache.save(result, queryId: query.id, threadId: threadId) }
                    results.append(ChatToolResult(id: query.id, result: result, shareResults: shareResults))
                }
                response = try await pulse.chatSend(deploymentName: deploymentName, schema: schema, threadId: threadId,
                                                    question: nil, toolResults: results)
                stepCount += 1
            }
            turns[index].answer = response.answer
                ?? ChatAnswer(text: "I couldn't finish that in a few steps. Try asking more specifically.", resultOf: nil, display: nil, followups: [])
        } catch {
            turns[index].error = error.localizedDescription
        }
        turns[index].isWorking = false
    }

    /// The developer's answer to a pending query request.
    func resolveApproval(run: Bool) {
        approval?.resume(returning: run)
        approval = nil
    }

    func newThread() {
        resolveApproval(run: false)
        threadId = nil
        turns = []
        draft = ""
    }

    func loadThreads(pulse: PulseClient) async {
        threads = (try? await pulse.chatThreads(deploymentName: deploymentName)) ?? []
    }

    /// Opens a past chat with the results saved on this device. Nothing runs until Refresh.
    func open(_ thread: ChatThreadSummary, pulse: PulseClient) async {
        guard let records = try? await pulse.chatTurns(threadId: thread.id) else { return }
        resolveApproval(run: false)
        threadId = thread.id
        let cached = ChatResultCache.load(threadId: thread.id)
        turns = records.map { record in
            Turn(question: record.question,
                 steps: record.queries.map { query in
                     Step(query: query, result: cached[query.id]?.result, ranAt: cached[query.id]?.ranAt)
                 },
                 answer: record.answer)
        }
    }

    func delete(_ thread: ChatThreadSummary, pulse: PulseClient) async {
        try? await pulse.deleteChatThread(threadId: thread.id)
        ChatResultCache.delete(threadId: thread.id)
        threads.removeAll { $0.id == thread.id }
        if thread.id == threadId { newThread() }
    }

    /// Runs the query behind an answer again (the developer tapped Refresh).
    func rerun(turnID: UUID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let query = turns[index].shownQuery,
              let stepIndex = turns[index].steps.firstIndex(where: { $0.id == query.id }) else { return }
        let result = await context.client.runOneOffQuery(deploymentURL: context.deploymentURL, source: query.code,
                                                         readBudget: readBudget)
        turns[index].steps[stepIndex].result = result
        turns[index].steps[stepIndex].ranAt = .now
        if let threadId { ChatResultCache.save(result, queryId: query.id, threadId: threadId) }
    }

    private func promptSchema() async -> String {
        if let schemaText { return schemaText }
        let tables = (try? await context.client.tables(deploymentURL: context.deploymentURL)) ?? []
        var text = await context.promptSchema(tables: tables)
        text += "\n\nRead budget: each run_query may read at most \(readBudget.formatted()) documents in total (enforced by the app; going over fails the query). Use indexes, time ranges, and .take() limits well under that."
        schemaText = text
        return text
    }
}

/// Query results of chats, saved on this device (Caches) so opening a past chat doesn't run its
/// queries again. Results stay local: the backend only stores messages.
enum ChatResultCache {
    struct Entry: Codable {
        let value: JSONValue?
        let errorMessage: String?
        let documentsRead: Int?
        let ranAt: Date

        var result: QueryRunResult {
            var result = QueryRunResult(value: value, errorMessage: errorMessage, errorData: nil, logLines: [], duration: 0)
            result.documentsRead = documentsRead
            return result
        }
    }

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "ChatResults", directoryHint: .isDirectory)
    }

    private static func file(_ threadId: String) -> URL {
        directory.appending(path: "\(threadId).json")
    }

    static func load(threadId: String) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file(threadId)) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func save(_ result: QueryRunResult, queryId: String, threadId: String) {
        var entries = load(threadId: threadId)
        // Very large results aren't worth keeping; Refresh runs them again.
        var value = result.value
        if case .array(let items)? = value, items.count > 500 { value = .array(Array(items.prefix(500))) }
        entries[queryId] = Entry(value: value, errorMessage: result.errorMessage, documentsRead: result.documentsRead, ranAt: .now)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file(threadId), options: .atomic)
    }

    static func delete(threadId: String) {
        try? FileManager.default.removeItem(at: file(threadId))
    }
}

/// The deployment's data catalog: load, and build by profiling the data on this device.
@Observable @MainActor final class CatalogViewModel {
    enum State {
        case loading
        case missing
        case built(CatalogInfo)
        case building(String)
        case failed(String)
    }

    private(set) var state: State = .loading
    /// Set when the deployment was deployed after the catalog was built.
    private(set) var isStale = false

    @ObservationIgnored let deploymentName: String
    @ObservationIgnored private let lastDeploy: Date?
    @ObservationIgnored private let context: DataContext

    init(deploymentName: String, lastDeploy: Date?, context: DataContext) {
        self.deploymentName = deploymentName
        self.lastDeploy = lastDeploy
        self.context = context
    }

    var info: CatalogInfo? {
        if case .built(let info) = state { return info }
        return nil
    }

    var isBuilding: Bool {
        if case .building = state { return true }
        return false
    }

    func load(pulse: PulseClient) async {
        do {
            if let info = try await pulse.catalog(deploymentName: deploymentName) {
                state = .built(info)
                isStale = lastDeploy.map { $0 > info.date } ?? false
            } else {
                state = .missing
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func build(pulse: PulseClient, shareValues: Bool) async {
        guard !isBuilding else { return }
        let client = context.client
        let url = context.deploymentURL
        do {
            state = .building("Reading tables…")
            await context.loadMetadata()
            let tables = try await client.tables(deploymentURL: url)
            // The schema's tables, plus any table without one.
            let allTables = Array(Set(tables).union(context.schema.map { Array($0.tables.keys) } ?? [])).sorted()

            var profiles: [String: JSONValue] = [:]
            for start in stride(from: 0, to: allTables.count, by: 8) {
                let batch = Array(allTables[start..<min(start + 8, allTables.count)])
                state = .building("Profiling tables \(min(start + 8, allTables.count))/\(allTables.count)…")
                let result = await client.runOneOffQuery(
                    deploymentURL: url, source: CatalogProfiler.source(tables: batch, allTables: allTables, shareValues: shareValues))
                if case .object(let object)? = result.value {
                    profiles.merge(object) { first, _ in first }
                }
            }

            state = .building("Counting rows…")
            var counts: [String: Int] = [:]
            await withTaskGroup(of: (String, Int?).self) { group in
                var pending = allTables[...]
                func addNext() {
                    guard let table = pending.popFirst() else { return }
                    group.addTask { (table, try? await client.tableSize(deploymentURL: url, table: table)) }
                }
                for _ in 0..<4 { addNext() }
                for await (table, count) in group {
                    counts[table] = count
                    addNext()
                }
            }
            let functions = (try? await client.functionNames(deploymentURL: url)) ?? [:]
            let hints = await context.referenceHints()

            let tableProfiles: [JSONValue] = allTables.compactMap { name in
                guard let profile = profiles[name] else { return nil }
                var object: [String: JSONValue] = [
                    "name": .string(name),
                    "sampled": profile["sampled"] ?? .number(0),
                    "fields": profile["fields"] ?? .array([]),
                ]
                if let count = counts[name] { object["rows"] = .number(Double(count)) }
                return .object(object)
            }
            let profile = JSONValue.object([
                "tables": .array(tableProfiles),
                "functions": .object(functions.mapValues { .array($0.map(JSONValue.string)) }),
                "hints": .string(hints),
            ])

            state = .building("Writing descriptions with AI… (about a minute)")
            let info = try await pulse.buildCatalog(deploymentName: deploymentName, profile: JSONValue.compactJSON(profile))
            state = .built(info)
            isStale = false
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
