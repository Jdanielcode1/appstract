import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc } from "./_generated/dataModel";
import { internalAction, internalMutation, internalQuery, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { evaluateThresholds } from "./alerts";
import { applyStats, statDelta, totalDelta } from "./ingest";
import { assertAppKey } from "./lib/auth";
import {
  buildLiteBatch,
  functionTypesFromSpec,
  pollWindow,
  TOP_K,
  unknownPaths,
  windowParam,
  type MetricBucket,
  type PollWindow,
  type TopK,
} from "./lib/lite";

/**
 * Lite monitoring: the backend pulls each enabled deployment's metrics every few minutes (see
 * lib/lite.ts), so its usage doesn't grow with the monitored apps' traffic. The app enables it
 * per deployment and hands over its Convex access token, which the poller uses to read
 * `<deploymentUrl>/api/app_metrics/*`. A deployment that also has a log stream (Full monitoring)
 * is skipped, so its numbers aren't counted twice.
 *
 * Cost: one cron run per 5 minutes plus one poll action and one write per 5 minutes while any
 * deployment uses Lite, whatever the traffic.
 */

const TOKEN_SECRET = "convexAccessToken";
const MAX_TARGETS = 100;
/** Deployments fetched at once by one poll. */
const FETCH_CONCURRENCY = 8;
const FETCH_TIMEOUT_MS = 15_000;
/** Stat rows per `record` call, to stay well inside a mutation's read/write limits. */
const MAX_DELTAS_PER_RECORD = 4_000;
/** Cached function types per deployment. */
const MAX_FUNCTION_TYPES = 1_000;

async function getTarget(ctx: MutationCtx, deploymentName: string) {
  return ctx.db
    .query("liteTargets")
    .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
    .unique();
}

async function setSecret(ctx: MutationCtx, name: string, value: string | null) {
  const existing = await ctx.db
    .query("secrets")
    .withIndex("by_name", (q) => q.eq("name", name))
    .unique();
  if (value === null) {
    if (existing) await ctx.db.delete(existing._id);
  } else if (!existing) {
    await ctx.db.insert("secrets", { name, value, updatedAt: Date.now() });
  } else if (existing.value !== value) {
    await ctx.db.patch(existing._id, { value, updatedAt: Date.now() });
  }
}

// MARK: - Public API (iOS app)

/**
 * Turns Lite monitoring on for a deployment (or updates it) and stores the access token the
 * poller uses. Polls right away, so the last hour shows up within seconds.
 */
export const enable = mutation({
  args: {
    appKey: v.string(),
    accessToken: v.string(),
    deploymentName: v.string(),
    deploymentUrl: v.string(),
    deploymentType: v.optional(v.string()),
    projectName: v.optional(v.string()),
    projectSlug: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { appKey, accessToken, ...target }) => {
    assertAppKey(appKey);
    if (!/^https:\/\/[^/\s]+\/?$/.test(target.deploymentUrl)) {
      throw new ConvexError("The deployment URL must look like https://name.convex.cloud");
    }
    if (accessToken.trim().length === 0) throw new ConvexError("Missing access token");
    await setSecret(ctx, TOKEN_SECRET, accessToken.trim());

    const deploymentUrl = target.deploymentUrl.replace(/\/$/, "");
    const existing = await getTarget(ctx, target.deploymentName);
    if (existing) {
      await ctx.db.patch(existing._id, { ...target, deploymentUrl, lastError: undefined });
    } else {
      await ctx.db.insert("liteTargets", { ...target, deploymentUrl, createdAt: Date.now() });
    }
    await ctx.scheduler.runAfter(0, internal.lite.poll, {});
    return null;
  },
});

/** Turns Lite off for a deployment and, optionally, deletes everything collected for it. */
export const disable = mutation({
  args: { appKey: v.string(), deploymentName: v.string(), deleteData: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { appKey, deploymentName, deleteData }) => {
    assertAppKey(appKey);
    const existing = await getTarget(ctx, deploymentName);
    if (existing) await ctx.db.delete(existing._id);
    // The token is only kept while something uses it.
    if ((await ctx.db.query("liteTargets").first()) === null) await setSecret(ctx, TOKEN_SECRET, null);

    const stream = await ctx.db
      .query("streams")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
      .unique();
    if (deleteData && !stream) {
      await ctx.scheduler.runAfter(0, internal.streams.deleteDeploymentData, { deploymentName });
    }
    return null;
  },
});

/** Replaces the stored access token (e.g. after signing in with a new one). */
export const updateToken = mutation({
  args: { appKey: v.string(), accessToken: v.string() },
  returns: v.null(),
  handler: async (ctx, { appKey, accessToken }) => {
    assertAppKey(appKey);
    if ((await ctx.db.query("liteTargets").first()) === null) return null;
    await setSecret(ctx, TOKEN_SECRET, accessToken.trim());
    for (const target of await ctx.db.query("liteTargets").take(MAX_TARGETS)) {
      if (target.lastError) await ctx.db.patch(target._id, { lastError: undefined });
    }
    await ctx.scheduler.runAfter(0, internal.lite.poll, {});
    return null;
  },
});

export const list = query({
  args: { appKey: v.string() },
  returns: v.array(
    v.object({
      deploymentName: v.string(),
      createdAt: v.number(),
      lastPolledAt: v.optional(v.number()),
      lastError: v.optional(v.string()),
    }),
  ),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const targets = await ctx.db.query("liteTargets").take(MAX_TARGETS);
    return targets.map(({ deploymentName, createdAt, lastPolledAt, lastError }) => ({
      deploymentName,
      createdAt,
      lastPolledAt,
      lastError,
    }));
  },
});

// MARK: - Polling

/**
 * The `monitor` cron (crons.ts). With Lite deployments it starts a poll, which evaluates
 * error-rate / scheduler alerts once the numbers are written; otherwise it evaluates them here.
 */
export const tick = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    if ((await activeTargets(ctx)).length > 0) {
      await ctx.scheduler.runAfter(0, internal.lite.poll, {});
    } else {
      await evaluateThresholds(ctx);
    }
    return null;
  },
});

/** Lite targets without a log stream (a stream already reports their numbers). */
async function activeTargets(ctx: { db: QueryCtx["db"] }): Promise<Doc<"liteTargets">[]> {
  const targets = await ctx.db.query("liteTargets").take(MAX_TARGETS);
  if (targets.length === 0) return [];
  const streamed = new Set((await ctx.db.query("streams").take(500)).map((stream) => stream.deploymentName));
  return targets.filter((target) => !streamed.has(target.deploymentName));
}

export const pollWork = internalQuery({
  args: {},
  returns: v.object({
    token: v.union(v.string(), v.null()),
    targets: v.array(
      v.object({
        deploymentName: v.string(),
        deploymentUrl: v.string(),
        polledThrough: v.optional(v.number()),
        functionTypes: v.array(v.object({ path: v.string(), type: v.string() })),
      }),
    ),
  }),
  handler: async (ctx) => {
    const secret = await ctx.db
      .query("secrets")
      .withIndex("by_name", (q) => q.eq("name", TOKEN_SECRET))
      .unique();
    const targets = await activeTargets(ctx);
    return {
      token: secret?.value ?? null,
      targets: targets.map(({ deploymentName, deploymentUrl, polledThrough, functionTypes }) => ({
        deploymentName,
        deploymentUrl,
        polledThrough,
        functionTypes: functionTypes ?? [],
      })),
    };
  },
});

const pollResult = v.object({
  deploymentName: v.string(),
  /** The `polledThrough` this poll started from; a result for a stale value is dropped. */
  from: v.optional(v.number()),
  /** New `polledThrough`; omitted when nothing was recorded. */
  through: v.optional(v.number()),
  error: v.optional(v.string()),
  stats: v.array(statDelta),
  totals: v.array(totalDelta),
  lastActiveAt: v.optional(v.number()),
  schedulerLag: v.optional(v.object({ seconds: v.number(), at: v.number() })),
  functionTypes: v.optional(v.array(v.object({ path: v.string(), type: v.string() }))),
});
type PollResult = typeof pollResult.type;

class MetricsError extends Error {}

async function fetchJson(url: string, token: string, init?: RequestInit): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      ...init,
      headers: { Authorization: `Convex ${token}`, "Content-Type": "application/json", ...init?.headers },
      signal: controller.signal,
    });
    if (response.status === 401 || response.status === 403) {
      throw new MetricsError("Convex rejected the access token. Open Convex Go and turn monitoring on again to reconnect.");
    }
    if (response.status === 404) throw new MetricsError("Deployment not found. It may have been deleted.");
    if (!response.ok) throw new MetricsError(`Convex metrics request failed (HTTP ${response.status}).`);
    return await response.json();
  } catch (error) {
    if (error instanceof MetricsError) throw error;
    throw new MetricsError(controller.signal.aborted ? "Convex metrics request timed out." : "Couldn't reach the deployment.");
  } finally {
    clearTimeout(timeout);
  }
}

function asTopK(value: unknown): TopK {
  if (!Array.isArray(value)) throw new MetricsError("Unexpected metrics response.");
  return value as TopK;
}

async function pollTarget(
  token: string,
  target: { deploymentName: string; deploymentUrl: string; polledThrough?: number; functionTypes: { path: string; type: string }[] },
  window: PollWindow,
): Promise<PollResult> {
  const base = `${target.deploymentUrl}/api/app_metrics`;
  const params = (extra: Record<string, string> = {}) =>
    new URLSearchParams({ window: windowParam(window), ...extra }).toString();
  const [calls, failures, lag] = await Promise.all([
    fetchJson(`${base}/function_call_count_top_k?${params({ k: String(TOP_K) })}`, token).then(asTopK),
    fetchJson(`${base}/failure_percentage_top_k?${params({ k: String(TOP_K) })}`, token).then(asTopK),
    // Optional: older or self-hosted backends may not report it.
    fetchJson(`${base}/scheduled_job_lag?${params()}`, token).then(
      (value) => (Array.isArray(value) ? (value as MetricBucket[]) : []),
      () => [] as MetricBucket[],
    ),
  ]);

  const types = new Map(target.functionTypes.map(({ path, type }) => [path, type]));
  let updatedTypes: { path: string; type: string }[] | undefined;
  const missing = unknownPaths(calls, types);
  if (missing.length > 0) {
    try {
      const spec = await fetchJson(`${target.deploymentUrl}/api/query`, token, {
        method: "POST",
        body: JSON.stringify({ path: "_system/cli/modules:apiSpec", args: {}, format: "json" }),
      });
      const value = (spec as { status?: string; value?: unknown }).value;
      for (const [path, type] of functionTypesFromSpec(value)) types.set(path, type);
    } catch {
      // Types are cosmetic (the Q/M/A badge); keep going without them.
    }
    // Remember paths the spec doesn't list (components, deleted functions) so they aren't refetched.
    for (const path of missing) if (!types.has(path)) types.set(path, "unknown");
    updatedTypes = [...types].slice(-MAX_FUNCTION_TYPES).map(([path, type]) => ({ path, type }));
  }

  const batch = buildLiteBatch(target.deploymentName, window, calls, failures, lag, types);
  return {
    deploymentName: target.deploymentName,
    from: target.polledThrough,
    through: window.end,
    stats: batch.stats,
    totals: batch.totals,
    lastActiveAt: batch.lastActiveAt ?? undefined,
    schedulerLag: batch.schedulerLag ?? undefined,
    functionTypes: updatedTypes,
  };
}

/** Fetches every active Lite deployment's new minutes and records them. */
export const poll = internalAction({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const work: {
      token: string | null;
      targets: { deploymentName: string; deploymentUrl: string; polledThrough?: number; functionTypes: { path: string; type: string }[] }[];
    } = await ctx.runQuery(internal.lite.pollWork, {});
    if (work.targets.length === 0) return null;

    const now = Date.now();
    const results: PollResult[] = [];
    const queue = [...work.targets];
    const worker = async () => {
      for (let target = queue.shift(); target; target = queue.shift()) {
        const failed = (error: string): PollResult => ({
          deploymentName: target.deploymentName,
          from: target.polledThrough,
          error,
          stats: [],
          totals: [],
        });
        if (!work.token) {
          results.push(failed("No access token stored. Turn monitoring on again in Convex Go."));
          continue;
        }
        const window = pollWindow(target.polledThrough, now);
        if (!window) continue;
        try {
          results.push(await pollTarget(work.token, target, window));
        } catch (error) {
          results.push(failed(error instanceof MetricsError ? error.message : "Polling failed."));
        }
      }
    };
    await Promise.all(Array.from({ length: FETCH_CONCURRENCY }, worker));

    // Few, large writes; alerts are evaluated once, after the last one.
    const chunks: PollResult[][] = [[]];
    let size = 0;
    for (const result of results) {
      const deltas = result.stats.length + result.totals.length;
      if (size + deltas > MAX_DELTAS_PER_RECORD && chunks[chunks.length - 1].length > 0) {
        chunks.push([]);
        size = 0;
      }
      chunks[chunks.length - 1].push(result);
      size += deltas;
    }
    for (const [index, chunk] of chunks.entries()) {
      await ctx.runMutation(internal.lite.record, { results: chunk, evaluateAlerts: index === chunks.length - 1 });
    }
    return null;
  },
});

/** Writes one poll's numbers. Each minute is recorded once: results from a stale start are dropped. */
export const record = internalMutation({
  args: { results: v.array(pollResult), evaluateAlerts: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { results, evaluateAlerts }) => {
    const now = Date.now();
    for (const result of results) {
      const target = await getTarget(ctx, result.deploymentName);
      // Disabled meanwhile, or another poll already recorded these minutes.
      if (!target || target.polledThrough !== result.from) continue;
      // A log stream was added meanwhile; it reports these numbers itself.
      const stream = await ctx.db
        .query("streams")
        .withIndex("by_deployment", (q) => q.eq("deploymentName", result.deploymentName))
        .unique();
      if (stream) continue;

      if (result.error !== undefined) {
        await ctx.db.patch(target._id, { lastPolledAt: now, lastError: result.error });
        continue;
      }
      await ctx.db.patch(target._id, {
        polledThrough: result.through,
        lastPolledAt: now,
        lastError: undefined,
        ...(result.functionTypes && { functionTypes: result.functionTypes }),
      });
      await applyStats(ctx, result.stats, result.totals);
      await upsertDeployment(ctx, target, result);
    }
    if (evaluateAlerts) await evaluateThresholds(ctx);
    return null;
  },
});

/** The `deployments` row the app's lists and alerts read, as a log stream batch would update it. */
async function upsertDeployment(ctx: MutationCtx, target: Doc<"liteTargets">, result: PollResult) {
  const existing = await ctx.db
    .query("deployments")
    .withIndex("by_name", (q) => q.eq("name", target.deploymentName))
    .unique();
  const scheduler = result.schedulerLag && {
    schedulerLagSeconds: result.schedulerLag.seconds,
    schedulerStatsAt: result.schedulerLag.at,
  };
  if (!existing) {
    await ctx.db.insert("deployments", {
      name: target.deploymentName,
      deploymentType: target.deploymentType,
      projectName: target.projectName,
      projectSlug: target.projectSlug,
      lastEventAt: result.lastActiveAt ?? target.createdAt,
      ...scheduler,
    });
    return;
  }
  const patch = {
    ...(target.deploymentType !== undefined &&
      target.deploymentType !== existing.deploymentType && { deploymentType: target.deploymentType }),
    ...(target.projectName !== undefined && target.projectName !== existing.projectName && { projectName: target.projectName }),
    ...(target.projectSlug !== undefined && target.projectSlug !== existing.projectSlug && { projectSlug: target.projectSlug }),
    ...(result.lastActiveAt !== undefined && result.lastActiveAt > existing.lastEventAt && { lastEventAt: result.lastActiveAt }),
    ...(scheduler && scheduler.schedulerStatsAt > (existing.schedulerStatsAt ?? 0) && scheduler),
  };
  if (Object.keys(patch).length > 0) await ctx.db.patch(existing._id, patch);
}
