import SwiftUI

/// Ask AI: chat about a deployment's data. The model plans and checks; this device runs each
/// query read-only with its own token (deployment screen → Ask AI).
struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var catalog: CatalogViewModel
    @State private var context: DataContext
    @State private var isShowingCatalog = false
    @State private var isShowingHistory = false
    @Environment(PulseSettings.self) private var pulseSettings
    @AppStorage("aiSeesResults") private var aiSeesResults = true
    @AppStorage(AIRunMode.storageKey) private var runMode: AIRunMode = .automatic
    @FocusState private var isInputFocused: Bool
    private let deploymentName: String
    private let deploymentType: String
    private let projectName: String?
    private let onPickDeployment: (() -> Void)?

    /// `onPickDeployment` adds the top-left switcher (the Ask AI tab); without it the chat is
    /// fixed to this deployment (deployment screen → Ask AI).
    init(deployment: Deployment, deploymentURL: URL, client: ConvexAPIClient,
         projectName: String? = nil, onPickDeployment: (() -> Void)? = nil) {
        deploymentName = deployment.name
        deploymentType = deployment.deploymentType
        self.projectName = projectName
        self.onPickDeployment = onPickDeployment
        let context = DataContext(deploymentURL: deploymentURL, client: client)
        _context = State(initialValue: context)
        _viewModel = State(initialValue: ChatViewModel(deploymentName: deployment.name, isProduction: deployment.deploymentType == "prod",
                                                       context: context))
        _catalog = State(initialValue: CatalogViewModel(deploymentName: deployment.name,
                                                        lastDeploy: deployment.lastDeployTime?.dateFromMillis, context: context))
    }

    var body: some View {
        messageList
        .background(Color.convexBackground)
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle("Ask AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitle(subtitle: projectName.map { "\($0) · \(deploymentType)" } ?? deploymentName)
            }
            if let onPickDeployment {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Choose deployment", systemImage: "folder", action: onPickDeployment)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("History", systemImage: "clock.arrow.circlepath", action: showHistory)
                Button("New Chat", systemImage: "square.and.pencil", action: viewModel.newThread)
                    .disabled(viewModel.turns.isEmpty || viewModel.isWorking)
            }
        }
        .task {
            guard let pulse = pulseSettings.client else { return }
            await catalog.load(pulse: pulse)
        }
        .sheet(isPresented: $isShowingCatalog) {
            CatalogView(catalog: catalog, shareValues: aiSeesResults)
        }
        .sheet(isPresented: $isShowingHistory) {
            ChatHistoryView(viewModel: viewModel)
        }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if viewModel.turns.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.turns) { turn in
                        turnView(turn)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.turns.last?.steps.count) { scrollToEnd(proxy) }
            .onChange(of: viewModel.turns.count) { scrollToEnd(proxy) }
            .onChange(of: viewModel.isWorking) { scrollToEnd(proxy) }
            .onChange(of: viewModel.turns.last?.pendingQueries?.count) { scrollToEnd(proxy) }
        }
    }

    private func turnView(_ turn: ChatViewModel.Turn) -> some View {
        TurnView(turn: turn, context: context, deploymentName: viewModel.deploymentName,
                 readBudget: viewModel.readBudget, onFollowup: send, onRerun: { rerun(turn.id) },
                 onApprove: approve)
            .id(turn.id)
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 22) {
            ChatHero()
            if pulseSettings.client == nil {
                Label("Connect your monitoring backend in Settings to ask questions about your data.", systemImage: "waveform.path.ecg")
                    .font(.callout)
                    .foregroundStyle(Color.convexSecondaryText)
                    .multilineTextAlignment(.center)
            } else {
                TopicGrid(onSelect: startTopic)
                CatalogCard(catalog: catalog, onOpen: showCatalog, onBuild: buildCatalog)
            }
        }
        .padding(.top, 28)
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.convexAccent)
                    .padding(.bottom, 9)
                    .accessibilityHidden(true)
                TextField("Ask about your data…", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .submitLabel(.send)
                    .onSubmit { send(nil) }
                    .padding(.vertical, 8)
                Button {
                    send(nil)
                } label: {
                    Image(systemName: viewModel.isWorking ? "ellipsis" : "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.convexAccentFill : Color.convexSecondaryText.opacity(0.35), in: .circle)
                        .symbolEffect(.variableColor.iterative, isActive: viewModel.isWorking)
                }
                .disabled(!canSend)
                .padding(.bottom, 3)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
            .background(Color.convexSurface, in: .rect(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color.convexHairline) }

            Label(aiSeesResults ? "Read-only · AI sees up to 20 rows per result" : "Read-only · AI never sees your data",
                  systemImage: "lock")
                .font(.caption2)
                .foregroundStyle(Color.convexSecondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color.convexBackground)
    }

    private var canSend: Bool {
        pulseSettings.client != nil && !viewModel.isWorking
            && !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func send(_ text: String?) {
        guard let pulse = pulseSettings.client else { return }
        isInputFocused = false
        Task { await viewModel.send(text, pulse: pulse, shareResults: aiSeesResults, runMode: runMode) }
    }

    /// Questions with a blank to fill go to the input; the rest are asked right away.
    private func startTopic(_ topic: ChatTopic) {
        if topic.needsInput {
            viewModel.draft = topic.prompt
            isInputFocused = true
        } else {
            send(topic.prompt)
        }
    }

    private func approve(_ run: Bool) {
        viewModel.resolveApproval(run: run)
    }

    private func rerun(_ id: UUID) {
        Task { await viewModel.rerun(turnID: id) }
    }

    private func showCatalog() {
        isShowingCatalog = true
    }

    private func showHistory() {
        isShowingHistory = true
    }

    private func buildCatalog() {
        guard let pulse = pulseSettings.client else { return }
        Task { await catalog.build(pulse: pulse, shareValues: aiSeesResults) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = viewModel.turns.last?.id else { return }
        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
    }
}

// MARK: - Empty state

private struct ChatTitle: View {
    let subtitle: String

    var body: some View {
        VStack(spacing: 1) {
            Text("Ask AI")
                .font(.convexDisplay(.headline, weight: .medium))
                .foregroundStyle(Color.convexText)
            Text(subtitle)
                .font(.convexMono(.caption2))
                .foregroundStyle(Color.convexSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChatHero: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Color.convexAccentFill.gradient, in: .rect(cornerRadius: 20))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.convexYellow)
                        .offset(x: 6, y: -6)
                }
                .accessibilityHidden(true)
            Text("How can I help you understand your data?")
                .font(.convexDisplay(.title2, weight: .semibold))
                .foregroundStyle(Color.convexText)
                .multilineTextAlignment(.center)
            Text("Ask about users, activity, growth, or what's in a table. Queries run read-only on this phone; nothing is ever changed.")
                .font(.subheadline)
                .foregroundStyle(Color.convexSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A starter question. `needsInput` ones go to the input field for the user to finish.
struct ChatTopic: Identifiable {
    let title: String
    let systemImage: String
    let prompt: String
    var needsInput = false
    var id: String { title }

    static let all = [
        ChatTopic(title: "Explore", systemImage: "square.grid.2x2", prompt: "What are my biggest tables and what's in them?"),
        ChatTopic(title: "Users", systemImage: "person.2", prompt: "How many users signed up in the last 7 days?"),
        ChatTopic(title: "Activity", systemImage: "chart.bar.xaxis", prompt: "Who are the 10 most active users?"),
        ChatTopic(title: "Growth", systemImage: "chart.line.uptrend.xyaxis", prompt: "How many new documents per day in the last 14 days?"),
        ChatTopic(title: "Find", systemImage: "magnifyingglass", prompt: "Find the user with email ", needsInput: true),
        ChatTopic(title: "Data health", systemImage: "stethoscope", prompt: "Which fields are often missing or empty?"),
    ]
}

private struct TopicGrid: View {
    let onSelect: (ChatTopic) -> Void
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ChatTopic.all) { topic in
                Button {
                    onSelect(topic)
                } label: {
                    Label(topic.title, systemImage: topic.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.convexText)
                        .labelStyle(TopicLabelStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 15)
                        .background(Color.convexSurface, in: .rect(cornerRadius: 14))
                        .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityHint(topic.prompt)
            }
        }
    }
}

private struct TopicLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .foregroundStyle(Color.convexAccent)
                .frame(width: 22)
            configuration.title
        }
    }
}

// MARK: - Turn

private struct TurnView: View {
    let turn: ChatViewModel.Turn
    let context: DataContext
    let deploymentName: String
    let readBudget: Int
    let onFollowup: (String) -> Void
    let onRerun: () -> Void
    let onApprove: (Bool) -> Void
    @State private var showsQueries = false
    @State private var didSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.convexAccentFill, in: .rect(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)

            if !turn.steps.isEmpty {
                stepsSummary
            }

            if let pending = turn.pendingQueries {
                ApprovalCard(queries: pending, readBudget: readBudget, onApprove: onApprove)
            }

            if turn.isWorking && turn.pendingQueries == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(turn.steps.last.map { $0.result == nil ? "Running: \($0.query.purpose)" : "Checking the result…" } ?? "Thinking…")
                        .font(.footnote)
                        .foregroundStyle(Color.convexSecondaryText)
                        .lineLimit(2)
                }
            }

            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.convexRed)
            }

            if let answer = turn.answer {
                answerCard(answer)
            }
        }
    }

    private var stepsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { showsQueries.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: failedCount > 0 && turn.answer == nil ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(Color.convexGreen)
                    Text(stepsLabel)
                    Image(systemName: showsQueries ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexSecondaryText)
            }
            .buttonStyle(.plain)

            if showsQueries {
                ForEach(turn.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: step.result == nil ? "circle.dotted" : (step.result!.succeeded ? "checkmark" : "xmark"))
                                .foregroundStyle(step.result?.succeeded == false ? Color.convexRed : Color.convexGreen)
                            Text(step.query.purpose.isEmpty ? "Query" : step.query.purpose)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.convexText)
                        }
                        Text(step.query.code)
                            .font(.convexMono(.caption2))
                            .foregroundStyle(Color.convexText)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.convexSurface, in: .rect(cornerRadius: 8))
                        if let error = step.result?.errorMessage {
                            Text(error)
                                .font(.convexMono(.caption2))
                                .foregroundStyle(Color.convexRed)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
    }

    private var failedCount: Int { turn.steps.filter { $0.result?.succeeded == false }.count }

    private var stepsLabel: String {
        let count = turn.steps.count
        let fixed = failedCount > 0 ? " · \(failedCount) failed" : ""
        let read = turn.documentsRead > 0 ? " · read \(turn.documentsRead.formatted()) docs" : ""
        return "Ran \(count) quer\(count == 1 ? "y" : "ies")\(read)\(fixed)"
    }

    private func answerCard(_ answer: ChatAnswer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.text)
                .font(.body)
                .foregroundStyle(Color.convexText)
                .textSelection(.enabled)

            if let result = turn.shownResult {
                ChatResultView(presentation: AnswerPresentation(value: result.value, display: answer.display),
                               title: answer.display?.title, context: context)
                if let ranAt = turn.shownStep?.ranAt, ranAt < .now.addingTimeInterval(-60) {
                    HStack(spacing: 8) {
                        Text("Result from \(ranAt, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(Color.convexSecondaryText)
                        Button("Refresh", systemImage: "arrow.clockwise", action: onRerun)
                            .font(.caption.weight(.semibold))
                    }
                }
            } else if turn.shownQuery != nil, !turn.isWorking {
                Button("Run query again", systemImage: "play.fill", action: onRerun)
                    .font(.footnote.weight(.medium))
            }

            HStack(spacing: 14) {
                if let query = turn.shownQuery {
                    Button(didSave ? "Saved" : "Save", systemImage: didSave ? "star.fill" : "star") { save(query, answer: answer) }
                    ShareLink(item: turn.shownResult?.value?.prettyJSON ?? answer.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .font(.footnote.weight(.medium))
            .labelStyle(.titleAndIcon)

            if !answer.followups.isEmpty {
                FollowupChips(followups: answer.followups, onTap: onFollowup)
            }
        }
        .padding(14)
        .background(Color.convexSurface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.convexHairline) }
    }

    /// Saves the query behind the answer for one-tap runs (Run Query and Overview).
    private func save(_ query: ChatQuery, answer: ChatAnswer) {
        guard !didSave else { return }
        SavedQueriesStore.shared.save(SavedQuery(name: answer.display?.title ?? turn.question, deploymentName: deploymentName,
                                                 deploymentURL: context.deploymentURL, source: query.code,
                                                 question: turn.question, display: answer.display))
        didSave = true
    }
}

/// Shown when Run AI queries asks first: what the AI wants to run, with Run / Skip.
private struct ApprovalCard: View {
    let queries: [ChatQuery]
    let readBudget: Int
    let onApprove: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Run \(queries.count == 1 ? "this query" : "these \(queries.count) queries")?", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.convexText)
            ForEach(queries, id: \.id) { query in
                VStack(alignment: .leading, spacing: 4) {
                    Text(query.purpose.isEmpty ? "Query" : query.purpose)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.convexText)
                    Text(query.code)
                        .font(.convexMono(.caption2))
                        .foregroundStyle(Color.convexText)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.convexBackground, in: .rect(cornerRadius: 8))
                }
            }
            Text("Read-only, at most \(readBudget.formatted()) documents per query.")
                .font(.caption)
                .foregroundStyle(Color.convexSecondaryText)
            HStack(spacing: 10) {
                Button("Skip") { onApprove(false) }
                    .buttonStyle(.bordered)
                Button("Run") { onApprove(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.convexAccentFill)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(Color.convexSurface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.convexYellow.opacity(0.6)) }
    }
}

private struct FollowupChips: View {
    let followups: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(followups, id: \.self) { followup in
                Button {
                    onTap(followup)
                } label: {
                    Label(followup, systemImage: "arrow.turn.down.right")
                        .font(.footnote)
                        .foregroundStyle(Color.convexAccent)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.convexAccent.opacity(0.1), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// An answer's result inside a chat card: a big number, a ranked chart, rows, or a record.
private struct ChatResultView: View {
    let presentation: AnswerPresentation
    let title: String?
    let context: DataContext
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Eyebrow(title)
            }
            switch presentation {
            case .number(let text, let unit):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(text)
                        .font(.convexDisplay(.largeTitle, weight: .semibold))
                        .foregroundStyle(Color.convexText)
                    if let unit {
                        Text(unit)
                            .font(.convexMono(.subheadline))
                            .foregroundStyle(Color.convexSecondaryText)
                    }
                }
            case .text(let text):
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Color.convexText)
            case .ranking(let rows, let metric, let unit):
                RankingChart(rows: Array(rows.prefix(8)), metric: unit ?? metric)
                    .frame(height: CGFloat(min(rows.count, 8)) * 30 + 16)
                ForEach(visible(rows)) { row in
                    rowLink(row.documentId) { RankRowView(row: row, unit: unit) }
                }
                moreButton(total: rows.count)
            case .list(let rows):
                ForEach(visible(rows)) { row in
                    rowLink(row.documentId) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.convexText)
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(.convexMono(.caption2))
                                .foregroundStyle(Color.convexSecondaryText)
                                .lineLimit(2)
                                .opacity(row.subtitle.isEmpty ? 0 : 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                moreButton(total: rows.count)
            case .record(let fields):
                ForEach(fields, id: \.key) { field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.key)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexSecondaryText)
                        Spacer(minLength: 12)
                        Text(field.value)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexText)
                            .multilineTextAlignment(.trailing)
                    }
                }
            case .empty:
                Label("No results", systemImage: "tray")
                    .font(.footnote)
                    .foregroundStyle(Color.convexSecondaryText)
            }
        }
        .padding(12)
        .background(Color.convexBackground, in: .rect(cornerRadius: 12))
    }

    private func visible<Row>(_ rows: [Row]) -> [Row] {
        showsAll ? rows : Array(rows.prefix(5))
    }

    @ViewBuilder
    private func moreButton(total: Int) -> some View {
        if total > 5 {
            Button(showsAll ? "Show fewer" : "Show all \(total)") {
                withAnimation(.snappy) { showsAll.toggle() }
            }
            .font(.footnote.weight(.medium))
        }
    }

    @ViewBuilder
    private func rowLink(_ documentId: String?, @ViewBuilder label: () -> some View) -> some View {
        if let documentId {
            NavigationLink {
                DocumentLookupView(id: documentId, context: context)
            } label: {
                HStack {
                    label()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.convexSecondaryText.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
        } else {
            label()
        }
    }
}

// MARK: - Catalog

private struct CatalogCard: View {
    let catalog: CatalogViewModel
    let onOpen: () -> Void
    let onBuild: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.convexText)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.convexSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if catalog.info != nil {
                        Button("View", action: onOpen)
                    }
                    if !catalog.isBuilding {
                        Button(catalog.info == nil ? "Build catalog" : "Rebuild", action: onBuild)
                    }
                }
                .font(.footnote.weight(.semibold))
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if catalog.isBuilding { ProgressView() }
        }
        .padding(14)
        .background(Color.convexSurface, in: .rect(cornerRadius: 14))
    }

    private var icon: String {
        switch catalog.state {
        case .built: catalog.isStale ? "arrow.triangle.2.circlepath" : "books.vertical.fill"
        case .failed: "exclamationmark.triangle"
        default: "books.vertical"
        }
    }

    private var tint: Color {
        switch catalog.state {
        case .built: catalog.isStale ? .convexYellow : .convexGreen
        case .failed: .convexRed
        default: .convexAccent
        }
    }

    private var title: String {
        switch catalog.state {
        case .loading: "Data catalog"
        case .missing: "Build a data catalog first"
        case .built(let info): "Data catalog · \(info.tableCount) tables"
        case .building: "Building data catalog…"
        case .failed: "Couldn't load the data catalog"
        }
    }

    private var subtitle: String {
        switch catalog.state {
        case .loading: "Checking…"
        case .missing: "A one-time scan (about a minute, ~$0.05) so the AI knows what your tables and fields mean. Much better answers."
        case .built(let info):
            catalog.isStale
                ? "Built \(info.date.formatted(.relative(presentation: .named))), before your latest deploy. Rebuild to pick up changes."
                : "Built \(info.date.formatted(.relative(presentation: .named))). The AI uses it for every question."
        case .building(let progress): progress
        case .failed(let message): message
        }
    }
}

struct CatalogView: View {
    let catalog: CatalogViewModel
    let shareValues: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(PulseSettings.self) private var pulseSettings

    var body: some View {
        NavigationStack {
            List {
                if let info = catalog.info {
                    if !info.notes.isEmpty {
                        ConvexSection("Notes") {
                            ForEach(info.notes, id: \.self) { note in
                                Label(note, systemImage: "lightbulb")
                                    .font(.footnote)
                                    .foregroundStyle(Color.convexText)
                            }
                        }
                    }
                    if let text = info.text {
                        ConvexSection {
                            Text(text)
                                .font(.convexMono(.caption2))
                                .foregroundStyle(Color.convexText)
                                .textSelection(.enabled)
                        } header: {
                            Eyebrow("What the AI reads")
                        } footer: {
                            Text("Built \(info.date.formatted(date: .abbreviated, time: .shortened)) from each table's newest 100 documents. Values are only listed for status-like fields.")
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .convexScreenBackground()
            .navigationTitle("Data Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Rebuild", action: rebuild)
                        .disabled(catalog.isBuilding)
                }
            }
            .task {
                guard let pulse = pulseSettings.client, catalog.info?.text == nil else { return }
                await catalog.load(pulse: pulse)
            }
        }
    }

    private func close() {
        dismiss()
    }

    private func rebuild() {
        guard let pulse = pulseSettings.client else { return }
        dismiss()
        Task { await catalog.build(pulse: pulse, shareValues: shareValues) }
    }
}

// MARK: - History

private struct ChatHistoryView: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(PulseSettings.self) private var pulseSettings

    var body: some View {
        NavigationStack {
            List {
                if viewModel.threads.isEmpty {
                    Text("No past chats for this deployment.")
                        .foregroundStyle(Color.convexSecondaryText)
                }
                ForEach(viewModel.threads) { thread in
                    Button {
                        open(thread)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.convexText)
                                .lineLimit(2)
                            Text(thread.date, format: .relative(presentation: .named))
                                .font(.convexMono(.caption))
                                .foregroundStyle(Color.convexSecondaryText)
                        }
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { viewModel.threads[$0] }
                    guard let pulse = pulseSettings.client else { return }
                    Task { for thread in doomed { await viewModel.delete(thread, pulse: pulse) } }
                }
            }
            .convexScreenBackground()
            .navigationTitle("Past Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
            .task {
                guard let pulse = pulseSettings.client else { return }
                await viewModel.loadThreads(pulse: pulse)
            }
        }
    }

    private func open(_ thread: ChatThreadSummary) {
        guard let pulse = pulseSettings.client else { return }
        dismiss()
        Task { await viewModel.open(thread, pulse: pulse) }
    }

    private func close() {
        dismiss()
    }
}
