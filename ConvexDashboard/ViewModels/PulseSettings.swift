import Foundation
import Observation

/// Connection to the user's self-hosted monitoring backend. Optional: the app works without it,
/// but per-function stats, errors, and logs require it.
@Observable @MainActor final class PulseSettings {
    private(set) var client: PulseClient?

    init() {
        client = Self.storedClient()
    }

    /// The saved backend connection, if any. Also used by background refresh.
    static func storedClient() -> PulseClient? {
        guard let urlString = KeychainStore.load(.pulseURL),
              let url = URL(string: urlString),
              let appKey = KeychainStore.load(.pulseAppKey) else { return nil }
        return PulseClient(deploymentURL: url, appKey: appKey)
    }

    var isConfigured: Bool { client != nil }

    /// Validates the URL + key by calling the backend, then saves them.
    func connect(urlString: String, appKey rawKey: String) async throws {
        guard let url = Self.normalizedURL(urlString) else {
            throw PulseClient.PulseError.function("Enter your backend's URL, e.g. https://happy-otter-123.convex.cloud")
        }
        let appKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = PulseClient(deploymentURL: url, appKey: appKey)
        guard candidate.siteURL != nil else {
            throw PulseClient.PulseError.function("Only Convex cloud URLs (*.convex.cloud) are supported.")
        }
        _ = try await candidate.registeredStreams()

        KeychainStore.save(url.absoluteString, for: .pulseURL)
        KeychainStore.save(appKey, for: .pulseAppKey)
        WidgetRefresher.reload()
        client = candidate
    }

    func disconnect() {
        KeychainStore.delete(.pulseURL)
        KeychainStore.delete(.pulseAppKey)
        WidgetRefresher.reload()
        client = nil
    }

    /// Accepts `happy-otter-123`, `https://happy-otter-123.convex.cloud`, or the `.convex.site` URL.
    static func normalizedURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains(".") { text = "https://\(text).convex.cloud" }
        if !text.hasPrefix("http") { text = "https://\(text)" }
        text = text.replacingOccurrences(of: ".convex.site", with: ".convex.cloud")
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }
}
