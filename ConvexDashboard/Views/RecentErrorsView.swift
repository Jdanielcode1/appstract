import SwiftUI

/// Latest failed function executions across the whole deployment.
struct RecentErrorsView: View {
    @State private var viewModel: RecentErrorsViewModel

    init(deploymentName: String, source: any MonitoringSource) {
        _viewModel = State(initialValue: RecentErrorsViewModel(deploymentName: deploymentName, source: source))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
            }
            ForEach(viewModel.errors) { error in
                NavigationLink {
                    ErrorDetailView(error: error)
                } label: {
                    ErrorRow(error: error, showPath: true)
                }
            }
        }
        .overlay {
            if !viewModel.hasLoaded {
                ProgressView()
            } else if viewModel.errors.isEmpty && viewModel.errorMessage == nil {
                ContentUnavailableView("No Recent Errors", systemImage: "checkmark.seal",
                                       description: Text("Failed function calls from the last 7 days show up here."))
            }
        }
        .convexScreenBackground()
        .navigationTitle("Errors")
        .refreshable { await viewModel.load() }
        .task { await viewModel.autoRefresh() }
    }
}

struct ErrorRow: View {
    let error: FunctionError
    let showPath: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showPath {
                HStack(spacing: 6) {
                    FunctionTypeBadge(type: error.type)
                    Text(error.path)
                        .font(.convexMono(.subheadline))
                        .lineLimit(1)
                }
            }
            Text(error.headline)
                .font(.convexMono(.caption))
                .foregroundStyle(Color.convexRed)
                .lineLimit(2)
            Text(error.timestamp.dateFromMillis, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(Color.convexSecondaryText)
        }
        .padding(.vertical, 2)
    }
}

struct ErrorDetailView: View {
    let error: FunctionError

    var body: some View {
        List {
            ConvexSection {
                LabeledContent("Function", value: error.path)
                LabeledContent("Type", value: error.type)
                LabeledContent("Time", value: error.timestamp.dateFromMillis.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Request ID") {
                    Text(error.requestId)
                        .font(.convexMono(.caption))
                        .textSelection(.enabled)
                }
            }
            ConvexSection("Message") {
                Text(error.message)
                    .font(.convexMono(.caption))
                    .textSelection(.enabled)
            }
        }
        .convexScreenBackground()
        .navigationTitle("Error")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: "\(error.path)\n\(error.message)")
            }
        }
    }
}
