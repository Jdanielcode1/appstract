import Charts
import SwiftUI

struct FunctionDetailView: View {
    @State private var viewModel: FunctionDetailViewModel

    init(stat: FunctionStat, window: StatWindow, deploymentName: String, source: any MonitoringSource) {
        _viewModel = State(initialValue: FunctionDetailViewModel(
            stat: stat, window: window, deploymentName: deploymentName, source: source
        ))
    }

    private var stat: FunctionStat { viewModel.stat }

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

            ConvexSection {
                HStack {
                    StatTile(title: "Calls", value: MetricFormat.count(stat.calls))
                    StatTile(title: "Error Rate", value: MetricFormat.percent(stat.errorRate),
                             tint: stat.errors > 0 ? .convexRed : nil)
                    StatTile(title: "p95", value: MetricFormat.duration(stat.p95Ms))
                }
                if !viewModel.timeseries.isEmpty {
                    CallsChart(points: viewModel.timeseries)
                        .frame(height: 140)
                    LatencyChart(points: viewModel.timeseries)
                        .frame(height: 120)
                }
            }

            ConvexSection("Performance") {
                LabeledContent("Average", value: MetricFormat.duration(stat.avgMs))
                LabeledContent("p95", value: MetricFormat.duration(stat.p95Ms))
                LabeledContent("Max", value: MetricFormat.duration(stat.maxMs))
                if stat.type == "query" {
                    LabeledContent("Cached", value: stat.calls > 0
                        ? MetricFormat.percent(Double(stat.cachedCalls) / Double(stat.calls)) : "–")
                }
            }

            ConvexSection("Database") {
                LabeledContent("Documents Read", value: MetricFormat.count(stat.docsRead))
                LabeledContent("Documents Written", value: MetricFormat.count(stat.docsWritten))
                LabeledContent("Bytes Read", value: MetricFormat.bytes(stat.dbReadBytes))
                LabeledContent("Bytes Written", value: MetricFormat.bytes(stat.dbWriteBytes))
                LabeledContent("Egress", value: MetricFormat.bytes(stat.egressBytes))
            }

            ConvexSection("Recent Errors") {
                if viewModel.errors.isEmpty {
                    Text("No recent errors.")
                        .foregroundStyle(Color.convexSecondaryText)
                }
                ForEach(viewModel.errors) { error in
                    NavigationLink {
                        ErrorDetailView(error: error)
                    } label: {
                        ErrorRow(error: error, showPath: false)
                    }
                }
            }
        }
        .convexScreenBackground()
        .navigationTitle(stat.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(stat.name).font(.convexDisplay(.headline, weight: .medium))
                    Text(stat.module).font(.caption).foregroundStyle(Color.convexSecondaryText)
                }
            }
        }
        .refreshable { await viewModel.load() }
        .task(id: viewModel.window) { await viewModel.autoRefresh() }
    }
}

private struct LatencyChart: View {
    let points: [TimeseriesPoint]

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Time", point.date), y: .value("p95 (ms)", point.p95Ms))
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.convexYellow)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYAxisLabel("p95 ms")
    }
}
