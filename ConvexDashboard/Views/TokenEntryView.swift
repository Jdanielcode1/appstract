import SwiftUI

struct TokenEntryView: View {
    @Environment(SessionStore.self) private var sessionStore
    @State private var token = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("Convex Go · Unofficial")
                        Text("Your Convex apps,\nat a glance.")
                            .font(.convexDisplay(.largeTitle))
                            .foregroundStyle(Color.convexText)
                        Text("Projects, usage, function health, and logs for your Convex team.")
                            .font(.callout)
                            .foregroundStyle(Color.convexSecondaryText)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }

                ConvexSection {
                    SecureField("Paste access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.convexMono(.body))
                } header: {
                    Eyebrow("Access Token")
                } footer: {
                    Text("Create one in the Convex dashboard under Team Settings → Access Tokens. For read-only access, create it from a team member with a view-only custom role. The token is stored in your device's Keychain.")
                }

                if let message = errorMessage ?? sessionStore.restoreError {
                    ConvexSection {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.convexRed)
                    }
                }

                Section {
                    Button(action: connectTapped) {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                                    .font(.convexMono(.body, weight: .semibold))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                ConvexSection {
                    if sessionStore.hasSavedToken {
                        Button("Retry Saved Token") {
                            Task { await sessionStore.restore() }
                        }
                    }

                    Link("Open Convex Dashboard", destination: URL(string: "https://dashboard.convex.dev")!)
                }
            }
            .convexScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func connectTapped() {
        Task { await connect() }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await sessionStore.signIn(token: token)
            token = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
