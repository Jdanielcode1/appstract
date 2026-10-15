import Foundation

// Crons, scheduled functions, and the deployment audit log ("History"), read through the same
// system queries as the dashboard's Schedules and History pages (get-convex/convex-backend
// npm-packages/system-udfs/convex/_system/frontend). Shapes come from system-udfs/convex/schema.ts.

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Int64 values arrive as numbers or strings depending on size.
    var int64: Int64? {
        switch self {
        case .number(let value): Int64(value)
        case .string(let value): Int64(value)
        default: nil
        }
    }

    var array: [JSONValue] {
        if case .array(let values) = self { return values }
        return []
    }

    /// Nanosecond timestamps (`ts`, `nextTs`) as dates.
    var nanosecondsDate: Date? {
        int64.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) }
    }

    /// Millisecond timestamps (`_creationTime`) as dates.
    var millisecondsDate: Date? {
        if case .number(let ms) = self { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }
}

/// `udfPath` is "file.js:export"; show it the way it's called, "file:export".
enum FunctionPath {
    static func display(_ udfPath: String) -> String {
        udfPath.replacingOccurrences(of: ".js:", with: ":").replacingOccurrences(of: ".js", with: "")
    }
}

// MARK: - Crons

struct CronRun: Identifiable, Sendable {
    enum Status: Sendable {
        case success
        case failed(String)
        case canceled(Int64)
    }

    let id: String
    let name: String
    let functionPath: String
    let date: Date?
    /// Seconds.
    let executionTime: Double?
    let status: Status
    let logLines: [String]

    init?(_ value: JSONValue) {
        guard let id = value["_id"]?.string, let name = value["name"]?.string else { return nil }
        self.id = id
        self.name = name
        functionPath = FunctionPath.display(value["udfPath"]?.string ?? "")
        date = value["ts"]?.nanosecondsDate
        if case .number(let seconds)? = value["executionTime"] { executionTime = seconds } else { executionTime = nil }
        switch value["status"]?["type"]?.string {
        case "err":
            let error = value["status"]?["error"]
            status = .failed(error?.string ?? error?.preview ?? "Failed")
        case "canceled":
            status = .canceled(value["status"]?["num_canceled"]?.int64 ?? 0)
        default:
            status = .success
        }
        logLines = value["logLines"]?["logLines"]?.array.compactMap(\.string) ?? []
    }

    var isFailure: Bool {
        if case .failed = status { return true }
        return false
    }

    var durationText: String? {
        executionTime.map { $0 < 1 ? "\(Int(($0 * 1000).rounded())) ms" : String(format: "%.1f s", $0) }
    }
}

struct CronJob: Identifiable, Sendable {
    let id: String
    let name: String
    let functionPath: String
    let schedule: String
    let lastRun: CronRun?
    let nextRun: Date?
    let isRunning: Bool

    init?(_ value: JSONValue) {
        guard let id = value["_id"]?.string, let name = value["name"]?.string else { return nil }
        self.id = id
        self.name = name
        functionPath = FunctionPath.display(value["cronSpec"]?["udfPath"]?.string ?? "")
        schedule = Self.describe(value["cronSpec"]?["cronSchedule"])
        lastRun = value["lastRun"].flatMap(CronRun.init)
        nextRun = value["nextRun"]?["nextTs"]?.nanosecondsDate
        isRunning = value["nextRun"]?["state"]?["type"]?.string == "inProgress"
    }

    /// "Every 15 min", "Daily at 3:00 AM" (local time), "cron 0 3 * * *".
    static func describe(_ schedule: JSONValue?) -> String {
        guard let schedule, let type = schedule["type"]?.string else { return "Unknown schedule" }
        let minute = Int(schedule["minuteUTC"]?.int64 ?? 0)
        let hour = Int(schedule["hourUTC"]?.int64 ?? 0)
        switch type {
        case "interval":
            let seconds = Int(schedule["seconds"]?.int64 ?? 0)
            if seconds % 3600 == 0 { return seconds == 3600 ? "Every hour" : "Every \(seconds / 3600) h" }
            if seconds % 60 == 0 { return seconds == 60 ? "Every minute" : "Every \(seconds / 60) min" }
            return "Every \(seconds) s"
        case "hourly":
            return "Hourly at :\(String(format: "%02d", minute))"
        case "daily":
            return "Daily at \(localTime(hour: hour, minute: minute))"
        case "weekly":
            let day = Int(schedule["dayOfWeek"]?.int64 ?? 0)
            let names = Calendar.current.weekdaySymbols
            let name = names.indices.contains(day) ? names[day] : "day \(day)"
            return "\(name)s at \(localTime(hour: hour, minute: minute))"
        case "monthly":
            return "Monthly on day \(schedule["day"]?.int64 ?? 1) at \(localTime(hour: hour, minute: minute))"
        case "cron":
            return "cron \(schedule["cronExpr"]?.string ?? "")"
        default:
            return type.capitalized
        }
    }

    /// A UTC hour/minute shown in the device's time zone.
    private static func localTime(hour: Int, minute: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Scheduled functions

struct ScheduledJob: Identifiable, Sendable {
    let id: String
    let functionPath: String
    let scheduledFor: Date?
    let isRunning: Bool
    let component: String?

    init?(_ value: JSONValue) {
        guard let id = value["_id"]?.string else { return nil }
        self.id = id
        functionPath = FunctionPath.display(value["udfPath"]?.string ?? "")
        scheduledFor = value["nextTs"]?.nanosecondsDate
        isRunning = value["state"]?["type"]?.string == "inProgress"
        component = value["component"]?.string
    }
}

// MARK: - History (deployment audit log)

struct DeploymentEvent: Identifiable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case deploys = "Deploys"
        case environment = "Env Vars"
        case data = "Data"
        case other = "Other"
        var id: String { rawValue }
    }

    struct Detail: Hashable, Sendable {
        let label: String
        let values: [String]
    }

    let id: String
    let action: String
    let date: Date
    let memberId: String?
    let source: String
    let metadata: JSONValue
    let raw: JSONValue

    init?(_ value: JSONValue) {
        guard let id = value["_id"]?.string, let action = value["action"]?.string,
              let date = value["_creationTime"]?.millisecondsDate else { return nil }
        self.id = id
        self.action = action
        self.date = date
        memberId = value["member_id"]?.string ?? value["member_id"]?.int64.map(String.init)
        metadata = value["metadata"] ?? .null
        raw = value
        let agent = value["client_user_agent"]?.string ?? ""
        source = if agent.hasPrefix("ConvexDashboard") { "this app" }
            else if agent.hasPrefix("node") || agent.contains("convex-cli") { "CLI" }
            else if agent.contains("Mozilla") { "dashboard" }
            else if agent.isEmpty { "Convex" }
            else { agent.components(separatedBy: "/").first ?? agent }
    }

    var category: Category {
        if action.hasPrefix("push_config") { return .deploys }
        if action.contains("environment_variable") { return .environment }
        if action.contains("document") || action.contains("table") || action.contains("import") { return .data }
        return .other
    }

    var systemImage: String {
        switch category {
        case .deploys: "arrow.up.circle"
        case .environment: "lock.rectangle.stack"
        case .data: "tablecells"
        default:
            if action.contains("integration") { "waveform.path.ecg" }
            else if action.contains("export") { "externaldrive" }
            else if action.contains("deployment_state") { "pause.circle" }
            else { "clock.arrow.circlepath" }
        }
    }

    var title: String {
        switch action {
        case "push_config", "push_config_with_components": "Deployed"
        case "create_environment_variable": "Added env var"
        case "update_environment_variable", "replace_environment_variable": "Changed env var"
        case "delete_environment_variable": "Removed env var"
        case "update_documents": "Edited documents"
        case "insert_documents", "add_documents": "Added documents"
        case "delete_documents": "Deleted documents"
        case "clear_tables": "Cleared table"
        case "snapshot_import": "Imported data"
        case "create_integration": "Added integration"
        case "update_integration": "Updated integration"
        case "delete_integration": "Removed integration"
        case "request_export": metadata["requestor"]?.string == "cloud_backup" ? "Backup created" : "Export requested"
        case "change_deployment_state":
            switch metadata["new_state"]?.string {
            case "paused": "Paused deployment"
            case "running": "Resumed deployment"
            default: "Changed deployment state"
            }
        default: action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// One line under the title: the deploy message and what changed, the variable, the table…
    var summary: String {
        switch category {
        case .deploys:
            let changes = deployChanges
            let counts = [
                count(changes.modulesAdded, "+", "module"), count(changes.modulesRemoved, "−", "module"),
                count(changes.indexesAdded, "+", "index"), count(changes.indexesRemoved, "−", "index"),
                count(changes.cronsAdded + changes.cronsUpdated + changes.cronsDeleted, "", "cron change"),
            ].compactMap { $0 }
            let message = metadata["message"]?.string
            let parts = [message] + [counts.isEmpty ? (message == nil ? "No function or index changes" : nil) : counts.joined(separator: " · ")]
            return parts.compactMap { $0 }.joined(separator: "\n")
        case .environment:
            return metadata["variable_name"]?.string ?? ""
        case .data:
            let table = metadata["table"]?.string ?? metadata["table_names"]?.array.compactMap(\.string).joined(separator: ", ") ?? ""
            let ids = metadata["document_ids"]?.array.count
            return [table, ids.map { "\($0) document\($0 == 1 ? "" : "s")" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        default:
            return metadata["type"]?.string ?? ""
        }
    }

    struct DeployChanges {
        var modulesAdded: [String] = []
        var modulesRemoved: [String] = []
        var indexesAdded: [String] = []
        var indexesRemoved: [String] = []
        var cronsAdded: [String] = []
        var cronsUpdated: [String] = []
        var cronsDeleted: [String] = []
        var components: [String] = []
        var versionChange: String?
    }

    /// Changes across the app and every component in a deploy.
    var deployChanges: DeployChanges {
        var changes = DeployChanges()
        let names: (JSONValue?) -> [String] = { $0?.array.compactMap { $0.string ?? $0["name"]?.string } ?? [] }
        for entry in metadata["component_diffs"]?.array ?? [] {
            let diff = entry["component_diff"]
            let prefix = entry["component_path"]?.string.map { "\($0)/" } ?? ""
            let modulesAdded = names(diff?["moduleDiff"]?["added"]).map { prefix + $0 }
            let modulesRemoved = names(diff?["moduleDiff"]?["removed"]).map { prefix + $0 }
            let indexesAdded = names(diff?["indexDiff"]?["added_indexes"]).map { prefix + $0 }
            let indexesRemoved = names(diff?["indexDiff"]?["removed_indexes"]).map { prefix + $0 }
            let cronsAdded = names(diff?["cronDiff"]?["added"]).map { prefix + $0 }
            let cronsUpdated = names(diff?["cronDiff"]?["updated"]).map { prefix + $0 }
            let cronsDeleted = names(diff?["cronDiff"]?["deleted"]).map { prefix + $0 }
            changes.modulesAdded += modulesAdded
            changes.modulesRemoved += modulesRemoved
            changes.indexesAdded += indexesAdded
            changes.indexesRemoved += indexesRemoved
            changes.cronsAdded += cronsAdded
            changes.cronsUpdated += cronsUpdated
            changes.cronsDeleted += cronsDeleted
            let changed = !(modulesAdded + modulesRemoved + indexesAdded + indexesRemoved + cronsAdded + cronsUpdated + cronsDeleted).isEmpty
            let type = diff?["diffType"]?["type"]?.string ?? "modify"
            if let path = entry["component_path"]?.string, changed || type != "modify" {
                changes.components.append(type == "modify" ? path : "\(path) (\(type))")
            }
            if let previous = diff?["udfConfigDiff"]?["previous_version"]?.string,
               let next = diff?["udfConfigDiff"]?["next_version"]?.string {
                changes.versionChange = "convex \(previous) → \(next)"
            }
        }
        return changes
    }

    /// Sections for the detail screen.
    var details: [Detail] {
        switch category {
        case .deploys:
            let changes = deployChanges
            return [
                Detail(label: "Message", values: metadata["message"]?.string.map { [$0] } ?? []),
                Detail(label: "Modules added", values: changes.modulesAdded),
                Detail(label: "Modules removed", values: changes.modulesRemoved),
                Detail(label: "Indexes added", values: changes.indexesAdded),
                Detail(label: "Indexes removed", values: changes.indexesRemoved),
                Detail(label: "Crons added", values: changes.cronsAdded),
                Detail(label: "Crons updated", values: changes.cronsUpdated),
                Detail(label: "Crons removed", values: changes.cronsDeleted),
                Detail(label: "Components changed", values: changes.components),
                Detail(label: "Convex version", values: changes.versionChange.map { [$0] } ?? []),
            ].filter { !$0.values.isEmpty }
        default:
            return metadata.children.compactMap { key, value in
                let values = value.isContainer ? value.children.map { $0.value.preview } : [value.preview]
                guard value != .null, !values.isEmpty else { return nil }
                return Detail(label: key.replacingOccurrences(of: "_", with: " ").capitalized, values: values)
            }
        }
    }

    private func count(_ items: [String], _ sign: String, _ noun: String) -> String? {
        guard !items.isEmpty else { return nil }
        let plural = noun == "index" ? "indexes" : "\(noun)s"
        return "\(sign)\(items.count) \(items.count == 1 ? noun : plural)"
    }
}
