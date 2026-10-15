import Charts
import SwiftUI

/// Last-hour metrics at the top of the deployment screen: function calls, failure rate, and cache
/// hit rate, plus a link to every chart. Shares its view model with `DeploymentMetricsView`.
struct MetricsSummarySection: View {
    let viewModel: DeploymentMetricsViewModel

    var body: some View {
        ConvexSection {
            VStack(alignment: .leading, spacing: 10) {
                SummaryHeader(title: "Function Calls", value: callsSummary, tint: nil)
                chartOrPlaceholder(viewModel.functionCalls, empty: "No calls in the last hour.", height: 120) { series in
                    MetricLinesChart(series: series, domain: viewModel.domain, title: "Calls")
                }
                ForEach(viewModel.functionCalls.series.prefix(3)) { line in
                    LegendRow(name: line.name, color: MetricColors.color(for: line, in: viewModel.functionCalls.series),
                              value: MetricFormat.count(Int(line.total)))
                }
            }
            .padding(.vertical, 4)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SummaryHeader(title: "Failure Rate", value: MetricsText.failureSummary(viewModel.failureRate.series),
                                  tint: MetricsText.failureTint(viewModel.failureRate.series))
                    chartOrPlaceholder(viewModel.failureRate, empty: "No calls", height: 70) { series in
                        MetricLinesChart(series: series, domain: viewModel.domain, title: "Failure %", yDomain: 0...100, compact: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SummaryHeader(title: "Cache Hit Rate", value: MetricsText.cacheSummary(viewModel.cacheHitRate.series), tint: nil)
                    chartOrPlaceholder(viewModel.cacheHitRate, empty: "No queries yet", height: 70) { series in
                        MetricLinesChart(series: series, domain: viewModel.domain, title: "Cache hit %", yDomain: 0...100, compact: true)
                    }
                }
            }
            .padding(.vertical, 4)

            NavigationLink {
                DeploymentMetricsView(viewModel: viewModel)
            } label: {
                SettingsRow("All Metrics", systemImage: "chart.xyaxis.line", tint: .convexBlue) {
                    Text("Concurrency, lag")
                }
            }
        } header: {
            Eyebrow("Last Hour")
        }
    }

    private var callsSummary: String {
        guard case .loaded(let series) = viewModel.functionCalls else { return "–" }
        return MetricFormat.count(Int(series.reduce(0) { $0 + $1.total }))
    }

    @ViewBuilder
    private func chartOrPlaceholder<Content: View>(_ chart: DeploymentMetricsViewModel.Chart, empty: String, height: CGFloat,
                                                   @ViewBuilder content: ([MetricSeries]) -> Content) -> some View {
        Group {
            switch chart {
            case .loading:
                ProgressView()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.convexYellow)
            case .loaded(let series) where series.isEmpty:
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
            case .loaded(let series):
                content(series)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
}

private struct SummaryHeader: View {
    let title: String
    let value: String
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(title)
            Text(value)
                .font(.convexDisplay(.title3))
                .foregroundStyle(tint ?? .convexText)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Every chart, with full legends. Deployment screen → Last Hour → All Metrics.
struct DeploymentMetricsView: View {
    let viewModel: DeploymentMetricsViewModel

    var body: some View {
        List {
            MetricChartSection(
                title: "Function Calls",
                chart: viewModel.functionCalls,
                domain: viewModel.domain,
                summary: { series in MetricFormat.count(Int(series.reduce(0) { $0 + $1.total })) + " calls" },
                legendValue: { MetricFormat.count(Int($0.total)) },
                empty: "No function calls in the last hour.",
                footer: "Calls per minute for the 5 busiest functions."
            )
            MetricChartSection(
                title: "Failure Rate",
                chart: viewModel.failureRate,
                domain: viewModel.domain,
                yDomain: 0...100,
                unit: "%",
                summary: MetricsText.failureSummary,
                summaryTint: MetricsText.failureTint,
                legendValue: { "peak \(MetricsText.percent($0.peak))" },
                empty: "No function calls in the last hour.",
                footer: "Share of calls that failed, per minute, for the functions failing most."
            )
            MetricChartSection(
                title: "Cache Hit Rate",
                chart: viewModel.cacheHitRate,
                domain: viewModel.domain,
                yDomain: 0...100,
                unit: "%",
                summary: MetricsText.cacheSummary,
                legendValue: { $0.latest.map(MetricsText.percent) ?? "–" },
                empty: "Data will appear here as your queries run.",
                footer: "Share of query calls served from Convex's cache."
            )
            MetricChartSection(
                title: "Running Functions",
                chart: viewModel.running,
                domain: viewModel.domain,
                colors: MetricColors.typeColor,
                summary: { series in "Peak \(MetricsText.number(series.map(\.peak).max() ?? 0))" },
                legendValue: { "peak \(MetricsText.number($0.peak))" },
                empty: "No concurrency data in the last hour.",
                footer: nil
            )
            MetricChartSection(
                title: "Queued Functions",
                chart: viewModel.queued,
                domain: viewModel.domain,
                colors: MetricColors.typeColor,
                summary: { series in
                    let peak = series.map(\.peak).max() ?? 0
                    return peak == 0 ? "None queued" : "Peak \(MetricsText.number(peak))"
                },
                summaryTint: { series in (series.map(\.peak).max() ?? 0) > 0 ? .convexYellow : .convexGreen },
                legendValue: { "peak \(MetricsText.number($0.peak))" },
                empty: "No concurrency data in the last hour.",
                footer: "Functions waiting for a free slot. Anything above zero means the deployment is at its concurrency limit."
            )
            MetricChartSection(
                title: "Scheduler Lag",
                chart: viewModel.schedulerLag,
                domain: viewModel.domain,
                unit: " min",
                colors: { _ in .convexYellow },
                summary: { series in
                    let latest = series.first?.latest ?? 0
                    return latest < 1 ? "On time" : "\(MetricsText.number(latest)) min behind"
                },
                summaryTint: { series in (series.first?.latest ?? 0) >= 1 ? .convexYellow : .convexGreen },
                legendValue: nil,
                empty: "No scheduled functions in the last hour.",
                footer: "How far behind scheduled functions and crons are running."
            )
        }
        .convexScreenBackground()
        .navigationTitle("Metrics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Metrics").font(.convexDisplay(.headline, weight: .medium))
                    Text(subtitle).font(.convexMono(.caption2)).foregroundStyle(Color.convexSecondaryText)
                }
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.autoRefresh() }
    }

    private var subtitle: String {
        guard let updated = viewModel.lastUpdated else { return "Last hour" }
        return "Last hour · updated \(updated.formatted(date: .omitted, time: .shortened))"
    }
}

enum MetricsText {
    static func percent(_ value: Double) -> String {
        MetricFormat.percent(value / 100)
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func failureSummary(_ series: [MetricSeries]) -> String {
        guard !series.isEmpty else { return "–" }
        let peak = series.map(\.peak).max() ?? 0
        return peak == 0 ? "No failures" : "Peak \(percent(peak))"
    }

    static func failureTint(_ series: [MetricSeries]) -> Color? {
        guard !series.isEmpty else { return nil }
        return (series.map(\.peak).max() ?? 0) > 0 ? .convexRed : .convexGreen
    }

    static func cacheSummary(_ series: [MetricSeries]) -> String {
        let latest = series.compactMap(\.latest)
        return latest.isEmpty ? "–" : "\(percent(latest.reduce(0, +) / Double(latest.count))) now"
    }
}

enum MetricColors {
    static let palette: [Color] = [.convexAccent, .convexBlue, .convexGreen, .convexYellow, .convexAero]

    static func color(for line: MetricSeries, in series: [MetricSeries]) -> Color {
        if line.isRest { return .convexSecondaryText }
        let index = series.filter { !$0.isRest }.firstIndex { $0.id == line.id } ?? 0
        return palette[index % palette.count]
    }

    static func typeColor(_ name: String) -> Color {
        switch name {
        case "Queries": .convexBlue
        case "Mutations": .convexAccent
        case "Actions": .convexGreen
        case "Actions (Node)": .convexAero
        default: .convexYellow
        }
    }
}

/// Multi-line chart over a fixed last-hour x axis. `compact` drops the axes for small tiles.
struct MetricLinesChart: View {
    let series: [MetricSeries]
    let domain: ClosedRange<Date>
    let title: String
    var yDomain: ClosedRange<Double>?
    var unit = ""
    var colors: ((String) -> Color)?
    var compact = false

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points) { point in
                    LineMark(x: .value("Time", point.date), y: .value(title, point.value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))
                }
                .foregroundStyle(by: .value("Series", line.name))
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(color))
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .modifier(YDomain(domain: yDomain))
        .chartXAxis {
            if !compact {
                AxisMarks(values: .stride(by: .minute, count: 15)) { value in
                    AxisGridLine().foregroundStyle(Color.convexHairline)
                    // A label at the right edge gets clipped.
                    if let date = value.as(Date.self), domain.upperBound.timeIntervalSince(date) > 300 {
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.convexMono(.caption2))
                    }
                }
            }
        }
        .chartYAxis {
            if compact {
                AxisMarks(values: [yDomain?.lowerBound ?? 0]) { _ in
                    AxisGridLine().foregroundStyle(Color.convexHairline)
                }
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.convexHairline)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number.formatted(.number.notation(.compactName)) + unit)
                                .font(.convexMono(.caption2))
                        }
                    }
                }
            }
        }
    }

    private func color(_ line: MetricSeries) -> Color {
        colors?(line.name) ?? MetricColors.color(for: line, in: series)
    }
}

/// One chart card: headline, multi-line chart, and a legend with a value per line.
private struct MetricChartSection: View {
    let title: String
    let chart: DeploymentMetricsViewModel.Chart
    let domain: ClosedRange<Date>
    var yDomain: ClosedRange<Double>?
    var unit = ""
    var colors: ((String) -> Color)?
    let summary: ([MetricSeries]) -> String
    var summaryTint: (([MetricSeries]) -> Color?)?
    let legendValue: ((MetricSeries) -> String)?
    let empty: String
    let footer: String?

    var body: some View {
        ConvexSection {
            switch chart {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.convexYellow)
            case .loaded(let series) where series.isEmpty:
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(Color.convexSecondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .loaded(let series):
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary(series))
                        .font(.convexDisplay(.title3))
                        .foregroundStyle(summaryTint?(series) ?? .convexText)
                        .contentTransition(.numericText())
                    MetricLinesChart(series: series, domain: domain, title: title, yDomain: yDomain, unit: unit, colors: colors)
                        .frame(height: 160)
                }
                .padding(.vertical, 4)
                if let legendValue, series.count > 1 || series.first?.isRest == false {
                    ForEach(series) { line in
                        LegendRow(name: line.name, color: colors?(line.name) ?? MetricColors.color(for: line, in: series), value: legendValue(line))
                    }
                }
            }
        } header: {
            Eyebrow(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

private struct YDomain: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}

private struct LegendRow: View {
    let name: String
    let color: Color
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 4)
            Text(name)
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(.convexMono(.caption, weight: .medium))
                .foregroundStyle(Color.convexSecondaryText)
        }
    }
}
