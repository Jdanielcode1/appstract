import SwiftUI

/// console.* output from a monitored deployment, newest first, polling every 5s.
struct LogsView: View {
    @State private var viewModel: LogsViewModel

    init(deploymentName: String, source: any MonitoringSource) {
        _viewModel = State(initialValue: LogsViewModel(deploymentName: deploymentName, source: source))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            ConvexSection {
                Picker("Level", selection: $viewModel.levelFilter) {
                    ForEach(LogsViewModel.LevelFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
            }

            ForEach(viewModel.visibleEntries) { entry in
                LogRow(entry: entry)
            }
        }
        .listStyle(.plain)
        .overlay {
            if !viewModel.hasLoaded {
                ProgressView()
            } else if viewModel.visibleEntries.isEmpty && viewModel.errorMessage == nil {
                if viewModel.searchText.isEmpty {
                    ContentUnavailableView("No Logs", systemImage: "text.alignleft",
                                           description: Text("console.log output from the last 24 hours shows up here."))
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            }
        }
        .convexScreenBackground()
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search messages or functions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.isPaused.toggle()
                } label: {
                    Label(viewModel.isPaused ? "Resume" : "Pause",
                          systemImage: viewModel.isPaused ? "play.fill" : "pause.fill")
                }
            }
        }
        .refreshable { await viewModel.load() }
        // Restarts (and reloads immediately) when the level filter changes.
        .task(id: viewModel.levelFilter) { await viewModel.autoRefresh() }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    @State private var isExpanded = false

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.level)
                        .font(.convexMono(.caption2, weight: .semibold))
                        .foregroundStyle(levelColor)
                    Text(entry.path)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.timestamp.dateFromMillis, format: .dateTime.hour().minute().second())
                        .font(.convexMono(.caption2))
                        .foregroundStyle(Color.convexSecondaryText)
                }
                Text(entry.message)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(isExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                if entry.isTruncated && isExpanded {
                    Text("Message truncated")
                        .font(.caption2)
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapses the message" : "Shows the full message")
        .listRowBackground(entry.level == LogLevel.error.rawValue ? Color.convexRed.opacity(0.08) : Color.convexSurface)
    }

    private func toggle() {
        isExpanded.toggle()
    }

    private var levelColor: Color {
        switch LogLevel(rawValue: entry.level) {
        case .error: .convexRed
        case .warn: .convexYellow
        case .info: .convexBlue
        case .debug: .convexSecondaryText
        default: .convexText
        }
    }
}
