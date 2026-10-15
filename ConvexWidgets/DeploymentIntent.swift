import AppIntents
import WidgetKit

/// A deployment to show, picked when editing the widget (long-press → Edit Widget).
struct DeploymentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deployment"
    static let defaultQuery = DeploymentQuery()

    /// The deployment name, e.g. `happy-otter-123`.
    let id: String
    let projectName: String?
    let deploymentType: String

    init(_ option: WidgetDeploymentOption) {
        id = option.name
        projectName = option.projectName
        deploymentType = option.deploymentType
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(projectName ?? id)", subtitle: "\(deploymentType) · \(id)")
    }
}

struct DeploymentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DeploymentEntity] {
        let all = try await suggestedEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [DeploymentEntity] {
        guard let source = WidgetDataSource() else { throw WidgetDataError.signedOut }
        return try await source.deploymentOptions().map(DeploymentEntity.init)
    }

    /// New widgets show the busiest production deployment.
    func defaultResult() async -> DeploymentEntity? {
        guard let option = try? await WidgetDataSource()?.mostActiveOption() else { return nil }
        return DeploymentEntity(option)
    }
}

struct SelectDeploymentIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Deployment"
    static let description = IntentDescription("Choose which Convex deployment to show.")

    @Parameter(title: "Deployment")
    var deployment: DeploymentEntity?

    init() {}
}
