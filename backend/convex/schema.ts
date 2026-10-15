import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export const granularity = v.union(v.literal("minute"), v.literal("hour"), v.literal("day"));
/** Deployment-wide totals only come in minute and hour buckets. */
export const totalGranularity = v.union(v.literal("minute"), v.literal("hour"));

export const alertKind = v.union(
  v.literal("newError"),
  v.literal("errorRate"),
  v.literal("schedulerLag"),
  v.literal("logMatch"),
  v.literal("deploy"),
);

/** Fields shared by stored rules and the `alerts:saveRule` arguments. */
export const alertRuleFields = {
  kind: alertKind,
  /** Omitted = every monitored deployment. */
  deploymentName: v.optional(v.string()),
  enabled: v.boolean(),
  /** Minimum minutes between alerts from this rule for the same deployment. */
  cooldownMinutes: v.number(),
  // errorRate
  threshold: v.optional(v.number()),
  minCalls: v.optional(v.number()),
  windowMinutes: v.optional(v.number()),
  // schedulerLag
  lagSeconds: v.optional(v.number()),
  // logMatch (all provided conditions must match)
  level: v.optional(v.string()),
  pattern: v.optional(v.string()),
  path: v.optional(v.string()),
  // deploy: skip dev deployments (`npx convex dev` pushes on every save)
  prodOnly: v.optional(v.boolean()),
};

export default defineSchema({
  /**
   * Webhook log streams registered by the iOS app. Each monitored deployment posts to
   * `/logs/<deploymentName>` and is verified with its own HMAC secret.
   */
  streams: defineTable({
    deploymentName: v.string(),
    logStreamId: v.string(),
    hmacSecret: v.string(),
    createdAt: v.number(),
  }).index("by_deployment", ["deploymentName"]),

  alertRules: defineTable({ ...alertRuleFields, createdAt: v.number() }),

  /** Fired alerts (history shown in the app). Kept 30 days. */
  alertEvents: defineTable({
    ruleId: v.optional(v.id("alertRules")),
    kind: v.union(alertKind, v.literal("test")),
    deploymentName: v.string(),
    title: v.string(),
    body: v.string(),
    path: v.optional(v.string()),
    firedAt: v.number(),
    deliveredCount: v.optional(v.number()),
    deliveryError: v.optional(v.string()),
  })
    .index("by_time", ["firedAt"])
    .index("by_rule_deployment_time", ["ruleId", "deploymentName", "firedAt"]),

  /** Every distinct error seen per function, so "new error" alerts fire only once. Kept 30 days. */
  errorSignatures: defineTable({
    deploymentName: v.string(),
    path: v.string(),
    signature: v.string(),
    sample: v.string(),
    firstSeenAt: v.number(),
    lastSeenAt: v.number(),
    count: v.number(),
  })
    .index("by_key", ["deploymentName", "path", "signature"])
    .index("by_last_seen", ["lastSeenAt"]),

  /** APNs device tokens for the owner's devices. */
  devices: defineTable({
    token: v.string(),
    /** Debug builds use the APNs sandbox. */
    sandbox: v.boolean(),
    createdAt: v.number(),
    lastSeenAt: v.number(),
  }).index("by_token", ["token"]),

  /** One row per monitored deployment, created the first time it sends an event. */
  deployments: defineTable({
    name: v.string(),
    deploymentType: v.optional(v.string()),
    projectName: v.optional(v.string()),
    projectSlug: v.optional(v.string()),
    lastEventAt: v.number(),
    schedulerLagSeconds: v.optional(v.number()),
    schedulerRunningJobs: v.optional(v.number()),
    schedulerStatsAt: v.optional(v.number()),
    /** Daily storage quota (lib/config.ts): UTC day the counters below belong to. */
    quotaDayStart: v.optional(v.number()),
    logsToday: v.optional(v.number()),
    errorsToday: v.optional(v.number()),
    /** Log lines / errors not stored today because the quota was reached (still counted in stats). */
    logsDroppedToday: v.optional(v.number()),
    errorsDroppedToday: v.optional(v.number()),
  }).index("by_name", ["name"]),

  /**
   * Deployment-wide totals per minute/hour, maintained alongside functionStats so charts and the
   * Overview read one row per bucket instead of one per function.
   */
  deploymentStats: defineTable({
    deploymentName: v.string(),
    granularity: totalGranularity,
    bucketStart: v.number(),
    calls: v.number(),
    errors: v.number(),
    cachedCalls: v.number(),
    totalMs: v.number(),
    maxMs: v.number(),
    latencyHistogram: v.array(v.number()),
  })
    .index("by_deploymentName_granularity_bucketStart", ["deploymentName", "granularity", "bucketStart"])
    .index("by_granularity_bucketStart", ["granularity", "bucketStart"]),

  /**
   * Pre-aggregated function stats. Raw function_execution events are never stored; each
   * webhook batch is folded into one row per (deployment, function, bucket). Minute rows back
   * the 1h view, hour rows 24h and per-function charts, day rows the 7d function list, so
   * queries stay well under read limits. Deployment totals live in deploymentStats.
   */
  functionStats: defineTable({
    deploymentName: v.string(),
    granularity,
    bucketStart: v.number(),
    path: v.string(),
    type: v.string(),
    calls: v.number(),
    errors: v.number(),
    cachedCalls: v.number(),
    totalMs: v.number(),
    maxMs: v.number(),
    /** Counts per latency bucket; bounds live in lib/events.ts (LATENCY_BUCKETS_MS). */
    latencyHistogram: v.array(v.number()),
    dbReadBytes: v.number(),
    dbWriteBytes: v.number(),
    docsRead: v.number(),
    docsWritten: v.number(),
    egressBytes: v.number(),
    /** errors > 0; indexed so "which functions are failing" reads only failing rows. */
    hasErrors: v.optional(v.boolean()),
  })
    .index("by_deployment_bucket", ["deploymentName", "granularity", "bucketStart"])
    .index("by_deploymentName_granularity_hasErrors_bucketStart", [
      "deploymentName",
      "granularity",
      "hasErrors",
      "bucketStart",
    ])
    .index("by_key", ["deploymentName", "granularity", "path", "bucketStart"])
    .index("by_granularity_bucket", ["granularity", "bucketStart"]),

  /** Failed function executions. Kept 7 days. */
  errors: defineTable({
    deploymentName: v.string(),
    timestamp: v.number(),
    path: v.string(),
    type: v.string(),
    requestId: v.string(),
    message: v.string(),
  })
    .index("by_deployment_time", ["deploymentName", "timestamp"])
    .index("by_deployment_path_time", ["deploymentName", "path", "timestamp"])
    .index("by_time", ["timestamp"]),

  /** console.* output. Kept 24 hours. */
  logs: defineTable({
    deploymentName: v.string(),
    timestamp: v.number(),
    level: v.string(),
    path: v.string(),
    requestId: v.string(),
    message: v.string(),
    isTruncated: v.boolean(),
  })
    .index("by_deployment_time", ["deploymentName", "timestamp"])
    .index("by_deployment_level_time", ["deploymentName", "level", "timestamp"])
    .index("by_time", ["timestamp"]),

  /** Deploys, env var changes, pauses, etc. Kept 30 days. */
  auditEvents: defineTable({
    deploymentName: v.string(),
    timestamp: v.number(),
    action: v.string(),
    metadata: v.string(),
    summary: v.optional(v.string()),
  })
    .index("by_deployment_time", ["deploymentName", "timestamp"])
    .index("by_time", ["timestamp"]),

  /** Natural-language → query requests (ai.ts), kept 30 days to review what the model wrote. */
  aiQueries: defineTable({
    question: v.string(),
    model: v.string(),
    query: v.optional(v.string()),
    explanation: v.optional(v.string()),
    /** Set when this was a "fix it" request. */
    previousQuery: v.optional(v.string()),
    previousError: v.optional(v.string()),
    /** Set when generation itself failed. */
    failure: v.optional(v.string()),
    durationMs: v.number(),
    /** USD reported by the AI Gateway. */
    cost: v.optional(v.number()),
  }),

  /** Per-deployment data catalog (catalog.ts): what tables and fields mean, for AI prompts. */
  catalogs: defineTable({
    deploymentName: v.string(),
    builtAt: v.number(),
    /** Prompt-ready text: table descriptions, field meanings, value lists, notes. */
    text: v.string(),
    tableCount: v.number(),
    notes: v.array(v.string()),
    cost: v.optional(v.number()),
  }).index("by_deployment", ["deploymentName"]),

  /** Chat about a deployment's data (chat.ts). Queries run on the phone; only messages live here. */
  chatThreads: defineTable({
    deploymentName: v.string(),
    title: v.string(),
    updatedAt: v.number(),
  })
    .index("by_deployment_updated", ["deploymentName", "updatedAt"])
    .index("by_updated", ["updatedAt"]),

  chatMessages: defineTable({
    threadId: v.id("chatThreads"),
    role: v.union(v.literal("user"), v.literal("assistant")),
    /** Anthropic Messages content blocks, JSON-encoded (text, tool_use, tool_result). */
    content: v.string(),
    cost: v.optional(v.number()),
  }).index("by_thread", ["threadId"]),
});
