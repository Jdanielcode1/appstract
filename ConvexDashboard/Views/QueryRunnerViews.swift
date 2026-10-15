import SwiftUI

/// Run Query: write a read-only query (or start from a template), run it, and save favorites.
struct QueryRunnerView: View {
    @State private var context: DataContext
    @State private var viewModel: OneOffQueryViewModel
    @State private var store = SavedQueriesStore.shared
    @State private var editing: SavedQuery?
    @State private var isNaming = false
    @State private var saveName = ""
    @State private var showsQuery = false
    @State private var showsRaw = false
    @Environment(PulseSettings.self) private var pulseSettings
    private let deploymentName: String

    init(deploymentName: String, deploymentURL: URL, client: ConvexAPIClient) {
        self.init(deploymentName: deploymentName, context: DataContext(deploymentURL: deploymentURL, client: client), editing: nil)
    }

    init(deploymentName: String, context: DataContext, editing: SavedQuery?) {
        self.deploymentName = deploymentName
        _context = State(initialValue: context)
        _editing = State(initialValue: editing)
        let viewModel = OneOffQueryViewModel(deploymentURL: context.deploymentURL, client: context.client, source: editing?.source ?? "")
        viewModel.deploymentName = deploymentName
        _viewModel = State(initialValue: viewModel)
    }

    private var hasSource: Bool {
        !viewModel.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if isAnswer {
                resultSections
                querySection
            } else {
                querySection
                resultSections
            }

            let saved = store.items(for: deploymentName)
            if !saved.isEmpty {
                ConvexSection {
                    ForEach(saved) { query in
                        Button {
                            open(query)
                        } label: {
                            SavedQueryRow(query: query, showsDeployment: false)
                        }
                        .listRowBackground(query.id == editing?.id ? Color.convexAccent.opacity(0.12) : Color.convexSurface)
                    }
                    .onDelete { offsets in
                        offsets.map { saved[$0] }.forEach(delete)
                    }
                } header: {
                    Eyebrow("Saved")
                } footer: {
                    Text("Tap to load and run. Saved queries also appear on the Overview tab.")
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Run Query")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editing != nil {
                    Button("New Query", systemImage: "square.and.pencil", action: startNew)
                }
                Button("Save", systemImage: editing == nil ? "star" : "star.fill", action: startSaving)
                    .disabled(!hasSource)
            }
        }
        .task { await viewModel.loadTables() }
        .alert(editing == nil ? "Save Query" : "Update Saved Query", isPresented: $isNaming) {
            TextField("Name", text: $saveName)
            Button("Save", action: save)
            if editing != nil {
                Button("Save as New", action: saveAsNew)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A query written by Ask: show the answer first and fold the code away.
    private var isAnswer: Bool { viewModel.answerQuestion != nil }

    @ViewBuilder
    private var querySection: some View {
        if isAnswer && !showsQuery {
            ConvexSection {
                Button(action: toggleQuery) {
                    SettingsRow("Show query", systemImage: "chevron.left.forwardslash.chevron.right", tint: .convexAccent) {
                        Text("Written by AI")
                    }
                }
            }
        } else {
            ConvexSection {
                TextEditor(text: $viewModel.source)
                    .font(.convexMono(.footnote))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 150)
                    .overlay(alignment: .topLeading) {
                        if viewModel.source.isEmpty {
                            Text("await ctx.db.query(\"users\").order(\"desc\").take(10)")
                                .font(.convexMono(.footnote))
                                .foregroundStyle(Color.convexSecondaryText.opacity(0.6))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                HStack {
                    Eyebrow(editing.map { "Editing · \($0.name)" } ?? "Query")
                    Spacer()
                    TemplatesMenu(tables: viewModel.tables, onPick: viewModel.applyTemplate)
                }
            } footer: {
                Text("Sandboxed and read-only. A single expression is returned automatically; for several statements, use return.")
            }

            ConvexSection {
                Button(action: run) {
                    HStack {
                        Spacer()
                        if viewModel.isRunning { ProgressView() } else { Label("Run", systemImage: "play.fill") }
                        Spacer()
                    }
                    .font(.body.weight(.semibold))
                }
                .disabled(viewModel.isRunning || !hasSource)
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if let result = viewModel.result {
            if result.succeeded {
                AnswerSections(title: viewModel.answerQuestion, explanation: viewModel.aiExplanation,
                               display: viewModel.answerDisplay, result: result, context: context)
                ConvexSection {
                    Button(action: toggleRaw) {
                        SettingsRow(showsRaw ? "Hide raw result" : "Show raw result", systemImage: "curlybraces", tint: .convexSecondaryText)
                    }
                }
                if showsRaw {
                    QueryResultSections(result: result, context: context)
                }
            } else {
                if pulseSettings.client != nil {
                    ConvexSection {
                        Button(action: fix) {
                            HStack {
                                Spacer()
                                if viewModel.isGenerating { ProgressView() } else { Label("Fix it with AI", systemImage: "wand.and.stars") }
                                Spacer()
                            }
                        }
                        .disabled(viewModel.isGenerating)
                    }
                }
                QueryResultSections(result: result, context: context)
            }
        } else if viewModel.isRunning && isAnswer {
            ConvexSection {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Running…")
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
        }
    }

    private func toggleQuery() {
        showsQuery.toggle()
    }

    private func toggleRaw() {
        showsRaw.toggle()
    }

    private func fix() {
        guard let pulse = pulseSettings.client else { return }
        Task { await viewModel.fix(pulse: pulse, context: context) }
    }

    private func run() {
        Task { await viewModel.run() }
    }

    private func open(_ query: SavedQuery) {
        editing = query
        viewModel.load(source: query.source, question: query.question, display: query.display)
        showsRaw = false
        run()
    }

    private func startNew() {
        editing = nil
        viewModel.load(source: "")
    }

    private func startSaving() {
        saveName = editing?.name ?? viewModel.answerQuestion ?? ""
        isNaming = true
    }

    private func save() {
        var query = editing ?? SavedQuery(name: "", deploymentName: deploymentName, deploymentURL: context.deploymentURL, source: "")
        query.name = saveName.isEmpty ? (viewModel.answerQuestion ?? "Query") : saveName
        query.source = viewModel.source
        query.question = viewModel.answerQuestion
        query.display = viewModel.answerDisplay
        store.save(query)
        editing = query
    }

    private func saveAsNew() {
        editing = nil
        save()
    }

    private func delete(_ query: SavedQuery) {
        if query.id == editing?.id { editing = nil }
        store.delete(query)
    }
}

/// Starter queries: pick a template, then a table.
private struct TemplatesMenu: View {
    let tables: [String]
    let onPick: (String, String) -> Void

    var body: some View {
        Menu {
            ForEach(OneOffQuerySource.templates, id: \.title) { template in
                Menu(template.title) {
                    if tables.isEmpty {
                        Text("Loading tables…")
                    }
                    ForEach(tables, id: \.self) { table in
                        Button(table) { onPick(template.source, table) }
                    }
                }
            }
        } label: {
            Label("Templates", systemImage: "doc.on.doc")
                .font(.caption.weight(.medium))
        }
    }
}

struct SavedQueryRow: View {
    let query: SavedQuery
    let showsDeployment: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "star.fill", tint: .convexYellow, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(query.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Text(showsDeployment ? query.deploymentName : query.subtitle)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - Saved query

/// Runs a saved query as soon as it opens: the one-tap check (from the Overview tab).
struct SavedQueryRunView: View {
    @State private var viewModel: SavedQueryRunViewModel
    @State private var context: DataContext
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(query: SavedQuery, client: ConvexAPIClient) {
        _viewModel = State(initialValue: SavedQueryRunViewModel(query: query, client: client))
        _context = State(initialValue: DataContext(deploymentURL: query.deploymentURL, client: client))
    }

    private var query: SavedQuery { viewModel.query }

    var body: some View {
        List {
            ConvexSection {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(query.deploymentName)
                    Text(query.name)
                        .font(.convexDisplay(.title3, weight: .medium))
                        .foregroundStyle(Color.convexText)
                    if let question = query.question, question != query.name {
                        Label(question, systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(Color.convexSecondaryText)
                    }
                    if query.question == nil {
                        Text(query.source)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexSecondaryText)
                            .lineLimit(6)
                    }
                }
                .padding(.vertical, 4)
                if query.question != nil {
                    DisclosureGroup("Query") {
                        Text(query.source)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexText)
                            .textSelection(.enabled)
                    }
                }
            }

            if viewModel.isRunning, viewModel.result == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let result = viewModel.result {
                if result.succeeded {
                    AnswerSections(title: nil, explanation: nil, display: query.display, result: result, context: context)
                    ConvexSection {
                        DisclosureGroup("Raw result") {
                            Text(result.value?.prettyJSON ?? "")
                                .font(.convexMono(.caption))
                                .foregroundStyle(Color.convexText)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    QueryResultSections(result: result, context: context)
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle(query.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.run() }
        .task { if viewModel.result == nil { await viewModel.run() } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Run again", systemImage: "arrow.clockwise", action: rerun)
                    .disabled(viewModel.isRunning)
                Menu("More", systemImage: "ellipsis.circle") {
                    NavigationLink {
                        QueryRunnerView(deploymentName: query.deploymentName, context: context, editing: query)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button("Delete", systemImage: "trash", role: .destructive, action: confirmDelete)
                }
            }
        }
        .confirmationDialog("Delete \"\(query.name)\"?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func rerun() {
        Task { await viewModel.run() }
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func delete() {
        SavedQueriesStore.shared.delete(query)
        dismiss()
    }
}

// MARK: - Result

/// Status, value (drill into objects/arrays; document IDs open the document), and console output.
struct QueryResultSections: View {
    let result: QueryRunResult
    let context: DataContext

    var body: some View {
        ConvexSection {
            HStack(spacing: 10) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? Color.convexGreen : Color.convexRed)
                Text(result.succeeded ? result.shapeDescription : "Failed")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.convexText)
                Spacer()
                Text("\(Int((result.duration * 1000).rounded())) ms")
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                if let value = result.value {
                    ShareLink(item: value.prettyJSON) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let error = result.errorMessage {
                Text(error)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexRed)
                    .textSelection(.enabled)
                if let data = result.errorData, data != .null {
                    Text(data.prettyJSON)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexText)
                        .textSelection(.enabled)
                }
            } else if let value = result.value {
                if value.isContainer {
                    ForEach(Array(value.children.prefix(200)), id: \.key) { child in
                        if case .object = child.value, child.value.isContainer {
                            NavigationLink {
                                ResultObjectView(title: child.key, value: child.value, context: context)
                            } label: {
                                ResultObjectRow(key: child.key, value: child.value)
                            }
                        } else {
                            FieldRow(key: child.key, value: child.value, context: context)
                        }
                    }
                    if value.children.count > 200 {
                        Text("Showing 200 of \(value.children.count). Share to see everything.")
                            .font(.footnote)
                            .foregroundStyle(Color.convexSecondaryText)
                    }
                } else {
                    Text(value.preview)
                        .font(.convexDisplay(.title2, weight: .medium))
                        .foregroundStyle(Color.convexText)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Eyebrow("Result")
        }

        if !result.logLines.isEmpty {
            ConvexSection("Logs") {
                ForEach(Array(result.logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexText)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// An object in a result, labeled like a table card (name/title, then email/status…).
private struct ResultObjectRow: View {
    let key: String
    private let title: String
    private let subtitle: String

    init(key: String, value: JSONValue) {
        self.key = key
        let fields = value.children
        let document = ConvexDocument(value)
        let layout = CardLayout.inferred(schema: nil, sample: document.map { [$0] } ?? [])
        let text: (String?) -> String? = { name in
            guard let name, let field = fields.first(where: { $0.key == name }), field.value != .null else { return nil }
            let preview = field.value.preview
            return preview.isEmpty ? nil : preview
        }
        title = text(layout.title) ?? document?.id ?? value.preview
        subtitle = text(layout.subtitle) ?? fields.prefix(3).map { "\($0.key): \($0.value.preview.prefix(30))" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.convexMono(.caption2))
                .foregroundStyle(Color.convexSecondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// An object from a result: a document (with Related etc.) when it has an `_id`, else its fields.
private struct ResultObjectView: View {
    let title: String
    let value: JSONValue
    let context: DataContext

    var body: some View {
        if let document = ConvexDocument(value) {
            DocumentDetailView(document: document, table: nil, context: context)
                .task { await context.loadMetadata() }
        } else {
            JSONValueView(title: title, value: value, context: context)
        }
    }
}
