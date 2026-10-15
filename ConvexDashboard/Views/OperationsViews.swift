import SwiftUI

// MARK: - Schedules

/// Crons (last run, next run, history) and pending scheduled functions.
struct SchedulesView: View {
    @State private var viewModel: SchedulesViewModel

    init(deploymentURL: URL, client: ConvexAPIClient) {
        _viewModel = State(initialValue: SchedulesViewModel(deploymentURL: deploymentURL, client: client))
    }

    var body: some View {
        List {
            ConvexSection {
                SchedulesSummary(cronCount: viewModel.crons.count, failing: viewModel.failingCount,
                                 scheduledCount: viewModel.scheduled.count, hasMore: viewModel.hasMoreScheduled,
                                 hasLoaded: viewModel.hasLoaded)
            }

            if let error = viewModel.errorMessage {
                ConvexSection {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.convexRed)
                }
            }

            switch viewModel.tab {
            case .crons: cronsSection
            case .scheduled: scheduledSection
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $viewModel.tab) {
                    ForEach(SchedulesViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.loadIfNeeded() }
    }

    private var cronsSection: some View {
        ConvexSection {
            if viewModel.hasLoaded, viewModel.crons.isEmpty, viewModel.errorMessage == nil {
                Text("No cron jobs. Define them in convex/crons.ts.")
                    .foregroundStyle(Color.convexSecondaryText)
            }
            ForEach(viewModel.crons) { cron in
                NavigationLink {
                    CronDetailView(cron: cron, runs: viewModel.runsByCron[cron.name] ?? [])
                } label: {
                    CronRow(cron: cron)
                }
            }
        } header: {
            Eyebrow("Cron Jobs")
        } footer: {
            Text("Times are in your time zone. Convex keeps the last few runs of each cron.")
        }
    }

    private var scheduledSection: some View {
        ConvexSection {
            if viewModel.hasLoaded, viewModel.scheduled.isEmpty, viewModel.errorMessage == nil {
                Text("Nothing scheduled. Jobs from ctx.scheduler.runAfter / runAt appear here until they run.")
                    .foregroundStyle(Color.convexSecondaryText)
            }
            ForEach(viewModel.scheduled) { job in
                ScheduledJobRow(job: job)
            }
            if viewModel.hasMoreScheduled {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .onAppear(perform: viewModel.loadMoreScheduled)
            }
        } header: {
            Eyebrow("Pending, soonest first")
        }
    }
}

private struct SchedulesSummary: View {
    let cronCount: Int
    let failing: Int
    let scheduledCount: Int
    let hasMore: Bool
    let hasLoaded: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: failing > 0 ? "exclamationmark.octagon.fill" : "clock.badge.checkmark",
                     tint: !hasLoaded ? .convexSecondaryText : (failing > 0 ? .convexRed : .convexGreen), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.convexDisplay(.headline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                Text("\(cronCount) cron\(cronCount == 1 ? "" : "s") · \(scheduledCount)\(hasMore ? "+" : "") scheduled")
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Spacer(minLength: 0)
            if !hasLoaded { ProgressView() }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        if !hasLoaded { return "Checking schedules…" }
        if failing > 0 { return "\(failing) cron\(failing == 1 ? "" : "s") failing" }
        return "All crons healthy"
    }
}

private struct CronRow: View {
    let cron: CronJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(cron.name)
                    .font(.convexMono(.subheadline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Text(cron.schedule)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
                HStack(spacing: 10) {
                    Text(lastRunText)
                    Text(nextRunText)
                }
                .font(.convexMono(.caption2))
                .foregroundStyle(Color.convexSecondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if cron.isRunning { return "arrow.triangle.2.circlepath" }
        guard let run = cron.lastRun else { return "clock" }
        return run.isFailure ? "xmark" : "checkmark"
    }

    private var tint: Color {
        if cron.isRunning { return .convexBlue }
        guard let run = cron.lastRun else { return .convexSecondaryText }
        return run.isFailure ? .convexRed : .convexGreen
    }

    private var lastRunText: String {
        guard let date = cron.lastRun?.date else { return "Never ran" }
        return "Ran \(date.formatted(.relative(presentation: .named)))"
    }

    private var nextRunText: String {
        if cron.isRunning { return "Running now" }
        guard let next = cron.nextRun else { return "" }
        return "Next \(next.formatted(.relative(presentation: .named)))"
    }
}

private struct ScheduledJobRow: View {
    let job: ScheduledJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: job.isRunning ? "arrow.triangle.2.circlepath" : "calendar.badge.clock",
                     tint: job.isRunning ? .convexBlue : .convexAccent, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.functionPath)
                    .font(.convexMono(.subheadline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(timeText)
                    .font(.convexMono(.caption))
                    .foregroundStyle(isOverdue ? Color.convexYellow : Color.convexSecondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    /// A pending job whose time has passed means the scheduler is behind.
    private var isOverdue: Bool {
        !job.isRunning && (job.scheduledFor ?? .distantFuture) < .now.addingTimeInterval(-60)
    }

    private var timeText: String {
        if job.isRunning { return "Running now" }
        guard let date = job.scheduledFor else { return "Pending" }
        let relative = date.formatted(.relative(presentation: .named))
        return isOverdue ? "Overdue · was due \(relative)" : "Runs \(relative) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct CronDetailView: View {
    let cron: CronJob
    let runs: [CronRun]

    var body: some View {
        List {
            ConvexSection {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Cron job")
                    Text(cron.name)
                        .font(.convexDisplay(.title3, weight: .medium))
                        .foregroundStyle(Color.convexText)
                    Text(cron.functionPath)
                        .font(.convexMono(.subheadline))
                        .foregroundStyle(Color.convexText)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                LabeledContent("Schedule", value: cron.schedule)
                if let next = cron.nextRun {
                    LabeledContent("Next run") {
                        Text(cron.isRunning ? "Running now" : next.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }

            ConvexSection {
                if runs.isEmpty {
                    Text("No runs recorded yet.")
                        .foregroundStyle(Color.convexSecondaryText)
                }
                ForEach(runs) { run in
                    CronRunRow(run: run)
                }
            } header: {
                Eyebrow("Recent Runs")
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Cron")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CronRunRow: View {
    let run: CronRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusDot(isHealthy: !run.isFailure)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(run.isFailure ? Color.convexRed : Color.convexText)
                Spacer()
                Text(run.durationText ?? "")
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Text(run.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "")
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexSecondaryText)
            if case .failed(let message) = run.status {
                Text(message)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexText)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            ForEach(Array(run.logLines.prefix(10).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch run.status {
        case .success: "Succeeded"
        case .failed: "Failed"
        case .canceled(let count): "Skipped (\(count) run\(count == 1 ? "" : "s") overlapped)"
        }
    }
}

// MARK: - History

/// Deploys, env var changes, data edits, and integrations, newest first.
struct HistoryView: View {
    @State private var viewModel: HistoryViewModel

    init(deployment: Deployment, deploymentURL: URL, client: ConvexAPIClient) {
        _viewModel = State(initialValue: HistoryViewModel(deployment: deployment, deploymentURL: deploymentURL, client: client))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                ConvexSection {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.convexRed)
                }
            }

            if viewModel.chipItems.count > 2 {
                ChipBar(items: viewModel.chipItems, selection: $viewModel.category)
            }

            if !viewModel.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.sections.isEmpty, viewModel.errorMessage == nil {
                Text("No history yet.")
                    .foregroundStyle(Color.convexSecondaryText)
            }

            ForEach(viewModel.sections) { section in
                ConvexSection(section.day.formatted(.dateTime.weekday(.wide).month().day())) {
                    ForEach(section.events) { event in
                        NavigationLink {
                            HistoryEventDetailView(event: event, author: viewModel.author(of: event))
                        } label: {
                            HistoryRow(event: event, author: viewModel.author(of: event))
                        }
                    }
                }
            }

            if viewModel.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .onAppear(perform: viewModel.loadMore)
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task { await viewModel.loadIfNeeded() }
    }
}

private struct HistoryRow: View {
    let event: DeploymentEvent
    let author: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: event.systemImage, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.convexText)
                    Spacer(minLength: 6)
                    Text(event.date, format: .dateTime.hour().minute())
                        .font(.convexMono(.caption2))
                        .foregroundStyle(Color.convexSecondaryText)
                }
                Text(event.summary)
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(3)
                    .opacity(event.summary.isEmpty ? 0 : 1)
                    .frame(height: event.summary.isEmpty ? 0 : nil)
                Text(author)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch event.category {
        case .deploys: .convexAccent
        case .environment: .convexYellow
        case .data: .convexBlue
        default: .convexSecondaryText
        }
    }
}

struct HistoryEventDetailView: View {
    let event: DeploymentEvent
    let author: String

    var body: some View {
        List {
            ConvexSection {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemImage: event.systemImage, tint: .convexAccent, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(event.category.rawValue)
                        Text(event.title)
                            .font(.convexDisplay(.title3, weight: .medium))
                            .foregroundStyle(Color.convexText)
                        Text(event.date.formatted(date: .abbreviated, time: .standard))
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexSecondaryText)
                        Text(author)
                            .font(.convexMono(.caption))
                            .foregroundStyle(Color.convexSecondaryText)
                    }
                }
                .padding(.vertical, 6)
            }

            ForEach(event.details, id: \.self) { detail in
                ConvexSection(detail.label) {
                    ForEach(Array(detail.values.enumerated()), id: \.offset) { _, value in
                        Text(value)
                            .font(.convexMono(.subheadline))
                            .foregroundStyle(Color.convexText)
                            .textSelection(.enabled)
                    }
                }
            }

            if event.details.isEmpty, event.category == .deploys {
                ConvexSection {
                    Text("No function, index, or cron changes in this deploy.")
                        .foregroundStyle(Color.convexSecondaryText)
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: event.raw.prettyJSON)
            }
        }
    }
}
