import Charts
import SwiftUI

/// Convex's official health insights for a deployment, fetched from the Convex dashboard API.
struct InsightsView: View {
    @State private var viewModel: InsightsViewModel

    init(deployment: Deployment, client: ConvexAPIClient) {
        _viewModel = State(initialValue: InsightsViewModel(deployment: deployment, client: client))
    }

    var body: some View {
        List {
            ConvexSection {
                InsightsSummary(errors: viewModel.errorCount, warnings: viewModel.warningCount,
                                hasLoaded: viewModel.hasLoaded, failed: viewModel.errorMessage != nil)
            } footer: {
                Text("From Convex — the same insights as the Health page on dashboard.convex.dev. Last 72 hours.")
            }

            if let error = viewModel.errorMessage {
                ConvexSection {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.convexRed)
                }
            }

            if !viewModel.insights.isEmpty {
                ConvexSection("Issues") {
                    ForEach(viewModel.insights) { insight in
                        NavigationLink {
                            InsightDetailView(insight: insight)
                        } label: {
                            InsightRow(insight: insight)
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }
}

private struct InsightsSummary: View {
    let errors: Int
    let warnings: Int
    let hasLoaded: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: icon, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.convexDisplay(.headline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                Text(subtitle)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Spacer(minLength: 0)
            if !hasLoaded { ProgressView() }
        }
        .padding(.vertical, 6)
    }

    private var isHealthy: Bool { hasLoaded && !failed && errors + warnings == 0 }

    private var icon: String {
        if !hasLoaded || failed { return "stethoscope" }
        if isHealthy { return "checkmark.seal.fill" }
        return errors > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if !hasLoaded || failed { return .convexSecondaryText }
        if isHealthy { return .convexGreen }
        return errors > 0 ? .convexRed : .convexYellow
    }

    private var title: String {
        if !hasLoaded { return "Checking health…" }
        if failed { return "Couldn't load insights" }
        if isHealthy { return "No issues found" }
        return [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil,
                warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var subtitle: String {
        isHealthy ? "No read limits or write conflicts in 72h" : "Read limits and write conflicts"
    }
}

extension Insight {
    var tint: Color { isError ? .convexRed : .convexYellow }
    var systemImage: String { isWriteConflict ? "arrow.triangle.merge" : "doc.text.magnifyingglass" }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: insight.systemImage, tint: insight.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.convexDisplay(.headline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                Text(insight.functionPath)
                    .font(.convexMono(.subheadline))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(insight.summary)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                if !insight.hourlyCounts.isEmpty {
                    InsightChart(insight: insight)
                        .frame(height: 36)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Affected calls per hour.
struct InsightChart: View {
    let insight: Insight

    var body: some View {
        Chart(insight.hourlyCounts) { point in
            if let date = point.date {
                BarMark(x: .value("Hour", date, unit: .hour), y: .value("Calls", point.count))
                    .foregroundStyle(insight.tint.gradient)
            }
        }
    }
}

struct InsightDetailView: View {
    let insight: Insight

    var body: some View {
        List {
            ConvexSection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        IconTile(systemImage: insight.systemImage, tint: insight.tint, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Eyebrow(insight.isError ? "Error" : "Warning")
                            Text(insight.title)
                                .font(.convexDisplay(.title3, weight: .medium))
                                .foregroundStyle(Color.convexText)
                        }
                    }
                    Text(insight.functionPath)
                        .font(.convexMono(.subheadline, weight: .medium))
                        .foregroundStyle(Color.convexText)
                        .textSelection(.enabled)
                    Text(insight.summary)
                        .font(.convexMono(.caption))
                        .foregroundStyle(Color.convexSecondaryText)
                }
                .padding(.vertical, 6)
            }

            if !insight.hourlyCounts.isEmpty {
                ConvexSection("Affected Calls per Hour") {
                    InsightChart(insight: insight)
                        .frame(height: 160)
                        .padding(.vertical, 6)
                }
            }

            ConvexSection {
                Text(insight.explanation)
                    .font(.callout)
                    .foregroundStyle(Color.convexText)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: insight.learnMoreURL) {
                    Label("Learn more in the Convex docs", systemImage: "book")
                }
            } header: {
                Eyebrow("What it means")
            }

            if !insight.recentEvents.isEmpty {
                ConvexSection("Recent Events") {
                    ForEach(insight.recentEvents) { event in
                        InsightEventRow(event: event, isWriteConflict: insight.isWriteConflict)
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Insight")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InsightEventRow: View {
    let event: Insight.Event
    let isWriteConflict: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let date = event.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                } else {
                    Text(event.timestamp)
                }
                Spacer()
                Text(event.requestId)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.convexMono(.caption))
            .foregroundStyle(Color.convexSecondaryText)

            Text(detail)
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexText)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    /// Conflict source and document, or the tables read and how much.
    private var detail: String {
        if isWriteConflict {
            let source = event.occWriteSource.map { "Conflicted with \($0)" } ?? "Write conflict"
            let retries = event.occRetryCount.map { " · \($0) retr\($0 == 1 ? "y" : "ies")" } ?? ""
            return source + retries
        }
        let reads = (event.calls ?? []).map { call in
            "\(call.tableName): \(call.documentsRead.formatted()) docs, \(MetricFormat.bytes(call.bytesRead))"
        }
        return reads.isEmpty ? "No read details" : reads.joined(separator: "\n")
    }
}
