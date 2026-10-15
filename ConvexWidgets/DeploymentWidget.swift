import SwiftUI
import WidgetKit

@main
struct ConvexWidgetsBundle: WidgetBundle {
    init() {
        ConvexFont.register()
    }

    var body: some Widget {
        DeploymentWidget()
    }
}

/// Calls today, errors in 24h, limit pressure, paused state, and last deploy for one deployment.
struct DeploymentWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DeploymentWidget", intent: SelectDeploymentIntent.self, provider: DeploymentProvider()) { entry in
            DeploymentWidgetView(entry: entry)
                .containerBackground(Color.convexBackground, for: .widget)
        }
        .configurationDisplayName("Deployment")
        .description("Function calls, errors, and usage limits for a Convex deployment.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct DeploymentEntry: TimelineEntry {
    let date: Date
    let snapshot: DeploymentSnapshot?
    let message: String?
}

struct DeploymentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DeploymentEntry {
        DeploymentEntry(date: .now, snapshot: .sample, message: nil)
    }

    func snapshot(for configuration: SelectDeploymentIntent, in context: Context) async -> DeploymentEntry {
        if context.isPreview { return placeholder(in: context) }
        return await entry(for: configuration)
    }

    func timeline(for configuration: SelectDeploymentIntent, in context: Context) async -> Timeline<DeploymentEntry> {
        let entry = await entry(for: configuration)
        // Usage totals update every few minutes; 30 min keeps within WidgetKit's refresh budget.
        let next = Date.now.addingTimeInterval(entry.snapshot == nil ? 15 * 60 : 30 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func entry(for configuration: SelectDeploymentIntent) async -> DeploymentEntry {
        guard let source = WidgetDataSource() else {
            return DeploymentEntry(date: .now, snapshot: nil, message: WidgetDataError.signedOut.localizedDescription)
        }
        var choice = configuration.deployment
        if choice == nil { choice = await DeploymentQuery().defaultResult() }
        guard let choice else {
            return DeploymentEntry(date: .now, snapshot: nil, message: "Edit the widget to choose a deployment.")
        }
        do {
            let snapshot = try await source.snapshot(name: choice.id, projectName: choice.projectName)
            return DeploymentEntry(date: .now, snapshot: snapshot, message: nil)
        } catch {
            return DeploymentEntry(date: .now, snapshot: nil, message: error.localizedDescription)
        }
    }
}

// MARK: - Views

struct DeploymentWidgetView: View {
    let entry: DeploymentEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium: MediumDeploymentView(snapshot: snapshot)
            case .accessoryRectangular: RectangularDeploymentView(snapshot: snapshot)
            case .accessoryCircular: CircularDeploymentView(snapshot: snapshot)
            case .accessoryInline: Text(WidgetText.inline(snapshot))
            default: SmallDeploymentView(snapshot: snapshot)
            }
        } else {
            MessageView(message: entry.message ?? "No data", family: family)
        }
    }
}

/// Precomputed strings shared by every size.
enum WidgetText {
    static func calls(_ value: Double?) -> String {
        value.map { $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) } ?? "–"
    }

    static func errors(_ snapshot: DeploymentSnapshot) -> String {
        guard let errors = snapshot.errors24h else { return "Not monitored" }
        return errors == 1 ? "1 error · 24h" : "\(errors.formatted(.number.notation(.compactName))) errors · 24h"
    }

    static func lastDeploy(_ snapshot: DeploymentSnapshot) -> String {
        guard let date = snapshot.lastDeploy else { return "Never deployed" }
        return "Deployed " + date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func inline(_ snapshot: DeploymentSnapshot) -> String {
        if snapshot.isPaused { return "\(snapshot.title) · paused" }
        var parts = [snapshot.title, "\(calls(snapshot.callsToday)) calls"]
        if let errors = snapshot.errors24h { parts.append("\(errors) err") }
        return parts.joined(separator: " · ")
    }

    static func typeColor(_ type: String) -> Color {
        switch type {
        case "prod": .convexAccent
        case "dev": .convexGreen
        default: .convexBlue
        }
    }
}

private struct Header: View {
    let snapshot: DeploymentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle()
                    .fill(WidgetText.typeColor(snapshot.deploymentType))
                    .frame(width: 6, height: 6)
                Text(snapshot.title)
                    .font(.convexDisplay(.subheadline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
            }
            Text(snapshot.deploymentType.uppercased())
                .font(.convexMono(.caption2, weight: .medium))
                .foregroundStyle(Color.convexSecondaryText)
        }
    }
}

private struct PausedPill: View {
    let snapshot: DeploymentSnapshot

    var body: some View {
        Label(snapshot.state == "disabled" ? "Disabled" : "Paused", systemImage: "pause.circle.fill")
            .font(.convexMono(.caption2, weight: .semibold))
            .foregroundStyle(Color.convexYellow)
    }
}

private struct SmallDeploymentView: View {
    let snapshot: DeploymentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(snapshot: snapshot)
            Spacer(minLength: 4)
            if snapshot.isPaused {
                PausedPill(snapshot: snapshot)
            } else {
                Text(WidgetText.calls(snapshot.callsToday))
                    .font(.convexDisplay(.title, weight: .semibold))
                    .foregroundStyle(Color.convexText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("calls today")
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Spacer(minLength: 4)
            Text(WidgetText.errors(snapshot))
                .font(.convexMono(.caption2, weight: .medium))
                .foregroundStyle((snapshot.errors24h ?? 0) > 0 ? Color.convexRed : Color.convexSecondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MediumDeploymentView: View {
    let snapshot: DeploymentSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SmallDeploymentView(snapshot: snapshot)
            VStack(alignment: .leading, spacing: 8) {
                StatLine(label: "This month", value: "\(WidgetText.calls(snapshot.callsMonth)) calls", tint: .convexText)
                if let fraction = snapshot.limitFraction {
                    VStack(alignment: .leading, spacing: 3) {
                        StatLine(label: snapshot.limitName ?? "Usage limit", value: WidgetText.percent(fraction),
                                 tint: fraction >= 0.8 ? .convexYellow : .convexText)
                        ProgressView(value: min(fraction, 1))
                            .tint(fraction >= 1 ? Color.convexRed : fraction >= 0.8 ? Color.convexYellow : Color.convexGreen)
                    }
                } else {
                    StatLine(label: "Usage limit", value: "None set", tint: .convexSecondaryText)
                }
                Spacer(minLength: 0)
                Text(WidgetText.lastDeploy(snapshot))
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct StatLine: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.convexMono(.caption2, weight: .medium))
                .foregroundStyle(Color.convexSecondaryText)
                .lineLimit(1)
            Text(value)
                .font(.convexMono(.subheadline, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

/// Lock Screen: name, then calls and errors, then paused / last deploy.
private struct RectangularDeploymentView: View {
    let snapshot: DeploymentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snapshot.title)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
            Text("\(WidgetText.calls(snapshot.callsToday)) calls today")
                .lineLimit(1)
            Text(snapshot.isPaused ? "\(Image(systemName: "pause.fill")) Paused" : "\(WidgetText.errors(snapshot))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lock Screen circle: usage-limit gauge when there is one, otherwise calls today.
private struct CircularDeploymentView: View {
    let snapshot: DeploymentSnapshot

    var body: some View {
        if snapshot.isPaused {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "pause.fill")
                    .font(.title3)
            }
        } else if let fraction = snapshot.limitFraction {
            Gauge(value: min(fraction, 1)) {
                Text("Limit")
            } currentValueLabel: {
                Text(WidgetText.percent(fraction))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(WidgetText.calls(snapshot.callsToday))
                        .font(.headline)
                        .minimumScaleFactor(0.5)
                    Text("calls")
                        .font(.caption2)
                }
            }
        }
    }
}

private struct MessageView: View {
    let message: String
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline, .accessoryCircular:
            Image(systemName: "exclamationmark.triangle")
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Convex")
                    .font(.convexDisplay(.subheadline, weight: .medium))
                    .foregroundStyle(Color.convexText)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
