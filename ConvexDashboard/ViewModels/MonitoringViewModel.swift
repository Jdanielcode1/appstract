import Foundation
import Observation

/// Enables/disables log-stream monitoring for one deployment by creating a webhook log stream
/// (Deployment API) that points at the user's monitoring backend, then registering its secret there.
@Observable @MainActor final class MonitoringViewModel {
    enum Status: Equatable {
        case checking
        /// No monitoring backend configured in Settings.
        case backendNotConfigured
        /// This deployment *is* the monitoring backend; streaming it to itself would loop.
        case isMonitoringBackend
        case off
        case on
        /// Our stream exists but Convex stopped delivering (any non-2xx response marks it failed).
        case streamFailed(reason: String)
        /// A webhook stream to some other URL exists. Convex allows only one per deployment.
        case otherWebhookExists(url: String)
        case failed(String)
    }

    private(set) var status: Status = .checking
    private(set) var isWorking = false
    private(set) var actionError: String?

    @ObservationIgnored private let deployment: Deployment
    @ObservationIgnored private let client: ConvexAPIClient

    init(deployment: Deployment, client: ConvexAPIClient) {
        self.deployment = deployment
        self.client = client
    }

    private var deploymentURL: URL? { deployment.deploymentUrl.flatMap(URL.init(string:)) }

    func refresh(pulse: PulseClient?) async {
        guard let pulse else {
            status = .backendNotConfigured
            return
        }
        guard let deploymentURL, let webhookURL = pulse.webhookURL(forDeployment: deployment.name) else {
            status = .failed("This deployment has no URL.")
            return
        }
        if pulse.isSameDeployment(as: deploymentURL) {
            status = .isMonitoringBackend
            return
        }

        do {
            let webhook = try await client.logStreams(deploymentURL: deploymentURL).first(where: \.isWebhook)
            switch webhook {
            case nil:
                status = .off
            case let stream? where stream.url == webhookURL.absoluteString:
                // Self-heal: if the backend lost the registration, re-register using the secret
                // Convex returns for the existing stream.
                let registered = try await pulse.registeredStreams().contains { $0.deploymentName == deployment.name }
                if !registered, let secret = stream.hmacSecret {
                    try await pulse.registerStream(deploymentName: deployment.name, logStreamId: stream.id, hmacSecret: secret)
                }
                status = stream.isFailed ? .streamFailed(reason: stream.status?.reason ?? "Unknown reason") : .on
            case let stream?:
                status = .otherWebhookExists(url: stream.url ?? "unknown URL")
            }
        } catch is CancellationError {
            return
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func enable(pulse: PulseClient) async {
        guard let deploymentURL, let webhookURL = pulse.webhookURL(forDeployment: deployment.name) else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }

        do {
            let stream = try await client.createWebhookLogStream(deploymentURL: deploymentURL, webhookURL: webhookURL)
            do {
                try await pulse.registerStream(deploymentName: deployment.name, logStreamId: stream.id, hmacSecret: stream.hmacSecret)
            } catch {
                // Roll back so the deployment isn't left posting to a backend that rejects it.
                try? await client.deleteLogStream(deploymentURL: deploymentURL, id: stream.id)
                throw error
            }
            status = .on
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Recreates a failed stream. Convex doesn't resume a failed stream on its own. Collected data
    /// is kept; the backend registration is replaced with the new stream's secret.
    func repair(pulse: PulseClient) async {
        guard let deploymentURL, let webhookURL = pulse.webhookURL(forDeployment: deployment.name) else { return }
        isWorking = true
        actionError = nil

        do {
            for stream in try await client.logStreams(deploymentURL: deploymentURL)
                where stream.isWebhook && stream.url == webhookURL.absoluteString {
                try await client.deleteLogStream(deploymentURL: deploymentURL, id: stream.id)
            }
        } catch {
            actionError = error.localizedDescription
            isWorking = false
            return
        }
        isWorking = false
        await enable(pulse: pulse)
        if actionError != nil { status = .off }
    }

    func disable(pulse: PulseClient, deleteData: Bool) async {
        guard let deploymentURL, let webhookURL = pulse.webhookURL(forDeployment: deployment.name) else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }

        do {
            let ours = try await client.logStreams(deploymentURL: deploymentURL)
                .filter { $0.isWebhook && $0.url == webhookURL.absoluteString }
            for stream in ours {
                try await client.deleteLogStream(deploymentURL: deploymentURL, id: stream.id)
            }
            try await pulse.unregisterStream(deploymentName: deployment.name, deleteData: deleteData)
            status = .off
        } catch {
            actionError = error.localizedDescription
        }
    }
}
