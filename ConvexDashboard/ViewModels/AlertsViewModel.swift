import Foundation
import Observation

@Observable @MainActor final class AlertsViewModel {
    struct DaySection: Identifiable {
        let title: String
        let events: [AlertEvent]
        var id: String { title }
    }

    var category: AlertCategory = .all { didSet { rebuildSections() } }
    /// Grouped once per change instead of on every body evaluation.
    private(set) var sections: [DaySection] = []

    private(set) var events: [AlertEvent] = [] { didSet { rebuildSections() } }
    private(set) var rules: [AlertRule] = []
    private(set) var status: AlertStatus?
    private(set) var deployments: [MonitoredDeployment] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    private(set) var isSendingTest = false
    private(set) var testMessage: String?

    /// Chips with counts; empty categories (other than All) are hidden.
    var availableCategories: [(category: AlertCategory, count: Int)] {
        AlertCategory.allCases
            .map { category in (category, category == .all ? events.count : events.filter { $0.category == category }.count) }
            .filter { $0.category == .all || $0.count > 0 }
    }

    var enabledRuleCount: Int { rules.filter(\.enabled).count }

    private func rebuildSections() {
        if category != .all && !events.contains(where: { $0.category == category }) {
            category = .all
            return // didSet on category calls rebuildSections again
        }
        let matching = category == .all ? events : events.filter { $0.category == category }
        let calendar = Calendar.current
        let now = Date.now
        func title(for date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return "This week" }
            return "Older"
        }
        var order: [String] = []
        var grouped: [String: [AlertEvent]] = [:]
        for event in matching {
            let key = title(for: event.date)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(event)
        }
        // Events arrive newest first, so first-seen order is chronological.
        sections = order.map { DaySection(title: $0, events: grouped[$0] ?? []) }
    }

    func load(pulse: PulseClient) async {
        do {
            async let events = pulse.alertEvents()
            async let rules = pulse.alertRules()
            async let status = pulse.alertStatus()
            async let deployments = pulse.monitoredDeployments()
            self.events = try await events
            self.rules = try await rules
            self.status = try await status
            self.deployments = try await deployments
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    func autoRefresh(pulse: PulseClient) async {
        while !Task.isCancelled {
            await load(pulse: pulse)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func setEnabled(_ rule: AlertRule, enabled: Bool, pulse: PulseClient) async {
        guard let id = rule.id else { return }
        await perform(pulse) { try await pulse.setAlertRule(id: id, enabled: enabled) }
    }

    func delete(_ rule: AlertRule, pulse: PulseClient) async {
        guard let id = rule.id else { return }
        await perform(pulse) { try await pulse.deleteAlertRule(id: id) }
    }

    func save(_ rule: AlertRule, pulse: PulseClient) async throws {
        try await pulse.saveAlertRule(rule)
        await load(pulse: pulse)
    }

    func addRecommendedRules(pulse: PulseClient) async {
        await perform(pulse) { try await pulse.createDefaultAlertRules() }
    }

    /// Sends a test alert, then reloads after delivery has had a moment to run.
    func sendTest(pulse: PulseClient) async {
        isSendingTest = true
        testMessage = nil
        defer { isSendingTest = false }
        do {
            try await pulse.sendTestAlert()
            try? await Task.sleep(for: .seconds(2))
            await load(pulse: pulse)
            if let latest = events.first(where: { $0.kind == "test" }) {
                if (latest.deliveredCount ?? 0) > 0 {
                    testMessage = "Pushed to \(latest.deliveredCount ?? 0) device(s)."
                } else if await LocalAlertNotifier.shared.show(latest) {
                    testMessage = "Shown as a local notification."
                } else {
                    testMessage = "Notifications aren't allowed for this app."
                }
            }
        } catch {
            testMessage = error.localizedDescription
        }
    }

    private func perform(_ pulse: PulseClient, _ action: () async throws -> Void) async {
        do {
            try await action()
            await load(pulse: pulse)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
