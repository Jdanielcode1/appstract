import SwiftUI

/// Create or edit an alert rule. Owns its save action and dismisses itself on success.
struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AlertRule
    @State private var isSaving = false
    @State private var errorMessage: String?

    let deployments: [MonitoredDeployment]
    let onSave: (AlertRule) async throws -> Void

    init(rule: AlertRule, deployments: [MonitoredDeployment], onSave: @escaping (AlertRule) async throws -> Void) {
        _rule = State(initialValue: rule)
        self.deployments = deployments
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                ConvexSection {
                    Label(rule.kind.title, systemImage: rule.kind.systemImage)
                        .font(.convexDisplay(.headline, weight: .medium))
                } footer: {
                    Text(rule.kind.summary)
                }

                ConvexSection("Deployment") {
                    Picker("Watch", selection: $rule.deploymentName) {
                        Text("All monitored deployments").tag(String?.none)
                        ForEach(deployments) { deployment in
                            Text(deployment.label).tag(Optional(deployment.name))
                        }
                    }
                }

                conditionSection

                ConvexSection {
                    Stepper(value: $rule.cooldownMinutes, in: 0...1440, step: 5) {
                        LabeledContent("Cooldown", value: rule.cooldownMinutes == 0 ? "None" : "\(Int(rule.cooldownMinutes)) min")
                    }
                } header: {
                    Eyebrow("Noise Control")
                } footer: {
                    Text("Minimum time between alerts from this rule for the same deployment.")
                }

                if let errorMessage {
                    ConvexSection {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.convexRed)
                    }
                }
            }
            .convexScreenBackground()
            .navigationTitle(rule.id == nil ? "New Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || !isValid)
                }
            }
        }
    }

    @ViewBuilder
    private var conditionSection: some View {
        switch rule.kind {
        case .newError:
            EmptyView()
        case .errorRate:
            ConvexSection("Condition") {
                Stepper(value: binding(\.threshold, default: 0.05), in: 0.01...1, step: 0.01) {
                    LabeledContent("Error rate ≥", value: MetricFormat.percent(rule.threshold ?? 0.05))
                }
                Stepper(value: binding(\.windowMinutes, default: 5), in: 1...60) {
                    LabeledContent("Over", value: "\(Int(rule.windowMinutes ?? 5)) min")
                }
                Stepper(value: binding(\.minCalls, default: 20), in: 1...10_000, step: 10) {
                    LabeledContent("Minimum calls", value: "\(Int(rule.minCalls ?? 20))")
                }
            }
        case .schedulerLag:
            ConvexSection("Condition") {
                Stepper(value: binding(\.lagSeconds, default: 60), in: 10...3600, step: 10) {
                    LabeledContent("Behind by ≥", value: "\(Int(rule.lagSeconds ?? 60))s")
                }
            }
        case .logMatch:
            ConvexSection {
                Picker("Level", selection: $rule.level) {
                    Text("Any").tag(String?.none)
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue).tag(Optional(level.rawValue))
                    }
                }
                TextField("Message contains", text: textBinding(\.pattern))
                    .font(.convexMono(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Function contains (e.g. payments:)", text: textBinding(\.path))
                    .font(.convexMono(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Eyebrow("Match Logs")
            } footer: {
                Text("All filled-in conditions must match. Text matching ignores case.")
            }
        case .deploy:
            ConvexSection {
                Toggle("Production only", isOn: Binding(get: { rule.prodOnly ?? false }, set: { rule.prodOnly = $0 }))
            } header: {
                Eyebrow("Condition")
            } footer: {
                Text("`npx convex dev` pushes on every save, so dev deploys are usually noise. Needs the deployment's log stream (monitoring enabled).")
            }
        }
    }

    private var isValid: Bool {
        guard rule.kind == .logMatch else { return true }
        return rule.level != nil || !(rule.pattern ?? "").isEmpty || !(rule.path ?? "").isEmpty
    }

    private func binding(_ keyPath: WritableKeyPath<AlertRule, Double?>, default value: Double) -> Binding<Double> {
        Binding(get: { rule[keyPath: keyPath] ?? value }, set: { rule[keyPath: keyPath] = $0 })
    }

    private func textBinding(_ keyPath: WritableKeyPath<AlertRule, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: keyPath] ?? "" }, set: { rule[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onSave(rule)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
