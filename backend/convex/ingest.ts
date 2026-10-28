import { v } from "convex/values";
import { evaluateIngest } from "./alerts";
import { internalMutation, type MutationCtx } from "./_generated/server";
import { dailyQuotas, startOfUtcDay } from "./lib/config";
import { mergeHistograms, type StatDelta, type TotalDelta } from "./lib/events";
import { granularity, totalGranularity } from "./schema";

const deploymentUpdate = v.object({
  name: v.string(),
  deploymentType: v.optional(v.string()),
  projectName: v.optional(v.string()),
  projectSlug: v.optional(v.string()),
  lastEventAt: v.number(),
  schedulerLagSeconds: v.optional(v.number()),
  schedulerRunningJobs: v.optional(v.number()),
  schedulerStatsAt: v.optional(v.number()),
});

export const statDelta = v.object({
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
  latencyHistogram: v.array(v.number()),
  dbReadBytes: v.number(),
  dbWriteBytes: v.number(),
  docsRead: v.number(),
  docsWritten: v.number(),
  egressBytes: v.number(),
});

export const totalDelta = v.object({
  deploymentName: v.string(),
  granularity: totalGranularity,
  bucketStart: v.number(),
  calls: v.number(),
  errors: v.number(),
  cachedCalls: v.number(),
  totalMs: v.number(),
  maxMs: v.number(),
  latencyHistogram: v.array(v.number()),
});

const errorEntry = v.object({
  deploymentName: v.string(),
  timestamp: v.number(),
  path: v.string(),
  type: v.string(),
  requestId: v.string(),
  message: v.string(),
});

const logEntry = v.object({
  deploymentName: v.string(),
  timestamp: v.number(),
  level: v.string(),
  path: v.string(),
  requestId: v.string(),
  message: v.string(),
  isTruncated: v.boolean(),
});

const auditEntry = v.object({
  deploymentName: v.string(),
  timestamp: v.number(),
  action: v.string(),
  metadata: v.string(),
  summary: v.optional(v.string()),
});

/**
 * `lastEventAt` is shown as "n min ago", so it's only rewritten once it moves by a minute. Every
 * write to the deployment row can conflict with a concurrent batch for the same deployment.
 */
const LAST_EVENT_RESOLUTION_MS = 60_000;

function countByDeployment(entries: { deploymentName: string }[]) {
  const counts = new Map<string, number>();
  for (const entry of entries) counts.set(entry.deploymentName, (counts.get(entry.deploymentName) ?? 0) + 1);
  return counts;
}

/** Applies one pre-aggregated webhook batch. Called only from the /logs HTTP action. */
export const ingestBatch = internalMutation({
  args: {
    deployments: v.array(deploymentUpdate),
    stats: v.array(statDelta),
    totals: v.array(totalDelta),
    errors: v.array(errorEntry),
    logs: v.array(logEntry),
    audits: v.array(auditEntry),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const quotas = dailyQuotas();
    const today = startOfUtcDay(Date.now());
    const incomingLogs = countByDeployment(args.logs);
    const incomingErrors = countByDeployment(args.errors);
    // How many of this batch's log lines / errors each deployment may still store today.
    const logAllowance = new Map<string, number>();
    const errorAllowance = new Map<string, number>();

    for (const update of args.deployments) {
      const existing = await ctx.db
        .query("deployments")
        .withIndex("by_name", (q) => q.eq("name", update.name))
        .unique();

      const sameDay = existing?.quotaDayStart === today;
      const logsToday = sameDay ? (existing.logsToday ?? 0) : 0;
      const errorsToday = sameDay ? (existing.errorsToday ?? 0) : 0;
      const logsIn = incomingLogs.get(update.name) ?? 0;
      const errorsIn = incomingErrors.get(update.name) ?? 0;
      const logsKept = Math.min(logsIn, Math.max(0, quotas.logs - logsToday));
      const errorsKept = Math.min(errorsIn, Math.max(0, quotas.errors - errorsToday));
      logAllowance.set(update.name, logsKept);
      errorAllowance.set(update.name, errorsKept);
      const quotaFields =
        logsIn > 0 || errorsIn > 0
          ? {
              quotaDayStart: today,
              logsToday: logsToday + logsKept,
              errorsToday: errorsToday + errorsKept,
              logsDroppedToday: (sameDay ? (existing.logsDroppedToday ?? 0) : 0) + logsIn - logsKept,
              errorsDroppedToday: (sameDay ? (existing.errorsDroppedToday ?? 0) : 0) + errorsIn - errorsKept,
            }
          : {};

      if (!existing) {
        await ctx.db.insert("deployments", { ...update, ...quotaFields });
        continue;
      }
      const hasNewerSchedulerStats =
        update.schedulerStatsAt !== undefined && update.schedulerStatsAt > (existing.schedulerStatsAt ?? 0);
      // Only changed fields, and nothing at all when nothing changed.
      const patch = {
        ...(update.deploymentType !== undefined &&
          update.deploymentType !== existing.deploymentType && { deploymentType: update.deploymentType }),
        ...(update.projectName !== undefined &&
          update.projectName !== existing.projectName && { projectName: update.projectName }),
        ...(update.projectSlug !== undefined &&
          update.projectSlug !== existing.projectSlug && { projectSlug: update.projectSlug }),
        ...(update.lastEventAt - existing.lastEventAt >= LAST_EVENT_RESOLUTION_MS && {
          lastEventAt: update.lastEventAt,
        }),
        ...(hasNewerSchedulerStats && {
          schedulerLagSeconds: update.schedulerLagSeconds,
          schedulerRunningJobs: update.schedulerRunningJobs,
          schedulerStatsAt: update.schedulerStatsAt,
        }),
        ...quotaFields,
      };
      if (Object.keys(patch).length > 0) await ctx.db.patch(existing._id, patch);
    }

    await applyStats(ctx, args.stats, args.totals);

    const take = (allowance: Map<string, number>, deploymentName: string) => {
      const left = allowance.get(deploymentName) ?? 0;
      if (left <= 0) return false;
      allowance.set(deploymentName, left - 1);
      return true;
    };
    for (const error of args.errors) {
      if (take(errorAllowance, error.deploymentName)) await ctx.db.insert("errors", error);
    }
    for (const log of args.logs) {
      if (take(logAllowance, log.deploymentName)) await ctx.db.insert("logs", log);
    }
    for (const audit of args.audits) await ctx.db.insert("auditEvents", audit);

    // Alerts see every error and log line, including ones past today's storage quota.
    await evaluateIngest(ctx, args.errors, args.logs, args.audits);
    return null;
  },
});

/**
 * Adds stat deltas to functionStats / deploymentStats rows (creating missing ones). Shared by
 * log stream batches and Lite polls (lite.ts).
 */
export async function applyStats(ctx: MutationCtx, stats: StatDelta[], totals: TotalDelta[]) {
  for (const delta of stats) {
    const existing = await ctx.db
      .query("functionStats")
      .withIndex("by_key", (q) =>
        q
          .eq("deploymentName", delta.deploymentName)
          .eq("granularity", delta.granularity)
          .eq("path", delta.path)
          .eq("bucketStart", delta.bucketStart),
      )
      .unique();
    if (!existing) {
      await ctx.db.insert("functionStats", { ...delta, hasErrors: delta.errors > 0 });
      continue;
    }
    await ctx.db.patch(existing._id, {
      calls: existing.calls + delta.calls,
      errors: existing.errors + delta.errors,
      hasErrors: existing.errors + delta.errors > 0,
      cachedCalls: existing.cachedCalls + delta.cachedCalls,
      totalMs: existing.totalMs + delta.totalMs,
      maxMs: Math.max(existing.maxMs, delta.maxMs),
      latencyHistogram: mergeHistograms(existing.latencyHistogram, delta.latencyHistogram),
      dbReadBytes: existing.dbReadBytes + delta.dbReadBytes,
      dbWriteBytes: existing.dbWriteBytes + delta.dbWriteBytes,
      docsRead: existing.docsRead + delta.docsRead,
      docsWritten: existing.docsWritten + delta.docsWritten,
      egressBytes: existing.egressBytes + delta.egressBytes,
    });
  }

  for (const delta of totals) {
    const existing = await ctx.db
      .query("deploymentStats")
      .withIndex("by_deploymentName_granularity_bucketStart", (q) =>
        q
          .eq("deploymentName", delta.deploymentName)
          .eq("granularity", delta.granularity)
          .eq("bucketStart", delta.bucketStart),
      )
      .unique();
    if (!existing) {
      await ctx.db.insert("deploymentStats", delta);
      continue;
    }
    await ctx.db.patch(existing._id, {
      calls: existing.calls + delta.calls,
      errors: existing.errors + delta.errors,
      cachedCalls: existing.cachedCalls + delta.cachedCalls,
      totalMs: existing.totalMs + delta.totalMs,
      maxMs: Math.max(existing.maxMs, delta.maxMs),
      latencyHistogram: mergeHistograms(existing.latencyHistogram, delta.latencyHistogram),
    });
  }
}
