import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc } from "./_generated/dataModel";
import { internalMutation, type MutationCtx } from "./_generated/server";
import { DAY_MS, HOUR_MS, retention, startOfUtcDay } from "./lib/config";
import { HISTOGRAM_SIZE, mergeHistograms } from "./lib/events";

/**
 * Rebuilds the rollups (deploymentStats, day rows in functionStats, `hasErrors`) from the hour and
 * minute functionStats rows. Ingest maintains them; run this once after upgrading from a version
 * without them, or the Overview and charts start from zero:
 *
 *   npx convex run rollups:rebuild --prod
 *
 * Safe to re-run: every target row is recomputed from its source rows, never incremented. Works
 * through one deployment-day (hours) or deployment-hour (minutes) per mutation and schedules the
 * next step, so it runs in the background.
 */

const MAX_SOURCE_ROWS = 15_000;

const step = v.object({
  deploymentName: v.string(),
  phase: v.union(v.literal("hours"), v.literal("minutes")),
  start: v.number(),
});
type Step = typeof step.type;

export const rebuild = internalMutation({
  args: { step: v.optional(step) },
  returns: v.null(),
  handler: async (ctx, args) => {
    const now = Date.now();
    const names = (await ctx.db.query("deployments").withIndex("by_name").take(100)).map((d) => d.name);
    const current = args.step ?? (names[0] ? firstStep(names[0], now) : null);
    if (!current) return null;

    if (current.phase === "hours") await rebuildDay(ctx, current.deploymentName, current.start);
    else await rebuildMinuteTotals(ctx, current.deploymentName, current.start);

    const next = nextStep(current, names, now);
    if (next) await ctx.scheduler.runAfter(0, internal.rollups.rebuild, { step: next });
    return null;
  },
});

function firstStep(deploymentName: string, now: number): Step {
  return { deploymentName, phase: "hours", start: startOfUtcDay(now - retention().stats) };
}

function nextStep(current: Step, names: string[], now: number): Step | null {
  if (current.phase === "hours") {
    if (current.start + DAY_MS <= now) return { ...current, start: current.start + DAY_MS };
    const minutesStart = Math.floor((now - retention().minuteStats) / HOUR_MS) * HOUR_MS;
    return { ...current, phase: "minutes", start: minutesStart };
  }
  if (current.start + HOUR_MS <= now) return { ...current, start: current.start + HOUR_MS };
  const nextName = names[names.indexOf(current.deploymentName) + 1];
  return nextName ? firstStep(nextName, now) : null;
}

type Totals = Pick<
  Doc<"deploymentStats">,
  "calls" | "errors" | "cachedCalls" | "totalMs" | "maxMs" | "latencyHistogram"
>;

const emptyTotals = (): Totals => ({
  calls: 0,
  errors: 0,
  cachedCalls: 0,
  totalMs: 0,
  maxMs: 0,
  latencyHistogram: new Array<number>(HISTOGRAM_SIZE).fill(0),
});

function addTotals(into: Totals, row: Totals) {
  into.calls += row.calls;
  into.errors += row.errors;
  into.cachedCalls += row.cachedCalls;
  into.totalMs += row.totalMs;
  into.maxMs = Math.max(into.maxMs, row.maxMs);
  into.latencyHistogram = mergeHistograms(into.latencyHistogram, row.latencyHistogram);
}

async function sourceRows(ctx: MutationCtx, deploymentName: string, granularity: "minute" | "hour", start: number, end: number) {
  return ctx.db
    .query("functionStats")
    .withIndex("by_deployment_bucket", (q) =>
      q.eq("deploymentName", deploymentName).eq("granularity", granularity).gte("bucketStart", start).lt("bucketStart", end),
    )
    .take(MAX_SOURCE_ROWS);
}

/** Rows written before `hasErrors` existed lack it; only rows with errors need it set. */
async function markErrors(ctx: MutationCtx, rows: Doc<"functionStats">[]) {
  for (const row of rows) {
    const hasErrors = row.errors > 0;
    if ((row.hasErrors ?? false) !== hasErrors) await ctx.db.patch(row._id, { hasErrors });
  }
}

async function setTotals(
  ctx: MutationCtx,
  deploymentName: string,
  granularity: "minute" | "hour",
  rows: Doc<"functionStats">[],
) {
  const byBucket = new Map<number, Totals>();
  for (const row of rows) {
    const totals = byBucket.get(row.bucketStart) ?? emptyTotals();
    addTotals(totals, row);
    byBucket.set(row.bucketStart, totals);
  }
  for (const [bucketStart, totals] of byBucket) {
    const existing = await ctx.db
      .query("deploymentStats")
      .withIndex("by_deploymentName_granularity_bucketStart", (q) =>
        q.eq("deploymentName", deploymentName).eq("granularity", granularity).eq("bucketStart", bucketStart),
      )
      .unique();
    if (existing) await ctx.db.patch(existing._id, totals);
    else await ctx.db.insert("deploymentStats", { deploymentName, granularity, bucketStart, ...totals });
  }
}

/** One UTC day: hour totals, per-function day rows, and `hasErrors` on the hour rows. */
async function rebuildDay(ctx: MutationCtx, deploymentName: string, dayStart: number) {
  const rows = await sourceRows(ctx, deploymentName, "hour", dayStart, dayStart + DAY_MS);
  await markErrors(ctx, rows);
  await setTotals(ctx, deploymentName, "hour", rows);

  const byPath = new Map<string, Omit<Doc<"functionStats">, "_id" | "_creationTime">>();
  for (const row of rows) {
    const day = byPath.get(row.path);
    if (!day) {
      const { _id, _creationTime, ...fields } = row;
      byPath.set(row.path, { ...fields, granularity: "day", bucketStart: dayStart });
      continue;
    }
    addTotals(day, row);
    day.dbReadBytes += row.dbReadBytes;
    day.dbWriteBytes += row.dbWriteBytes;
    day.docsRead += row.docsRead;
    day.docsWritten += row.docsWritten;
    day.egressBytes += row.egressBytes;
  }
  for (const [path, day] of byPath) {
    const fields = { ...day, hasErrors: day.errors > 0 };
    const existing = await ctx.db
      .query("functionStats")
      .withIndex("by_key", (q) =>
        q.eq("deploymentName", deploymentName).eq("granularity", "day").eq("path", path).eq("bucketStart", dayStart),
      )
      .unique();
    if (existing) await ctx.db.replace(existing._id, fields);
    else await ctx.db.insert("functionStats", fields);
  }
}

/** One hour of minute rows: minute totals and `hasErrors`. */
async function rebuildMinuteTotals(ctx: MutationCtx, deploymentName: string, hourStart: number) {
  const rows = await sourceRows(ctx, deploymentName, "minute", hourStart, hourStart + HOUR_MS);
  await markErrors(ctx, rows);
  await setTotals(ctx, deploymentName, "minute", rows);
}
