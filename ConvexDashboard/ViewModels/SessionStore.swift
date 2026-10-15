import Foundation
import Observation

/// Owns the auth state. Token handling lives here only, so OAuth can be added later as another
/// way to produce a token without touching the rest of the app.
@Observable @MainActor final class SessionStore {
    enum State {
        case loading
        case signedOut
        case signedIn(Session)
    }

    struct Session {
        let client: ConvexAPIClient
        let tokenDetails: TokenDetails
    }

    private(set) var state: State = .loading
    /// Set when a saved token couldn't be verified (e.g. offline). The token is kept for retry.
    private(set) var restoreError: String?

    var hasSavedToken: Bool { KeychainStore.load(.convexAccessToken) != nil }

    /// Validates the saved token on launch. A revoked token signs the user out.
    func restore() async {
        guard let token = KeychainStore.load(.convexAccessToken) else {
            state = .signedOut
            return
        }
        state = .loading
        do {
            try await signIn(token: token)
            restoreError = nil
        } catch APIError.unauthorized {
            signOut()
        } catch {
            restoreError = error.localizedDescription
            state = .signedOut
        }
    }

    func signIn(token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ConvexAPIClient(token: token)
        let details = try await client.tokenDetails()
        KeychainStore.save(token, for: .convexAccessToken)
        WidgetRefresher.reload()
        state = .signedIn(Session(client: client, tokenDetails: details))
    }

    func signOut() {
        KeychainStore.delete(.convexAccessToken)
        WidgetRefresher.reload()
        restoreError = nil
        state = .signedOut
    }
}
