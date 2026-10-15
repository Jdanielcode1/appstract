import SwiftUI

/// The middle tab: Ask AI about the selected deployment. The top-left button switches project or
/// deployment; switching starts a fresh chat.
struct ChatTabView: View {
    @State private var model: ChatTabModel
    @State private var isPicking = false
    @Environment(PulseSettings.self) private var pulseSettings
    private let client: ConvexAPIClient

    init(session: SessionStore.Session) {
        client = session.client
        _model = State(initialValue: ChatTabModel(session: session))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let deployment = model.selected, let url = deployment.deploymentUrl.flatMap(URL.init(string:)) {
                    ChatView(deployment: deployment, deploymentURL: url, client: client,
                             projectName: model.selectedProjectName, onPickDeployment: showPicker)
                        .id(deployment.name)
                } else {
                    placeholder
                }
            }
        }
        .task {
            model.backendDeploymentName = pulseSettings.client?.deploymentURL.host()?.components(separatedBy: ".").first
            await model.loadIfNeeded()
        }
        .sheet(isPresented: $isPicking) {
            DeploymentPickerSheet(model: model)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading projects…")
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load projects", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: reload)
                }
            } else {
                ContentUnavailableView("No deployments", systemImage: "folder",
                                       description: Text("This token can't see any cloud deployments."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .convexScreenBackground()
        .navigationTitle("Ask AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func showPicker() {
        model.refreshRecent()
        isPicking = true
    }

    private func reload() {
        Task { await model.load() }
    }
}

/// Projects with their deployments; picking one closes the sheet.
private struct DeploymentPickerSheet: View {
    let model: ChatTabModel
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty, !model.recent.isEmpty {
                    ConvexSection("Recent chats") {
                        ForEach(model.recent) { deployment in
                            Button {
                                pick(deployment)
                            } label: {
                                PickerRow(deployment: deployment, projectName: model.projectName(for: deployment),
                                          calls: model.callsThisMonth[deployment.name],
                                          isSelected: deployment.name == model.selected?.name)
                            }
                        }
                    }
                }
                ForEach(filteredGroups) { group in
                    ConvexSection(group.project.name) {
                        ForEach(group.deployments) { deployment in
                            Button {
                                pick(deployment)
                            } label: {
                                PickerRow(deployment: deployment, projectName: nil, calls: model.callsThisMonth[deployment.name],
                                          isSelected: deployment.name == model.selected?.name)
                            }
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .convexScreenBackground()
            .searchable(text: $searchText, prompt: "Project or deployment")
            .navigationTitle("Choose Deployment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
            }
            .overlay {
                if model.isLoading && model.groups.isEmpty { ProgressView() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredGroups: [ChatTabModel.ProjectGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.groups }
        return model.groups.compactMap { group in
            if group.project.name.localizedStandardContains(query) { return group }
            let matches = group.deployments.filter { $0.name.localizedStandardContains(query) }
            return matches.isEmpty ? nil : ChatTabModel.ProjectGroup(project: group.project, deployments: matches)
        }
    }

    private func pick(_ deployment: Deployment) {
        model.select(deployment)
        dismiss()
    }

    private func close() {
        dismiss()
    }
}

private struct PickerRow: View {
    let deployment: Deployment
    /// Shown in the Recent section, where rows from different projects mix.
    let projectName: String?
    /// Function calls this month, once loaded.
    let calls: Double?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            DeploymentBadge(type: deployment.deploymentType)
            VStack(alignment: .leading, spacing: 1) {
                Text(projectName ?? deployment.name)
                    .font(projectName == nil ? .convexMono(.subheadline) : .subheadline.weight(.medium))
                    .foregroundStyle(Color.convexText)
                    .lineLimit(1)
                Text(lastDeployText)
                    .font(.convexMono(.caption2))
                    .foregroundStyle(Color.convexSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.convexAccent)
                .opacity(isSelected ? 1 : 0)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var lastDeployText: String {
        var parts: [String] = []
        if projectName != nil { parts.append(deployment.name) }
        if let calls {
            parts.append(calls > 0 ? "\(calls.formatted(.number.notation(.compactName))) calls this month" : "idle this month")
        }
        parts.append(deployment.lastDeployTime.map {
            "deployed " + $0.dateFromMillis.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        } ?? "never deployed")
        return parts.joined(separator: " · ")
    }
}
