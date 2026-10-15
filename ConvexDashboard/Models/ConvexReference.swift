import Foundation

// Explanations shown behind the ⓘ buttons. Sourced from Convex docs:
// - Usage metrics: https://docs.convex.dev/production/usage-limits#available-metrics
// - Deployment classes: https://docs.convex.dev/production/state/limits#deployment-classes

struct MetricInfo: Sendable {
    let title: String
    let explanation: String
    let unit: String
    var note: String?
}

enum ConvexReference {
    static let usageWindowsNote = "\"Today\" resets at midnight UTC; \"Month\" resets on the 1st at midnight UTC."
    static let usageDocsURL = URL(string: "https://docs.convex.dev/production/usage-limits#available-metrics")!
    static let classesDocsURL = URL(string: "https://docs.convex.dev/production/state/limits")!

    /// Keyed by the metric names returned by `get_current_usage` / usage limits.
    static let metrics: [String: MetricInfo] = [
        "functionCalls": MetricInfo(
            title: "Function Calls",
            explanation: "Every query, mutation, action, HTTP action, and file storage call.",
            unit: "calls",
            note: "Reactive queries count each time they re-run because data they read changed."
        ),
        "databaseIoGb": MetricInfo(
            title: "Database I/O",
            explanation: "Bandwidth used reading from and writing to the database.",
            unit: "GB",
            note: "Reading many or large documents adds up fast. Indexes keep reads small."
        ),
        "dataEgressGb": MetricInfo(
            title: "Data Egress",
            explanation: "Bandwidth used serving file downloads, outgoing fetch requests from actions, and log stream egress.",
            unit: "GB"
        ),
        "searchQueryGb": MetricInfo(
            title: "Search Queries",
            explanation: "Bandwidth used serving text and vector search queries.",
            unit: "query-GB"
        ),
        "queryMutationComputeGbHours": MetricInfo(
            title: "Query & Mutation Compute",
            explanation: "Compute consumed running queries and mutations.",
            unit: "GB-hours",
            note: "Only billed for deployments on dedicated hardware (Business & Enterprise)."
        ),
        "actionComputeConvexGbHours": MetricInfo(
            title: "Action Compute (Convex)",
            explanation: "Compute consumed running actions in the default Convex runtime.",
            unit: "GB-hours",
            note: "GB-hours = memory allocated × time running."
        ),
        "actionComputeNodeJsGbHours": MetricInfo(
            title: "Action Compute (Node.js)",
            explanation: "Compute consumed running actions in the Node.js runtime (files with \"use node\").",
            unit: "GB-hours",
            note: "GB-hours = memory allocated × time running."
        ),
        "actionComputeCpuGbHours": MetricInfo(
            title: "Action Compute (CPU)",
            explanation: "CPU time consumed running actions.",
            unit: "GB-hours",
            note: "Replaces Action Compute (Convex) on Business & Enterprise plans."
        ),
        "aiGatewayCostDollars": MetricInfo(
            title: "AI Gateway",
            explanation: "Cost of model requests made through the Convex AI Gateway.",
            unit: "USD"
        ),
    ]

    struct DeploymentClass: Identifiable, Sendable {
        let id: String
        let kind: String
        let plans: String
        let concurrentQueries: String
        let concurrentMutations: String
        let concurrentActions: String
        let nodeActions: String
        let scheduledJobs: String
        let sessions: String
        let queryCache: String
        let maxDataset: String
        let backups: String
        let writeThroughput: String
    }

    static let classSummary = "S = serverless (shared infrastructure), D = dedicated (exclusive database hardware). The number is how many queries can run at the same time; other limits scale with it."

    static let deploymentClasses: [DeploymentClass] = [
        DeploymentClass(id: "s16", kind: "Serverless", plans: "Free, Starter",
                        concurrentQueries: "16", concurrentMutations: "16", concurrentActions: "64", nodeActions: "64",
                        scheduledJobs: "8", sessions: "1,000", queryCache: "1 GB shared", maxDataset: "1 TB",
                        backups: "Logical", writeThroughput: "4 MiB"),
        DeploymentClass(id: "s256", kind: "Serverless", plans: "Professional",
                        concurrentQueries: "256", concurrentMutations: "256", concurrentActions: "512", nodeActions: "256",
                        scheduledJobs: "256", sessions: "10,000", queryCache: "1 GB shared", maxDataset: "1 TB",
                        backups: "Logical", writeThroughput: "8 MiB"),
        DeploymentClass(id: "d1024", kind: "Dedicated", plans: "Business, Enterprise",
                        concurrentQueries: "1,024", concurrentMutations: "512", concurrentActions: "1,024", nodeActions: "1,024",
                        scheduledJobs: "512", sessions: "100,000", queryCache: "2 GB dedicated", maxDataset: "4 TB",
                        backups: "High-speed physical", writeThroughput: "32 MiB"),
        DeploymentClass(id: "d2048", kind: "Dedicated", plans: "Business, Enterprise",
                        concurrentQueries: "2,048", concurrentMutations: "1,024", concurrentActions: "2,048", nodeActions: "2,048",
                        scheduledJobs: "1,024", sessions: "200,000", queryCache: "4 GB dedicated", maxDataset: "8 TB",
                        backups: "High-speed physical", writeThroughput: "64 MiB"),
    ]
}
