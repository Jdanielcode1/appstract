import Foundation
import Observation

/// Saved queries, on this device only (they hold no secrets: a deployment URL and query text).
@Observable @MainActor final class SavedQueriesStore {
    static let shared = SavedQueriesStore()
    private static let key = "savedQueries"

    private(set) var items: [SavedQuery] = []

    private init() {
        // Lossy: skips entries this version can't read (e.g. saved deployed-function queries).
        struct Lossy: Decodable {
            let query: SavedQuery?
            init(from decoder: Decoder) throws { query = try? SavedQuery(from: decoder) }
        }
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Lossy].self, from: data) {
            items = saved.compactMap(\.query)
        }
    }

    func items(for deploymentName: String) -> [SavedQuery] {
        items.filter { $0.deploymentName == deploymentName }
    }

    func save(_ query: SavedQuery) {
        if let index = items.firstIndex(where: { $0.id == query.id }) {
            items[index] = query
        } else {
            items.append(query)
        }
        persist()
    }

    func delete(_ query: SavedQuery) {
        items.removeAll { $0.id == query.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// A one-off JavaScript query, written by hand, from a template, or by AI from a question.
@Observable @MainActor final class OneOffQueryViewModel {
    var source: String
    var question = ""
    private(set) var result: QueryRunResult?
    private(set) var isRunning = false
    private(set) var tables: [String] = []
    private(set) var isGenerating = false
    private(set) var aiExplanation: String?
    /// The question and the model's display suggestion for the query in the editor; cleared when
    /// the editor gets a query from elsewhere (template, saved query, new).
    private(set) var answerQuestion: String?
    private(set) var answerDisplay: AnswerDisplay?
    private(set) var aiError: String?
    @ObservationIgnored private var lastQuestion = ""

    @ObservationIgnored let deploymentURL: URL
    @ObservationIgnored let client: ConvexAPIClient
    @ObservationIgnored var deploymentName: String?

    init(deploymentURL: URL, client: ConvexAPIClient, source: String = "") {
        self.deploymentURL = deploymentURL
        self.client = client
        self.source = source
    }

    func loadTables() async {
        guard tables.isEmpty else { return }
        tables = (try? await client.tables(deploymentURL: deploymentURL)) ?? []
    }

    func applyTemplate(_ template: String, table: String) {
        load(source: template.replacingOccurrences(of: "TABLE", with: table))
    }

    /// Puts a query in the editor that didn't come from Ask (template, saved query, blank).
    func load(source: String, question: String? = nil, display: AnswerDisplay? = nil) {
        self.source = source
        answerQuestion = question
        answerDisplay = display
        aiExplanation = nil
        aiError = nil
        result = nil
    }

    /// Asks the monitoring backend's AI action for a query, puts it in the editor, and runs it
    /// (safe: the sandbox is read-only). If it errors, the error goes back to the model once.
    func generate(pulse: PulseClient, context: DataContext) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastQuestion = trimmed
        guard await requestQuery(pulse: pulse, context: context, question: trimmed, previousQuery: nil, error: nil) else { return }
        await run()
        if let error = result?.errorMessage,
           await requestQuery(pulse: pulse, context: context, question: trimmed, previousQuery: source, error: error) {
            await run()
        }
    }

    /// Sends the failed query and its error back to the model for a corrected version, then runs it.
    func fix(pulse: PulseClient, context: DataContext) async {
        guard let error = result?.errorMessage else { return }
        if await requestQuery(pulse: pulse, context: context, question: lastQuestion, previousQuery: source, error: error) {
            await run()
        }
    }

    /// Returns whether a new query was put in the editor.
    @discardableResult
    private func requestQuery(pulse: PulseClient, context: DataContext, question: String, previousQuery: String?, error: String?) async -> Bool {
        guard !isGenerating else { return false }
        isGenerating = true
        defer { isGenerating = false }
        aiError = nil
        await loadTables()
        let schema = await context.promptSchema(tables: tables)
        do {
            let generated = try await pulse.generateQuery(question: question, schema: schema, deploymentName: deploymentName,
                                                          previousQuery: previousQuery, error: error)
            source = generated.query
            aiExplanation = generated.explanation.isEmpty ? nil : generated.explanation
            answerQuestion = question
            answerDisplay = generated.display ?? answerDisplay
            result = nil
            return true
        } catch {
            aiError = error.localizedDescription
            return false
        }
    }

    func run() async {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty else { return }
        isRunning = true
        result = await client.runOneOffQuery(deploymentURL: deploymentURL, source: trimmed)
        isRunning = false
    }
}

/// Runs a saved query when opened.
@Observable @MainActor final class SavedQueryRunViewModel {
    private(set) var result: QueryRunResult?
    private(set) var isRunning = false
    private(set) var ranAt: Date?

    @ObservationIgnored let query: SavedQuery
    @ObservationIgnored private let client: ConvexAPIClient

    init(query: SavedQuery, client: ConvexAPIClient) {
        self.query = query
        self.client = client
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        result = await client.runOneOffQuery(deploymentURL: query.deploymentURL, source: query.source)
        ranAt = .now
        isRunning = false
    }
}
