import SwiftUI

struct ProjectsView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case projects = "Projects"
        case deployments = "Deployments"

        var id: String { rawValue }
    }

    @State private var mode: Mode = Self.initialMode
    /// One search field for both modes: swapping per-list `.searchable`s rebuilds the search bar
    /// and makes the navigation bar jump.
    @State private var searchText = ""
    private let session: SessionStore.Session

    init(session: SessionStore.Session) {
        self.session = session
    }

    /// Debug builds accept `-projectsMode deployments` as a launch argument, for screenshots.
    private static var initialMode: Mode {
        #if DEBUG
        UserDefaults.standard.string(forKey: "projectsMode").flatMap { Mode(rawValue: $0.capitalized) } ?? .projects
        #else
        .projects
        #endif
    }

    /// Debug builds accept `-dataURL https://<name>.convex.cloud` to open that deployment's data browser.
    @State private var debugDataURL: URL? = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "dataURL").flatMap(URL.init(string:))
        #else
        nil
        #endif
    }()

    /// Debug builds accept `-deployment <name>` to open that deployment's screen.
    @State private var debugDeployment: Deployment?
    @State private var didOpenDebugDeployment = false

    /// Switch modes instantly, like a segmented control should, instead of cross-fading two lists.
    private var modeWithoutAnimation: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newMode in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { mode = newMode }
            }
        )
    }

    private func openDebugDeployment() async {
        #if DEBUG
        // `.task` re-runs when navigating back; open it once per launch.
        guard !didOpenDebugDeployment, let name = UserDefaults.standard.string(forKey: "deployment") else { return }
        didOpenDebugDeployment = true
        debugDeployment = try? await session.client.deployment(name: name)
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .projects:
                    ProjectsList(session: session, searchText: searchText)
                case .deployments:
                    TeamDeploymentsList(session: session, searchText: searchText)
                }
            }
            .searchable(text: $searchText, prompt: mode == .projects ? "Search projects" : "Project, deployment, or person")
            // Constant title: changing it while swapping content re-lays out the navigation bar.
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: modeWithoutAnimation) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project, client: session.client)
            }
            .navigationDestination(item: $debugDataURL) { url in
                DataBrowserView(deploymentURL: url, client: session.client)
            }
            .navigationDestination(item: $debugDeployment) { deployment in
                DeploymentDetailView(deployment: deployment, client: session.client)
            }
            .task { await openDebugDeployment() }
        }
    }
}

private struct ProjectsList: View {
    @State private var viewModel: ProjectsViewModel
    let searchText: String

    init(session: SessionStore.Session, searchText: String) {
        _viewModel = State(initialValue: ProjectsViewModel(session: session))
        self.searchText = searchText
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.convexRed)
            }

            ConvexSection {
                ForEach(viewModel.filteredProjects) { project in
                    NavigationLink(value: project) {
                        ProjectRow(project: project)
                    }
                }
            } header: {
                if let teamSlug = viewModel.teamSlug {
                    Eyebrow(teamSlug)
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.projects.isEmpty {
                ProgressView()
            } else if !viewModel.isLoading && viewModel.projects.isEmpty && viewModel.errorMessage == nil {
                ContentUnavailableView("No Projects", systemImage: "folder", description: Text("This token can't see any projects."))
            } else if !viewModel.searchText.isEmpty && viewModel.filteredProjects.isEmpty {
                ContentUnavailableView.search(text: viewModel.searchText)
            }
        }
        .convexScreenBackground()
        .onChange(of: searchText, initial: true) { _, text in viewModel.searchText = text }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.convexDisplay(.headline, weight: .medium))
            HStack(spacing: 6) {
                if project.prodDeploymentName != nil {
                    DeploymentBadge(type: "prod")
                }
                if project.devDeploymentName != nil {
                    DeploymentBadge(type: "dev")
                }
                Text(project.slug)
                    .font(.caption)
                    .foregroundStyle(Color.convexSecondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}



