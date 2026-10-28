import Charts
import SwiftUI

/// Function health for one deployment: totals, a calls/errors chart, and a sortable function list.
struct FunctionsView: View {
    @State private var viewModel: FunctionsViewModel
    private let source: any MonitoringSource
    /// False on 5-minute checks (no log stream): counts only, no latency, usage or error messages.
    private let hasDetails: Bool

    init(deploymentName: String, source: any MonitoringSource, hasDetails: Bool = true) {
        self.source = source
        self.hasDetails = hasDetails
        _viewModel = State(initialValue: FunctionsViewModel(deploymentName: deploymentName, source: source))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            ConvexSection {
                Picker("Window", selection: $viewModel.window) {
                    ForEach(StatWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
            }

            if let summary = viewModel.summary {
                ConvexSection {
                    HStack {
                        StatTile(title: "Calls", value: MetricFormat.count(summary.totals.calls))
                        StatTile(title: "Errors", value: MetricFormat.count(summary.totals.errors),
                                 tint: summary.totals.errors > 0 ? .convexRed : nil)
                        StatTile(title: "Error Rate", value: MetricFormat.percent(summary.totals.errorRate),
                                 tint: summary.totals.errorRate > 0.01 ? .convexRed : nil)
                    }
                    if !viewModel.timeseries.isEmpty {
                        CallsChart(points: viewModel.timeseries)
                            .frame(height: 140)
                    }
                } footer: {
                    if let updated = viewModel.lastUpdated {
                        Text(hasDetails
                             ? "Updated \(updated.formatted(.relative(presentation: .named))) · refreshes every 15s"
                             : "Counts update every 5 minutes, up to a few minutes behind. Turn on instant errors for latency and error details.")
                    }
                }

                ConvexSection {
                    Picker("Sort", selection: $viewModel.sort) {
                        ForEach(FunctionsViewModel.Sort.allCases.filter { hasDetails || $0 != .slowest }) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    ForEach(viewModel.functions) { stat in
                        NavigationLink {
                            FunctionDetailView(stat: stat, window: viewModel.window, deploymentName: viewModel.deploymentName,
                                               source: source, hasDetails: hasDetails)
                        } label: {
                            FunctionRow(stat: stat, showsLatency: hasDetails)
                        }
                    }
                } header: {
                    Eyebrow("Functions")
                }
            }
        }
        .overlay {
            if viewModel.summary == nil && viewModel.errorMessage == nil {
                ProgressView()
            } else if let summary = viewModel.summary, summary.functions.isEmpty {
                ContentUnavailableView(
                    "No Function Calls Yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Events appear here a few seconds after functions run on this deployment.")
                )
            }
        }
        .convexScreenBackground()
        .navigationTitle("Functions")
        .searchable(text: $viewModel.searchText, prompt: "Filter functions")
        .toolbar {
            if hasDetails {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RecentErrorsView(deploymentName: viewModel.deploymentName, source: source)
                    } label: {
                        Label("Errors", systemImage: "exclamationmark.octagon")
                    }
                }
            }
        }
        .refreshable { await viewModel.load() }
        // Restarts (and reloads immediately) whenever the window changes.
        .task(id: viewModel.window) { await viewModel.autoRefresh() }
    }
}

private struct FunctionRow: View {
    let stat: FunctionStat
    let showsLatency: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                FunctionTypeBadge(type: stat.type)
                Text(stat.path)
                    .font(.convexMono(.subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Label(MetricFormat.count(stat.calls), systemImage: "arrow.triangle.2.circlepath")
                if showsLatency {
                    Label("p95 \(MetricFormat.duration(stat.p95Ms))", systemImage: "timer")
                }
                if stat.errors > 0 {
                    Label(MetricFormat.percent(stat.errorRate), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.convexRed)
                }
            }
            .font(.convexMono(.caption))
            .foregroundStyle(Color.convexSecondaryText)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
    }
}

/// Calls per bucket, with errors overlaid in red.
struct CallsChart: View {
    let points: [TimeseriesPoint]

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Time", point.date), y: .value("Calls", point.calls))
                .foregroundStyle(Color.convexAccent.opacity(0.55))
            if point.errors > 0 {
                BarMark(x: .value("Time", point.date), y: .value("Errors", point.errors))
                    .foregroundStyle(Color.convexRed)
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
    }
}
