import Foundation
import Observation

@Observable @MainActor final class ProjectsViewModel {
    private(set) var projects: [Project] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var searchText = ""

    @ObservationIgnored private let session: SessionStore.Session

    init(session: SessionStore.Session) {
        self.session = session
    }

    var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.slug.localizedCaseInsensitiveContains(searchText)
        }
    }

    var teamSlug: String? { projects.first?.teamSlug }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await session.client.projects(for: session.tokenDetails.scope)
            projects = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
