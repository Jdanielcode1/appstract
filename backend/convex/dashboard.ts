import { v } from "convex/values";
import { query, type QueryCtx } from "./_generated/server";
import { assertAppKey } from "./lib/auth";
import { DAY_MS, HOUR_MS, MINUTE_MS, startOfUtcDay } from "./lib/config";
import { mergeHistograms, percentileFromHistogram, HISTOGRAM_SIZE } from "./lib/events";

/**
 * Read API for the iOS app. Every query requires `appKey` (see lib/auth.ts).
 *
 * Every read is bounded. Convex rejects a query past 32,000 documents / 16 MiB, so charts and
 * totals read deploymentStats (one row per bucket), the 7d function list reads day rows, and
 * per-function reads are capped at MAX_STAT_ROWS (newest first, so a cap drops the oldest data).
 */

const MAX_STAT_ROWS = 10_000;

const statWindow = v.union(v.literal("1h"), v.literal("24h"), v.literal("7d"));
type StatWindow = "1h" | "24h" | "7d";

// Rounded to the minute so the query result is stable between re-runs within the same minute.
const currentMinute = () => Math.floor(Date.now() / MINUTE_MS) * MINUTE_MS;

/** Bucket size for charts and deployment totals. */
function chartRange(window: StatWindow) {
  const now = currentMinute();
  switch (window) {
    case "1h":
      return { granularity: "minute" as const, since: now - HOUR_MS };
    case "24h":
      return { granularity: "hour" as const, since: now - 24 * HOUR_MS };
    case "7d":
      return { granularity: "hour" as const, since: now - 7 * 24 * HOUR_MS };
  }
}

/** Bucket size for per-function totals: 7d uses day rows (today plus the 6 previous UTC days). */
function functionRange(window: StatWindow) {
  if (window !== "7d") return chartRange(window);
  return { granularity: "day" as const, since: startOfUtcDay(currentMinute()) - 6 * DAY_MS };
}

async function deploymentTotals(ctx: QueryCtx, deploymentName: string, window: StatWindow) {
  const { granularity, since } = chartRange(window);
  return ctx.db
    .query("deploymentStats")
    .withIndex("by_deploymentName_granularity_bucketStart", (q) =>
      q.eq("deploymentName", deploymentName).eq("granularity", granularity).gte("bucketStart", since),
    )
    .take(24 * 7 + 2);
}

export const deployments = query({
  args: { appKey: v.string() },
  returns: v.array(
    v.object({
      name: v.string(),
      deploymentType: v.optional(v.string()),
      projectName: v.optional(v.string()),
      projectSlug: v.optional(v.string()),
      lastEventAt: v.number(),
      schedulerLagSeconds: v.optional(v.number()),
      schedulerRunningJobs: v.optional(v.number()),
      /** Log lines / errors not stored today because the daily quota was reached. */
      logsDroppedToday: v.number(),
      errorsDroppedToday: v.number(),
      /** "lite": numbers pulled every few minutes (no latency, error messages or logs). "full": log stream. */
      mode: v.union(v.literal("lite"), v.literal("full")),
    }),
  ),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const today = startOfUtcDay(Date.now());
    const rows = await ctx.db.query("deployments").take(100);
    const streamed = new Set((await ctx.db.query("streams").take(500)).map((stream) => stream.deploymentName));
    const lite = new Set((await ctx.db.query("liteTargets").take(100)).map((target) => target.deploymentName));
    return rows
      .sort((a, b) => b.lastEventAt - a.lastEventAt)
      .map((d) => ({
        name: d.name,
        deploymentType: d.deploymentType,
        projectName: d.projectName,
        projectSlug: d.projectSlug,
        lastEventAt: d.lastEventAt,
        schedulerLagSeconds: d.schedulerLagSeconds,
        schedulerRunningJobs: d.schedulerRunningJobs,
        logsDroppedToday: d.quotaDayStart === today ? (d.logsDroppedToday ?? 0) : 0,
        errorsDroppedToday: d.quotaDayStart === today ? (d.errorsDroppedToday ?? 0) : 0,
        mode: lite.has(d.name) && !streamed.has(d.name) ? ("lite" as const) : ("full" as const),
      }));
  },
});

const functionSummaryRow = v.object({
  path: v.string(),
  type: v.string(),
  calls: v.number(),
  errors: v.number(),
  errorRate: v.number(),
  cachedCalls: v.number(),
  avgMs: v.number(),
  p95Ms: v.number(),
  maxMs: v.number(),
  dbReadBytes: v.number(),
  dbWriteBytes: v.number(),
  docsRead: v.number(),
  docsWritten: v.number(),
  egressBytes: v.number(),
});

/** Per-function totals over the window, most-called first. */
export const functionSummary = query({
  args: { appKey: v.string(), deploymentName: v.string(), window: statWindow },
  returns: v.object({
    functions: v.array(functionSummaryRow),
    totals: v.object({ calls: v.number(), errors: v.number(), errorRate: v.number() }),
  }),
  handler: async (ctx, { appKey, deploymentName, window }) => {
    assertAppKey(appKey);
    const { granularity, since } = functionRange(window);
    const rows = await ctx.db
      .query("functionStats")
      .withIndex("by_deployment_bucket", (q) =>
        q.eq("deploymentName", deploymentName).eq("granularity", granularity).gte("bucketStart", since),
      )
      .order("desc")
      .take(MAX_STAT_ROWS);

    const byPath = new Map<string, (typeof rows)[number]>();
    for (const row of rows) {
      const acc = byPath.get(row.path);
      if (!acc) {
        byPath.set(row.path, { ...row });
        continue;
      }
      acc.calls += row.calls;
      acc.errors += row.errors;
      acc.cachedCalls += row.cachedCalls;
      acc.totalMs += row.totalMs;
      acc.maxMs = Math.max(acc.maxMs, row.maxMs);
      acc.latencyHistogram = mergeHistograms(acc.latencyHistogram, row.latencyHistogram);
      acc.dbReadBytes += row.dbReadBytes;
      acc.dbWriteBytes += row.dbWriteBytes;
      acc.docsRead += row.docsRead;
      acc.docsWritten += row.docsWritten;
      acc.egressBytes += row.egressBytes;
    }

    const functions = [...byPath.values()]
      .map((s) => ({
        path: s.path,
        type: s.type,
        calls: s.calls,
        errors: s.errors,
        errorRate: s.calls > 0 ? s.errors / s.calls : 0,
        cachedCalls: s.cachedCalls,
        avgMs: s.calls > 0 ? s.totalMs / s.calls : 0,
        p95Ms: percentileFromHistogram(s.latencyHistogram, 0.95, s.maxMs),
        maxMs: s.maxMs,
        dbReadBytes: s.dbReadBytes,
        dbWriteBytes: s.dbWriteBytes,
        docsRead: s.docsRead,
        docsWritten: s.docsWritten,
        egressBytes: s.egressBytes,
      }))
      .sort((a, b) => b.calls - a.calls);

    const calls = functions.reduce((sum, f) => sum + f.calls, 0);
    const errors = functions.reduce((sum, f) => sum + f.errors, 0);
    return { functions, totals: { calls, errors, errorRate: calls > 0 ? errors / calls : 0 } };
  },
});

/** Calls/errors/p95 per bucket for charts. Optionally scoped to one function. */
export const timeseries = query({
  args: {
    appKey: v.string(),
    deploymentName: v.string(),
    window: statWindow,
    path: v.optional(v.string()),
  },
  returns: v.array(
    v.object({ bucketStart: v.number(), calls: v.number(), errors: v.number(), p95Ms: v.number() }),
  ),
  handler: async (ctx, { appKey, deploymentName, window, path }) => {
    assertAppKey(appKey);
    const { granularity, since } = chartRange(window);
    const rows =
      path === undefined
        ? await deploymentTotals(ctx, deploymentName, window)
        : await ctx.db
            .query("functionStats")
            .withIndex("by_key", (q) =>
              q
                .eq("deploymentName", deploymentName)
                .eq("granularity", granularity)
                .eq("path", path)
                .gte("bucketStart", since),
            )
            .take(24 * 7 + 2);

    const buckets = new Map<number, { calls: number; errors: number; maxMs: number; histogram: number[] }>();
    for (const row of rows) {
      const bucket = buckets.get(row.bucketStart) ?? {
        calls: 0,
        errors: 0,
        maxMs: 0,
        histogram: new Array<number>(HISTOGRAM_SIZE).fill(0),
      };
      bucket.calls += row.calls;
      bucket.errors += row.errors;
      bucket.maxMs = Math.max(bucket.maxMs, row.maxMs);
      bucket.histogram = mergeHistograms(bucket.histogram, row.latencyHistogram);
      buckets.set(row.bucketStart, bucket);
    }

    return [...buckets.entries()]
      .sort(([a], [b]) => a - b)
      .map(([bucketStart, b]) => ({
        bucketStart,
        calls: b.calls,
        errors: b.errors,
        p95Ms: percentileFromHistogram(b.histogram, 0.95, b.maxMs),
      }));
  },
});

export const recentErrors = query({
  args: {
    appKey: v.string(),
    deploymentName: v.string(),
    path: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  returns: v.array(
    v.object({
      _id: v.id("errors"),
      timestamp: v.number(),
      path: v.string(),
      type: v.string(),
      requestId: v.string(),
      message: v.string(),
    }),
  ),
  handler: async (ctx, { appKey, deploymentName, path, limit }) => {
    assertAppKey(appKey);
    const take = Math.min(limit ?? 50, 200);
    const rows =
      path === undefined
        ? await ctx.db
            .query("errors")
            .withIndex("by_deployment_time", (q) => q.eq("deploymentName", deploymentName))
            .order("desc")
            .take(take)
        : await ctx.db
            .query("errors")
            .withIndex("by_deployment_path_time", (q) => q.eq("deploymentName", deploymentName).eq("path", path))
            .order("desc")
            .take(take);
    return rows.map(({ _id, timestamp, path, type, requestId, message }) => ({
      _id,
      timestamp,
      path,
      type,
      requestId,
      message,
    }));
  },
});

export const recentLogs = query({
  args: {
    appKey: v.string(),
    deploymentName: v.string(),
    level: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  returns: v.array(
    v.object({
      _id: v.id("logs"),
      timestamp: v.number(),
      level: v.string(),
      path: v.string(),
      requestId: v.string(),
      message: v.string(),
      isTruncated: v.boolean(),
    }),
  ),
  handler: async (ctx, { appKey, deploymentName, level, limit }) => {
    assertAppKey(appKey);
    const take = Math.min(limit ?? 100, 500);
    const rows =
      level === undefined
        ? await ctx.db
            .query("logs")
            .withIndex("by_deployment_time", (q) => q.eq("deploymentName", deploymentName))
            .order("desc")
            .take(take)
        : await ctx.db
            .query("logs")
            .withIndex("by_deployment_level_time", (q) => q.eq("deploymentName", deploymentName).eq("level", level))
            .order("desc")
            .take(take);
    return rows.map(({ _id, timestamp, level, path, requestId, message, isTruncated }) => ({
      _id,
      timestamp,
      level,
      path,
      requestId,
      message,
      isTruncated,
    }));
  },
});

export const recentAuditEvents = query({
  args: { appKey: v.string(), deploymentName: v.string(), limit: v.optional(v.number()) },
  returns: v.array(
    v.object({ _id: v.id("auditEvents"), timestamp: v.number(), action: v.string(), metadata: v.string() }),
  ),
  handler: async (ctx, { appKey, deploymentName, limit }) => {
    assertAppKey(appKey);
    const rows = await ctx.db
      .query("auditEvents")
      .withIndex("by_deployment_time", (q) => q.eq("deploymentName", deploymentName))
      .order("desc")
      .take(Math.min(limit ?? 50, 200));
    return rows.map(({ _id, timestamp, action, metadata }) => ({ _id, timestamp, action, metadata }));
  },
});

/** One row per monitored deployment with 24h health, for the app's Overview screen. */
export const overview = query({
  args: { appKey: v.string() },
  returns: v.array(
    v.object({
      deploymentName: v.string(),
      projectName: v.optional(v.string()),
      deploymentType: v.optional(v.string()),
      lastEventAt: v.number(),
      calls: v.number(),
      errors: v.number(),
      errorRate: v.number(),
      p95Ms: v.number(),
      failingFunctions: v.array(v.object({ path: v.string(), errors: v.number(), calls: v.number() })),
      schedulerLagSeconds: v.optional(v.number()),
    }),
  ),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const since = currentMinute() - 24 * HOUR_MS;
    const deployments = await ctx.db.query("deployments").take(100);

    return Promise.all(
      deployments.map(async (deployment) => {
        let calls = 0;
        let errors = 0;
        let maxMs = 0;
        let histogram = new Array<number>(HISTOGRAM_SIZE).fill(0);
        for (const row of await deploymentTotals(ctx, deployment.name, "24h")) {
          calls += row.calls;
          errors += row.errors;
          maxMs = Math.max(maxMs, row.maxMs);
          histogram = mergeHistograms(histogram, row.latencyHistogram);
        }

        // Top failing functions: read only the hour rows that had errors, then the call counts
        // for the top three.
        const failingRows =
          errors === 0
            ? []
            : await ctx.db
                .query("functionStats")
                .withIndex("by_deploymentName_granularity_hasErrors_bucketStart", (q) =>
                  q
                    .eq("deploymentName", deployment.name)
                    .eq("granularity", "hour")
                    .eq("hasErrors", true)
                    .gte("bucketStart", since),
                )
                .take(2_000);
        const errorsByPath = new Map<string, number>();
        for (const row of failingRows) errorsByPath.set(row.path, (errorsByPath.get(row.path) ?? 0) + row.errors);
        const top = [...errorsByPath.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3);
        const failingFunctions = await Promise.all(
          top.map(async ([path, pathErrors]) => {
            const hours = await ctx.db
              .query("functionStats")
              .withIndex("by_key", (q) =>
                q
                  .eq("deploymentName", deployment.name)
                  .eq("granularity", "hour")
                  .eq("path", path)
                  .gte("bucketStart", since),
              )
              .take(26);
            return { path, errors: pathErrors, calls: hours.reduce((sum, row) => sum + row.calls, 0) };
          }),
        );

        return {
          deploymentName: deployment.name,
          projectName: deployment.projectName,
          deploymentType: deployment.deploymentType,
          lastEventAt: deployment.lastEventAt,
          calls,
          errors,
          errorRate: calls > 0 ? errors / calls : 0,
          p95Ms: percentileFromHistogram(histogram, 0.95, maxMs),
          failingFunctions,
          schedulerLagSeconds: deployment.schedulerLagSeconds,
        };
      }),
    );
  },
});
