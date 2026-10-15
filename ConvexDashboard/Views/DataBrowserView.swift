import SwiftUI

/// Read-only browser for a deployment's tables (deployment screen → Data).
struct DataBrowserView: View {
    @State private var context: DataContext
    @State private var viewModel: DataBrowserViewModel
    @State private var lookupId = ""
    @State private var lookupTarget: DocumentLookupTarget?

    init(deploymentURL: URL, client: ConvexAPIClient) {
        let context = DataContext(deploymentURL: deploymentURL, client: client)
        _context = State(initialValue: context)
        _viewModel = State(initialValue: DataBrowserViewModel(context: context))
    }

    var body: some View {
        List {
            ConvexSection {
                HStack(spacing: 10) {
                    Image(systemName: "number")
                        .foregroundStyle(Color.convexSecondaryText)
                    TextField("Document ID", text: $lookupId)
                        .font(.convexMono(.subheadline))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(lookUp)
                    Button("Open", action: lookUp)
                        .font(.subheadline.weight(.medium))
                        .disabled(trimmedLookupId.isEmpty)
                }
            } header: {
                Eyebrow("Look Up")
            } footer: {
                Text("Paste an ID from any table, e.g. from an error or a user report.")
            }

            if let error = viewModel.errorMessage {
                ConvexSection {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.convexRed)
                }
            }

            ConvexSection {
                if !viewModel.hasLoaded {
                    ProgressView()
                } else if viewModel.visibleTables.isEmpty, viewModel.errorMessage == nil {
                    Text(viewModel.searchText.isEmpty ? "No tables yet." : "No matching tables.")
                        .foregroundStyle(Color.convexSecondaryText)
                }
                ForEach(viewModel.visibleTables) { table in
                    NavigationLink {
                        TableDocumentsView(table: table.name, context: context)
                    } label: {
                        TableRow(table: table)
                    }
                }
            } header: {
                Eyebrow("Tables")
            } footer: {
                Text("Read-only. Browsing reads documents, which counts toward database bandwidth.")
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Filter tables")
        .refreshable { await viewModel.load() }
        .task { await viewModel.loadIfNeeded() }
        .navigationDestination(item: $lookupTarget) { target in
            DocumentLookupView(id: target.id, context: context)
        }
    }

    private var trimmedLookupId: String {
        lookupId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lookUp() {
        guard !trimmedLookupId.isEmpty else { return }
        lookupTarget = DocumentLookupTarget(id: trimmedLookupId)
    }
}

struct DocumentLookupTarget: Identifiable, Hashable {
    let id: String
}

private struct TableRow: View {
    let table: DataBrowserViewModel.Table

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "tablecells", tint: .convexAccent, size: 30)
            Text(table.name)
                .font(.convexMono(.subheadline))
                .foregroundStyle(Color.convexText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(table.count.map { $0.formatted() } ?? "–")
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexSecondaryText)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Table

enum DataViewMode: String, CaseIterable, Identifiable {
    case cards = "Cards"
    case grid = "Grid"
    var id: String { rawValue }
    var systemImage: String { self == .cards ? "rectangle.grid.1x2" : "tablecells" }
}

struct TableDocumentsView: View {
    @State private var viewModel: TableDocumentsViewModel
    @State private var isEditingFilter = false
    @State private var isEditingLayout = false
    @State private var selectedDocument: ConvexDocument?
    @AppStorage("dataViewMode") private var mode: DataViewMode = .cards

    init(table: String, indexMatch: IndexMatch? = nil, context: DataContext) {
        _viewModel = State(initialValue: TableDocumentsViewModel(table: table, indexMatch: indexMatch, context: context))
    }

    var body: some View {
        Group {
            switch mode {
            case .cards: cardList
            case .grid: grid
            }
        }
        .convexScreenBackground()
        .navigationTitle(viewModel.table)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Filter", systemImage: viewModel.filter == nil
                       ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                       action: editFilter)
                Menu("Options", systemImage: "ellipsis.circle") {
                    Picker("View", selection: $mode) {
                        ForEach(DataViewMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    Picker("Sort", selection: $viewModel.order) {
                        Label("Newest first", systemImage: "arrow.down").tag(DocumentOrder.desc)
                        Label("Oldest first", systemImage: "arrow.up").tag(DocumentOrder.asc)
                    }
                    Button("Customize Cards…", systemImage: "slider.horizontal.3", action: editLayout)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        .task { await viewModel.loadIfNeeded() }
        .sheet(isPresented: $isEditingFilter) {
            FilterEditorView(filter: viewModel.filter, fields: viewModel.knownFields) { viewModel.filter = $0 }
        }
        .sheet(isPresented: $isEditingLayout) {
            CardLayoutEditorView(layout: viewModel.layout, fields: Array(viewModel.knownFields.dropFirst(2)),
                                 isCustomized: viewModel.isCustomized, onSave: viewModel.saveLayout)
        }
        .navigationDestination(item: $selectedDocument) { document in
            DocumentDetailView(document: document, table: viewModel.table, context: viewModel.context)
        }
    }

    private var cardList: some View {
        List {
            statusRows
            ConvexSection {
                ForEach(viewModel.documents) { document in
                    Button {
                        selectedDocument = document
                    } label: {
                        HStack(spacing: 8) {
                            if let card = viewModel.cards[document.id] {
                                DocumentCardRow(card: card, creationTime: document.creationTime, showsAvatar: viewModel.layout.image != nil)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.convexSecondaryText.opacity(0.6))
                        }
                    }
                }
                footerRow
            } header: {
                Eyebrow(header)
            }
        }
        .listSectionSpacing(.compact)
    }

    private var grid: some View {
        DocumentGrid(frozenColumn: viewModel.frozenColumn, columns: viewModel.columns, rows: viewModel.gridRows,
                     onSelect: select) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(header)
                if let match = viewModel.indexMatch {
                    FilterChip(label: match.label, systemImage: "link", onEdit: nil, onClear: nil)
                }
                if let filter = viewModel.filter {
                    FilterChip(label: filter.label, systemImage: "line.3.horizontal.decrease.circle.fill",
                               onEdit: editFilter, onClear: clearFilter)
                }
                if let error = viewModel.errorMessage ?? viewModel.filterErrors.first {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.convexRed)
                }
            }
            .padding(.horizontal, 20)
        } footer: {
            footerRow
                .padding()
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        if let match = viewModel.indexMatch {
            FilterChip(label: match.label, systemImage: "link", onEdit: nil, onClear: nil)
        }
        if let filter = viewModel.filter {
            FilterChip(label: filter.label, systemImage: "line.3.horizontal.decrease.circle.fill",
                       onEdit: editFilter, onClear: clearFilter)
        }
        ForEach(viewModel.filterErrors, id: \.self) { error in
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.convexYellow)
        }
        if let error = viewModel.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.convexRed)
        }
    }

    private var header: String {
        if viewModel.indexMatch != nil || viewModel.filter != nil { return "Matches" }
        guard let count = viewModel.count else { return "Documents" }
        return "\(count.formatted()) document\(count == 1 ? "" : "s")"
    }

    /// Loads the next page when it scrolls into view; also shows loading/empty/end states.
    @ViewBuilder
    private var footerRow: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if viewModel.reachedLimit {
            Text("Showing the first \(TableDocumentsViewModel.maximumLoaded) documents. Use a filter to find others.")
                .font(.footnote)
                .foregroundStyle(Color.convexSecondaryText)
        } else if viewModel.canLoadMore {
            Button("Load more", action: viewModel.loadMore)
                .frame(maxWidth: .infinity)
                .onAppear(perform: viewModel.loadMore)
        } else if viewModel.hasLoaded, viewModel.documents.isEmpty, viewModel.errorMessage == nil {
            Text(viewModel.filter == nil ? "No documents." : "No documents match this filter.")
                .foregroundStyle(Color.convexSecondaryText)
        }
    }

    private func select(_ document: ConvexDocument) {
        selectedDocument = document
    }

    private func editFilter() {
        isEditingFilter = true
    }

    private func editLayout() {
        isEditingLayout = true
    }

    private func clearFilter() {
        viewModel.filter = nil
    }
}

private struct FilterChip: View {
    let label: String
    let systemImage: String
    let onEdit: (() -> Void)?
    let onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.convexAccent)
            Button {
                onEdit?()
            } label: {
                Text(label)
                    .font(.convexMono(.subheadline))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(onEdit == nil)
            if let onClear {
                Button("Clear filter", systemImage: "xmark.circle.fill", action: onClear)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.convexSecondaryText)
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Smart card: avatar (image field or initials), title, subtitle, badges, and age.
private struct DocumentCardRow: View {
    let card: DocumentCard
    let creationTime: Date?
    let showsAvatar: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsAvatar {
                DocumentAvatar(card: card, size: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.convexText)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(creationTime ?? .distantPast, format: .relative(presentation: .named))
                        .font(.convexMono(.caption2))
                        .foregroundStyle(Color.convexSecondaryText)
                        .opacity(creationTime == nil ? 0 : 1)
                }
                Text(card.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
                    .opacity(card.subtitle.isEmpty ? 0 : 1)
                BadgeRow(badges: card.badges)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BadgeRow: View {
    let badges: [DocumentCard.Badge]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge.text)
                    .font(.convexMono(.caption2, weight: .medium))
                    .foregroundStyle(badge.isFlag ? Color.convexGreen : Color.convexAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((badge.isFlag ? Color.convexGreen : Color.convexAccent).opacity(0.14), in: .capsule)
                    .lineLimit(1)
            }
        }
        .frame(height: badges.isEmpty ? 0 : nil)
        .opacity(badges.isEmpty ? 0 : 1)
    }
}

private struct DocumentAvatar: View {
    let card: DocumentCard
    let size: CGFloat

    var body: some View {
        AsyncImage(url: card.imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Text(card.initials.isEmpty ? "?" : card.initials)
                    .font(.convexDisplay(size > 50 ? .title3 : .subheadline, weight: .medium))
                    .foregroundStyle(Color.convexAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.convexAccent.opacity(0.16))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

// MARK: - Grid

/// Spreadsheet view: a frozen first column, horizontally scrolling columns, and a pinned header row.
private struct DocumentGrid<Header: View, Footer: View>: View {
    let frozenColumn: String
    let columns: [String]
    let rows: [DocumentGridRow]
    let onSelect: (ConvexDocument) -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    private let frozenWidth: CGFloat = 150
    private let columnWidth: CGFloat = 150
    private let rowHeight: CGFloat = 44

    init(frozenColumn: String, columns: [String], rows: [DocumentGridRow], onSelect: @escaping (ConvexDocument) -> Void,
         @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.frozenColumn = frozenColumn
        self.columns = columns
        self.rows = rows
        self.onSelect = onSelect
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
                HStack(alignment: .top, spacing: 0) {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(rows) { row in
                                Button { onSelect(row.document) } label: {
                                    cell(row.frozen, width: frozenWidth, emphasized: true)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            headerCell(frozenColumn, width: frozenWidth)
                        }
                    }
                    .frame(width: frozenWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.convexHairline).frame(width: 1)
                    }

                    ScrollView(.horizontal) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            Section {
                                ForEach(rows) { row in
                                    Button { onSelect(row.document) } label: {
                                        HStack(spacing: 0) {
                                            ForEach(row.cells.indices, id: \.self) { index in
                                                cell(row.cells[index], width: columnWidth, emphasized: false)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack(spacing: 0) {
                                    ForEach(columns, id: \.self) { column in
                                        headerCell(column, width: columnWidth)
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                }
                .background(Color.convexSurface)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.convexHairline)
                }
                .padding(.horizontal, 16)
                footer
            }
            .padding(.vertical, 12)
        }
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.convexMono(.caption, weight: .semibold))
            .foregroundStyle(Color.convexSecondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: width, height: 34, alignment: .leading)
            .background(Color.convexBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.convexHairline).frame(height: 1)
            }
    }

    private func cell(_ text: String, width: CGFloat, emphasized: Bool) -> some View {
        Text(text)
            .font(emphasized ? .subheadline.weight(.medium) : .convexMono(.caption))
            .foregroundStyle(Color.convexText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(width: width, height: rowHeight, alignment: .leading)
            .contentShape(.rect)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.convexHairline.opacity(0.6)).frame(height: 0.5)
            }
    }
}

// MARK: - Filter

private struct FilterEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var field: String
    @State private var op: DocumentFilter.Operator
    @State private var value: String
    let fields: [String]
    let isEditing: Bool
    let onApply: (DocumentFilter?) -> Void

    init(filter: DocumentFilter?, fields: [String], onApply: @escaping (DocumentFilter?) -> Void) {
        _field = State(initialValue: filter?.field ?? "")
        _op = State(initialValue: filter?.op ?? .eq)
        _value = State(initialValue: filter.map { if case .string(let text) = $0.value { text } else { $0.value.prettyJSON } } ?? "")
        self.fields = fields
        self.isEditing = filter != nil
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                ConvexSection("Field") {
                    TextField("e.g. email", text: $field)
                        .font(.convexMono(.body))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.self) { name in
                                    Button(name) { field = name }
                                        .font(.convexMono(.caption, weight: .medium))
                                        .buttonStyle(.bordered)
                                        .tint(name == field ? .convexAccentFill : .convexSecondaryText)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                ConvexSection("Condition") {
                    Picker("Operator", selection: $op) {
                        ForEach(DocumentFilter.Operator.allCases) { op in
                            Text(op.symbol).tag(op)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                ConvexSection {
                    TextField("Value", text: $value)
                        .font(.convexMono(.body))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Eyebrow("Value")
                } footer: {
                    Text("Numbers, true, false and null are matched as those types. Wrap in quotes (\"42\") to match text.")
                }
            }
            .convexScreenBackground()
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply)
                        .disabled(trimmedField.isEmpty)
                }
                if isEditing {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remove Filter", role: .destructive, action: remove)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmedField: String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [String] {
        let query = trimmedField
        let matches = query.isEmpty ? fields : fields.filter { $0.localizedStandardContains(query) }
        return Array(matches.prefix(12))
    }

    private func apply() {
        onApply(DocumentFilter(field: trimmedField, op: op, value: JSONValue(userInput: value)))
        dismiss()
    }

    private func remove() {
        onApply(nil)
        dismiss()
    }

    private func cancel() {
        dismiss()
    }
}

// MARK: - Card layout

/// Pick which fields a table's cards show. Saved on this device per deployment and table.
private struct CardLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var layout: CardLayout
    let fields: [String]
    let isCustomized: Bool
    let onSave: (CardLayout?) -> Void

    init(layout: CardLayout, fields: [String], isCustomized: Bool, onSave: @escaping (CardLayout?) -> Void) {
        _layout = State(initialValue: layout)
        self.fields = fields
        self.isCustomized = isCustomized
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                ConvexSection {
                    fieldPicker("Title", selection: $layout.title)
                    fieldPicker("Subtitle", selection: $layout.subtitle)
                    fieldPicker("Image URL", selection: $layout.image)
                } header: {
                    Eyebrow("Card")
                }

                ConvexSection {
                    ForEach(fields, id: \.self) { field in
                        Button {
                            toggleBadge(field)
                        } label: {
                            HStack {
                                Text(field)
                                    .font(.convexMono(.subheadline))
                                    .foregroundStyle(Color.convexText)
                                Spacer()
                                Image(systemName: layout.badges.contains(field) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(layout.badges.contains(field) ? Color.convexAccentFill : Color.convexSecondaryText)
                            }
                        }
                        .disabled(!layout.badges.contains(field) && layout.badges.count >= 3)
                    }
                } header: {
                    Eyebrow("Badges")
                } footer: {
                    Text("Up to 3. True booleans show the field name; text shows its value.")
                }

                if isCustomized {
                    ConvexSection {
                        Button("Reset to Automatic", role: .destructive, action: reset)
                    }
                }
            }
            .convexScreenBackground()
            .navigationTitle("Customize Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func fieldPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(fields, id: \.self) { field in
                Text(field).tag(String?.some(field))
            }
        }
    }

    private func toggleBadge(_ field: String) {
        if let index = layout.badges.firstIndex(of: field) {
            layout.badges.remove(at: index)
        } else if layout.badges.count < 3 {
            layout.badges.append(field)
        }
    }

    private func save() {
        onSave(layout)
        dismiss()
    }

    private func reset() {
        onSave(nil)
        dismiss()
    }

    private func cancel() {
        dismiss()
    }
}

// MARK: - Document

struct DocumentDetailView: View {
    @State private var viewModel: DocumentDetailViewModel

    init(document: ConvexDocument, table: String?, context: DataContext) {
        _viewModel = State(initialValue: DocumentDetailViewModel(document: document, table: table, context: context))
    }

    private var document: ConvexDocument { viewModel.document }
    private var context: DataContext { viewModel.context }

    var body: some View {
        List {
            ConvexSection {
                DocumentHeader(card: viewModel.card, table: viewModel.table, document: document)
            }

            relatedSection

            ForEach(viewModel.groups, id: \.title) { group in
                ConvexSection(group.title) {
                    ForEach(group.fields, id: \.key) { field in
                        FieldRow(key: field.key, value: field.value, context: context)
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle(viewModel.table ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: document.raw.prettyJSON)
            }
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        ConvexSection {
            if viewModel.isSearchingRelated {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching indexes…")
                        .foregroundStyle(Color.convexSecondaryText)
                }
            } else if !viewModel.hasSchema {
                Text("Related documents need a schema with indexes.")
                    .foregroundStyle(Color.convexSecondaryText)
            } else if !viewModel.hasSearchedRelated {
                Button(action: findRelated) {
                    SettingsRow("Find Related Documents", systemImage: "arrow.triangle.branch", tint: .convexBlue) {
                        Text("\(viewModel.relatedLookupCount) lookups")
                    }
                }
            } else if viewModel.related.isEmpty {
                Text("Nothing else references this document.")
                    .foregroundStyle(Color.convexSecondaryText)
            }
            ForEach(viewModel.related) { group in
                NavigationLink {
                    TableDocumentsView(table: group.reference.table,
                                       indexMatch: IndexMatch(index: group.reference.index, field: group.reference.field, value: group.key),
                                       context: context)
                } label: {
                    RelatedRow(group: group)
                }
            }
        } header: {
            Eyebrow("Related")
        } footer: {
            Text("Checks indexed ID fields for this document's _id or tokenIdentifier. Each lookup reads only matching documents.")
        }
    }

    private func findRelated() {
        Task { await viewModel.loadRelated() }
    }
}

private struct DocumentHeader: View {
    let card: DocumentCard
    let table: String?
    let document: ConvexDocument

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DocumentAvatar(card: card, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(table ?? "Document")
                Text(card.title)
                    .font(.convexDisplay(.title3, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(2)
                Text(card.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
                    .opacity(card.subtitle.isEmpty ? 0 : 1)
                BadgeRow(badges: card.badges)
                Text(document.id)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                if let created = document.creationTime {
                    Text("Created \(created, format: .dateTime.month().day().year().hour().minute())")
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct RelatedRow: View {
    let group: RelatedGroup

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "arrow.triangle.branch", tint: .convexBlue, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.reference.table)
                    .font(.convexMono(.subheadline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                Text("via \(group.reference.field)")
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Spacer(minLength: 8)
            Text(group.hasMore ? "\(group.count)+" : "\(group.count)")
                .font(.convexMono(.subheadline, weight: .medium))
                .foregroundStyle(Color.convexText)
        }
    }
}

/// A field; objects and arrays open a nested view, document IDs open that document.
struct FieldRow: View {
    let key: String
    let value: JSONValue
    let context: DataContext

    var body: some View {
        if value.isContainer {
            NavigationLink {
                JSONValueView(title: key, value: value, context: context)
            } label: {
                content
            }
        } else if let id = value.documentId {
            NavigationLink {
                DocumentLookupView(id: id, context: context)
            } label: {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(key)
                    .font(.convexMono(.caption, weight: .medium))
                    .foregroundStyle(Color.convexSecondaryText)
                Text(value.typeLabel)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText.opacity(0.7))
            }
            if let date = value.timestampDate {
                Text(date, format: .dateTime.month().day().year().hour().minute())
                    .font(.convexMono(.subheadline))
                    .foregroundStyle(Color.convexText)
                Text("\(value.preview) · \(date, format: .relative(presentation: .named))")
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            } else {
                Text(value.preview)
                    .font(.convexMono(.subheadline))
                    .foregroundStyle(value == .null ? Color.convexSecondaryText : Color.convexText)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Contents of a nested object or array.
struct JSONValueView: View {
    let title: String
    let value: JSONValue
    let context: DataContext

    var body: some View {
        List {
            ConvexSection(value.preview) {
                ForEach(value.children, id: \.key) { child in
                    FieldRow(key: child.key, value: child.value, context: context)
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: value.prettyJSON)
            }
        }
    }
}

/// Loads a document by ID, then shows it.
struct DocumentLookupView: View {
    @State private var viewModel: DocumentLookupViewModel
    private let context: DataContext

    init(id: String, context: DataContext) {
        self.context = context
        _viewModel = State(initialValue: DocumentLookupViewModel(id: id, context: context))
    }

    var body: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .convexScreenBackground()
                .task { await viewModel.load() }
        case .found(let document):
            DocumentDetailView(document: document, table: nil, context: context)
        case .missing:
            ContentUnavailableView("No Document", systemImage: "doc.questionmark",
                                   description: Text("Nothing in this deployment has the ID \(viewModel.id)."))
                .convexScreenBackground()
        case .failed(let message):
            ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle", description: Text(message))
                .convexScreenBackground()
        }
    }
}
