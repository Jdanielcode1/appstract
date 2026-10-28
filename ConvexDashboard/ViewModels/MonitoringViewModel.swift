import Foundation
import Observation

/// Monitoring for one deployment. One toggle; the app picks the method:
/// - **5-minute checks** (always set up, any Convex plan): the user's backend pulls this deployment's
///   call and error counts (backend/convex/lite.ts) with the token the app hands over. Backend usage
///   doesn't grow with traffic.
/// - **Instant errors** (tried on top, needs Convex Pro): a webhook log stream sends every call,
///   error and console log to the backend as it happens. While it exists the checks pause for this
///   deployment; removing it resumes them.
@Observable @MainActor final class MonitoringViewModel {
    enum Status: Equatable {
        case checking
        /// No monitoring backend configured in Settings.
        case backendNotConfigured
        /// This deployment *is* the monitoring backend; monitoring it would loop.
        case isMonitoringBackend
        case off
        /// 5-minute checks only. `error`: why the last check failed.
        case lite(error: String?)
        /// Instant errors: log stream working.
        case on
        /// Our stream exists but Convex stopped delivering (any non-2xx response marks it failed).
        case streamFailed(reason: String)
        case failed(String)

        var isEnabled: Bool {
            switch self {
            case .lite, .on, .streamFailed: true
            default: false
            }
        }
    }

    private(set) var status: Status = .checking
    private(set) var isWorking = false
    private(set) var actionError: String?
    /// A webhook stream to some other URL. Convex allows one per deployment, so instant errors are unavailable.
    private(set) var otherWebhookURL: String?
    /// Why the last attempt to turn on instant errors failed (usually: not on Convex Pro).
    private(set) var instantErrorsUnavailable: String?

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

        // Older backends have no 5-minute checks; treat that as "checks off".
        async let liteTargets = try? pulse.liteTargets()
        let streams: Result<[LogStream], Error>
        do {
            streams = .success(try await client.logStreams(deploymentURL: deploymentURL))
        } catch is CancellationError {
            return
        } catch {
            streams = .failure(error)
        }
        let lite = (await liteTargets)?.first { $0.deploymentName == deployment.name }

        do {
            let webhook = try streams.get().first(where: \.isWebhook)
            otherWebhookURL = webhook.flatMap { $0.url == webhookURL.absoluteString ? nil : ($0.url ?? "unknown URL") }
            if let stream = webhook, stream.url == webhookURL.absoluteString {
                // Self-heal: if the backend lost the registration, re-register using the secret
                // Convex returns for the existing stream.
                let registered = try await pulse.registeredStreams().contains { $0.deploymentName == deployment.name }
                if !registered, let secret = stream.hmacSecret {
                    try await pulse.registerStream(deploymentName: deployment.name, logStreamId: stream.id, hmacSecret: secret)
                }
                status = stream.isFailed ? .streamFailed(reason: stream.status?.reason ?? "Unknown reason") : .on
                return
            }
        } catch is CancellationError {
            return
        } catch {
            // Listing streams can fail (e.g. permissions); the 5-minute checks don't need them.
            if lite == nil {
                status = .failed(error.localizedDescription)
                return
            }
        }
        status = lite.map { .lite(error: $0.lastError) } ?? .off
    }

    /// The toggle: sets up 5-minute checks, then tries instant errors. Without Convex Pro (or when
    /// another webhook stream exists) it stays on the checks.
    func enable(pulse: PulseClient) async {
        guard let deploymentURL else { return }
        isWorking = true
        actionError = nil
        instantErrorsUnavailable = nil
        defer { isWorking = false }

        var checksOn = false
        do {
            try await enableChecks(pulse: pulse, deploymentURL: deploymentURL)
            checksOn = true
        } catch {
            // Older backends have no 5-minute checks; the log stream alone still works there.
            actionError = error.localizedDescription
        }
        if otherWebhookURL == nil {
            do {
                try await addLogStream(pulse: pulse, deploymentURL: deploymentURL)
                actionError = nil
                status = .on
                return
            } catch {
                instantErrorsUnavailable = error.localizedDescription
            }
        }
        if checksOn { status = .lite(error: nil) }
    }

    /// Sends the current token again after the backend reported it rejected.
    func reconnect(pulse: PulseClient) async {
        guard let deploymentURL else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await enableChecks(pulse: pulse, deploymentURL: deploymentURL)
            status = .lite(error: nil)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Adds instant errors to a deployment that's on 5-minute checks (e.g. after upgrading to Pro).
    func addInstantErrors(pulse: PulseClient) async {
        guard let deploymentURL else { return }
        isWorking = true
        actionError = nil
        instantErrorsUnavailable = nil
        defer { isWorking = false }
        do {
            try await addLogStream(pulse: pulse, deploymentURL: deploymentURL)
            status = .on
        } catch {
            instantErrorsUnavailable = error.localizedDescription
        }
    }

    private func enableChecks(pulse: PulseClient, deploymentURL: URL) async throws {
        let project = try? await client.project(id: deployment.projectId)
        try await pulse.enableLite(deployment: deployment, deploymentURL: deploymentURL, project: project,
                                   accessToken: client.tokenForMonitoringBackend)
    }

    /// Creates the webhook log stream and registers its secret, rolling back if registering fails.
    private func addLogStream(pulse: PulseClient, deploymentURL: URL) async throws {
        guard let webhookURL = pulse.webhookURL(forDeployment: deployment.name) else { return }
        let stream = try await client.createWebhookLogStream(deploymentURL: deploymentURL, webhookURL: webhookURL)
        do {
            try await pulse.registerStream(deploymentName: deployment.name, logStreamId: stream.id, hmacSecret: stream.hmacSecret)
        } catch {
            // Roll back so the deployment isn't left posting to a backend that rejects it.
            try? await client.deleteLogStream(deploymentURL: deploymentURL, id: stream.id)
            throw error
        }
    }

    /// Recreates a failed stream. Convex doesn't resume a failed stream on its own. Collected data
    /// is kept; the backend registration is replaced with the new stream's secret.
    func repair(pulse: PulseClient) async {
        guard let deploymentURL else { return }
        isWorking = true
        actionError = nil

        do {
            try await deleteOurStreams(pulse: pulse, deploymentURL: deploymentURL)
        } catch {
            actionError = error.localizedDescription
            isWorking = false
            return
        }
        defer { isWorking = false }
        do {
            try await addLogStream(pulse: pulse, deploymentURL: deploymentURL)
            status = .on
        } catch {
            actionError = error.localizedDescription
            status = .off
        }
    }

    /// Removes the log stream and keeps the 5-minute checks, to cut backend usage on a busy deployment.
    func removeInstantErrors(pulse: PulseClient) async {
        guard let deploymentURL else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await deleteOurStreams(pulse: pulse, deploymentURL: deploymentURL)
            try await pulse.unregisterStream(deploymentName: deployment.name, deleteData: false)
            try await enableChecks(pulse: pulse, deploymentURL: deploymentURL)
            status = .lite(error: nil)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Turns everything off: the log stream (if any) and the 5-minute checks.
    func disable(pulse: PulseClient, deleteData: Bool) async {
        guard let deploymentURL else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }

        do {
            if case .lite = status {} else {
                try await deleteOurStreams(pulse: pulse, deploymentURL: deploymentURL)
            }
            try await pulse.unregisterStream(deploymentName: deployment.name, deleteData: deleteData)
            do {
                try await pulse.disableLite(deploymentName: deployment.name, deleteData: deleteData)
            } catch {
                // Older backends have no 5-minute checks; there the stream was all there was.
                if case .lite = status { throw error }
            }
            status = .off
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteOurStreams(pulse: PulseClient, deploymentURL: URL) async throws {
        guard let webhookURL = pulse.webhookURL(forDeployment: deployment.name) else { return }
        for stream in try await client.logStreams(deploymentURL: deploymentURL)
            where stream.isWebhook && stream.url == webhookURL.absoluteString {
            try await client.deleteLogStream(deploymentURL: deploymentURL, id: stream.id)
        }
    }
}
