import SwiftUI

/// Function calls, errors and console output as they happen, read straight from Convex (no
/// monitoring backend, any plan). Only what Convex still holds in memory; nothing is stored.
struct LiveLogsView: View {
    @State private var viewModel: LiveLogsViewModel

    init(deploymentURL: URL, client: ConvexAPIClient) {
        _viewModel = State(initialValue: LiveLogsViewModel(deploymentURL: deploymentURL, client: client))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            ChipBar(items: [
                .init(id: LiveLogsViewModel.Filter.all, title: "All", count: viewModel.totalCount),
                .init(id: .errors, title: "Errors", count: viewModel.errorCount),
                .init(id: .logs, title: "Logs", count: viewModel.logCount),
            ], selection: $viewModel.filter)

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
            }

            ForEach(viewModel.visibleItems) { item in
                NavigationLink {
                    LiveLogDetailView(item: item)
                } label: {
                    LiveLogRow(item: item)
                }
                .listRowBackground(item.outcome == .failure ? Color.convexRed.opacity(0.08) : Color.convexSurface)
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.visibleItems.isEmpty && viewModel.errorMessage == nil {
                if viewModel.searchText.isEmpty {
                    ContentUnavailableView("Waiting for Calls", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Function calls show up here as they happen."))
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(viewModel.isPaused ? "Paused" : "Live from Convex · recent calls only, nothing is saved")
                .font(.convexMono(.caption2))
                .foregroundStyle(Color.convexSecondaryText)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .convexScreenBackground()
        .navigationTitle("Live Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search functions or messages")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.isPaused.toggle()
                } label: {
                    Label(viewModel.isPaused ? "Resume" : "Pause",
                          systemImage: viewModel.isPaused ? "play.fill" : "pause.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", systemImage: "trash", action: viewModel.clear)
            }
        }
        .task { await viewModel.stream() }
    }
}

private struct LiveLogRow: View {
    let item: LiveLogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                FunctionTypeBadge(type: item.type)
                Text(item.path)
                    .font(.convexMono(.subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(item.date, format: .dateTime.hour().minute().second())
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            HStack(spacing: 6) {
                Text(outcomeLabel)
                    .font(.convexMono(.caption2, weight: .semibold))
                    .foregroundStyle(outcomeColor)
                Text(detail)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
            }
            Text(preview)
                .font(.convexMono(.caption))
                .foregroundStyle(item.error == nil ? Color.convexText : Color.convexRed)
                .lineLimit(3)
                .opacity(preview.isEmpty ? 0 : 1)
                .frame(height: preview.isEmpty ? 0 : nil)
        }
        .padding(.vertical, 2)
    }

    private var outcomeLabel: String {
        switch item.outcome {
        case .success: "OK"
        case .failure: "ERROR"
        case .running: "RUNNING"
        }
    }

    private var outcomeColor: Color {
        switch item.outcome {
        case .success: .convexGreen
        case .failure: .convexRed
        case .running: .convexYellow
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let ms = item.durationMs { parts.append(MetricFormat.duration(ms)) }
        if item.isCached { parts.append("cached") }
        if let caller = item.caller, !caller.isEmpty { parts.append(caller) }
        if item.hasLogs { parts.append(item.lines.count == 1 ? "1 log" : "\(item.lines.count) logs") }
        return parts.joined(separator: " · ")
    }

    /// The error's first meaningful line, else the last console line.
    private var preview: String {
        if let error = item.error {
            return error.split(separator: "\n").map(String.init).first { !$0.isEmpty } ?? error
        }
        return item.lines.last.map { "[\($0.level)] \($0.message)" } ?? ""
    }
}

private struct LiveLogDetailView: View {
    let item: LiveLogItem

    var body: some View {
        List {
            ConvexSection {
                LabeledContent("Function", value: item.path)
                LabeledContent("Type", value: item.type)
                LabeledContent("Time", value: item.date.formatted(date: .abbreviated, time: .standard))
                if let ms = item.durationMs {
                    LabeledContent("Duration", value: MetricFormat.duration(ms))
                }
                if let caller = item.caller, !caller.isEmpty {
                    LabeledContent("Caller", value: caller)
                }
                LabeledContent("Request ID") {
                    Text(item.requestId)
                        .font(.convexMono(.caption))
                        .textSelection(.enabled)
                }
            }
            if let error = item.error {
                ConvexSection("Error") {
                    Text(error)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexRed)
                        .textSelection(.enabled)
                }
            }
            if item.hasLogs {
                ConvexSection("Console") {
                    ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.level)
                                .font(.convexMono(.caption2, weight: .semibold))
                                .foregroundStyle(color(line.level))
                            Text(line.message + (line.isTruncated ? " (truncated)" : ""))
                                .font(.convexMono(.caption))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .convexScreenBackground()
        .navigationTitle(item.outcome == .failure ? "Error" : "Call")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText)
            }
        }
    }

    private var shareText: String {
        ([item.path, item.error ?? ""] + item.lines.map { "[\($0.level)] \($0.message)" })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func color(_ level: String) -> Color {
        switch LogLevel(rawValue: level) {
        case .error: .convexRed
        case .warn: .convexYellow
        case .info: .convexBlue
        case .debug: .convexSecondaryText
        default: .convexText
        }
    }
}
