import SwiftUI

/// Full alert: message, where it came from, delivery status, and shortcuts to investigate.
struct AlertEventDetailView: View {
    let event: AlertEvent
    let pulse: PulseClient

    var body: some View {
        List {
            ConvexSection {
                AlertEventHeader(event: event)
            }

            ConvexSection("Message") {
                Text(event.body)
                    .font(.convexMono(.callout))
                    .foregroundStyle(Color.convexText)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }

            ConvexSection("Details") {
                if !event.isTest {
                    LabeledContent("Deployment") {
                        Text(event.deploymentName)
                            .font(.convexMono(.subheadline))
                    }
                }
                if let path = event.path {
                    LabeledContent("Function") {
                        Text(path)
                            .font(.convexMono(.subheadline))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                LabeledContent("Fired", value: event.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Delivery", value: deliverySummary)
            }

            if !event.isTest {
                ConvexSection("Investigate") {
                    NavigationLink {
                        RecentErrorsView(deploymentName: event.deploymentName, source: pulse)
                    } label: {
                        SettingsRow("Recent Errors", systemImage: "exclamationmark.octagon", tint: .convexRed)
                    }
                    NavigationLink {
                        LogsView(deploymentName: event.deploymentName, source: pulse)
                    } label: {
                        SettingsRow("Live Logs", systemImage: "text.alignleft", tint: .convexBlue)
                    }
                    NavigationLink {
                        FunctionsView(deploymentName: event.deploymentName, source: pulse)
                    } label: {
                        SettingsRow("Function Health", systemImage: "waveform.path.ecg", tint: .convexGreen)
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .convexScreenBackground()
        .navigationTitle("Alert")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: "\(event.title)\n\(event.body)")
            }
        }
    }

    private var deliverySummary: String {
        if let count = event.deliveredCount, count > 0 { return "Apple push to \(count) device\(count == 1 ? "" : "s")" }
        return "Local notification"
    }
}

private struct AlertEventHeader: View {
    let event: AlertEvent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: event.systemImage, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(kindLabel)
                Text(event.title)
                    .font(.convexDisplay(.title3, weight: .medium))
                    .foregroundStyle(Color.convexText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.date, format: .relative(presentation: .named))
                    .font(.convexMono(.caption))
                    .foregroundStyle(Color.convexSecondaryText)
            }
        }
        .padding(.vertical, 6)
    }

    private var kindLabel: String {
        AlertRule.Kind(rawValue: event.kind)?.title ?? "Test"
    }

    private var tint: Color {
        event.isTest ? .convexSecondaryText : (AlertRule.Kind(rawValue: event.kind)?.tint ?? .convexRed)
    }
}
