import SwiftUI

/// Small ⓘ button that shows an explanation in a popover bubble (also on iPhone).
struct InfoButton<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder let content: Content
    @State private var isPresented = false

    init(_ accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        Button(action: show) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Color.convexSecondaryText)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPresented) {
            content
                .padding(16)
                .frame(idealWidth: 300, maxWidth: 340)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Color.convexSurface)
        }
    }

    private func show() {
        isPresented = true
    }
}

/// Popover body for a usage metric.
struct MetricInfoView: View {
    let info: MetricInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(info.unit)
            Text(info.title)
                .font(.convexDisplay(.headline, weight: .medium))
                .foregroundStyle(Color.convexText)
            Text(info.explanation)
                .font(.callout)
                .foregroundStyle(Color.convexText)
                .fixedSize(horizontal: false, vertical: true)
            if let note = info.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.convexSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Side-by-side comparison of Convex deployment classes, highlighting the current one.
struct DeploymentClassesView: View {
    @Environment(\.dismiss) private var dismiss
    let current: String

    var body: some View {
        NavigationStack {
            List {
                ConvexSection {
                    Text(ConvexReference.classSummary)
                        .font(.callout)
                        .foregroundStyle(Color.convexText)
                }

                ForEach(ConvexReference.deploymentClasses) { deploymentClass in
                    ConvexSection {
                        ClassCard(deploymentClass: deploymentClass, isCurrent: deploymentClass.id == current.lowercased())
                    }
                }

                ConvexSection {
                    Link(destination: ConvexReference.classesDocsURL) {
                        Label("Convex limits documentation", systemImage: "book")
                    }
                } footer: {
                    Text("Limits for D1024 and D2048 can be raised for Business and Enterprise plans on request.")
                }
            }
            .listSectionSpacing(.compact)
            .convexScreenBackground()
            .navigationTitle("Deployment Classes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ClassCard: View {
    let deploymentClass: ConvexReference.DeploymentClass
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(deploymentClass.id.uppercased())
                    .font(.convexDisplay(.title2))
                    .foregroundStyle(isCurrent ? Color.convexAccent : Color.convexText)
                Text(deploymentClass.kind)
                    .font(.convexMono(.caption, weight: .medium))
                    .foregroundStyle(Color.convexSecondaryText)
                Spacer()
                if isCurrent {
                    Text("THIS DEPLOYMENT")
                        .font(.convexMono(.caption2, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.convexAccent.opacity(0.16), in: .capsule)
                        .foregroundStyle(Color.convexAccent)
                }
            }
            Text("Plans: \(deploymentClass.plans)")
                .font(.footnote)
                .foregroundStyle(Color.convexSecondaryText)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                spec("Concurrent queries", deploymentClass.concurrentQueries)
                spec("Concurrent mutations", deploymentClass.concurrentMutations)
                spec("Actions (Convex / Node)", "\(deploymentClass.concurrentActions) / \(deploymentClass.nodeActions)")
                spec("Scheduled jobs", deploymentClass.scheduledJobs)
                spec("Concurrent sessions", deploymentClass.sessions)
                spec("Write throughput", deploymentClass.writeThroughput)
                spec("Query cache", deploymentClass.queryCache)
                spec("Max dataset", deploymentClass.maxDataset)
                spec("Backups", deploymentClass.backups)
            }
        }
        .padding(.vertical, 6)
    }

    private func spec(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.convexSecondaryText)
            Text(value)
                .font(.convexMono(.footnote, weight: .medium))
                .foregroundStyle(Color.convexText)
        }
    }
}
