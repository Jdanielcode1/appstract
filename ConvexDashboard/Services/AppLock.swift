import LocalAuthentication
import SwiftUI

/// Face ID gate for the whole app. On by default; locks at launch and whenever the app goes to the
/// background. Falls back to the device passcode when Face ID fails or isn't enrolled.
@Observable @MainActor final class AppLock {
    static let shared = AppLock()
    static let storageKey = "requireFaceID"

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Prompt automatically once per lock; after a cancel, wait for the Unlock button
    /// (the prompt itself toggles scene phase, so re-prompting on `.active` would loop).
    @ObservationIgnored private var shouldAutoPrompt = true
    var errorMessage: String?

    var isEnabled: Bool {
        get { access(keyPath: \.isEnabled); return UserDefaults.standard.object(forKey: Self.storageKey) as? Bool ?? true }
        set { withMutation(keyPath: \.isEnabled) { UserDefaults.standard.set(newValue, forKey: Self.storageKey) } }
    }

    private init() {
        isLocked = (UserDefaults.standard.object(forKey: Self.storageKey) as? Bool ?? true) && Self.canAuthenticate
    }

    /// "Face ID", "Touch ID", or "Passcode", for labels.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// False when the device has no passcode (e.g. a fresh simulator); locking would be permanent.
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lock() {
        guard isEnabled, Self.canAuthenticate else { return }
        isLocked = true
        shouldAutoPrompt = true
    }

    /// Called when the scene becomes active.
    func promptIfNeeded() async {
        guard isLocked, shouldAutoPrompt else { return }
        shouldAutoPrompt = false
        await unlock()
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        guard Self.canAuthenticate else { isLocked = false; return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        errorMessage = nil
        if await authenticate(reason: "Unlock Convex Go") {
            isLocked = false
        }
    }

    /// Turning the lock off requires authenticating first.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if !enabled, Self.canAuthenticate {
            guard await authenticate(reason: "Turn off \(Self.biometryName) lock") else { return }
        }
        isEnabled = enabled
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Covers the app while locked. Also hides content in the app switcher snapshot.
struct LockScreenView: View {
    var lock = AppLock.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            IconTile(systemImage: "lock.fill", tint: .convexAccent, size: 64)
            VStack(spacing: 6) {
                Text("Convex Go")
                    .font(.convexDisplay(.title2))
                    .foregroundStyle(Color.convexText)
                Text("Locked")
                    .font(.convexMono(.footnote))
                    .foregroundStyle(Color.convexSecondaryText)
            }
            Spacer()
            if let message = lock.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.convexRed)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("Unlock with \(AppLock.biometryName)", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.convexAccentFill)
            .controlSize(.large)
            .disabled(lock.isAuthenticating)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.convexBackground)
    }
}
