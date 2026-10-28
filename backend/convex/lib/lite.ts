/**
 * Lite monitoring: instead of receiving every event through a log stream, the backend pulls each
 * deployment's per-minute metrics every few minutes from `<deploymentUrl>/api/app_metrics/*`
 * (undocumented; the endpoints behind the Convex dashboard's Health charts). Backend usage stays
 * the same whatever the monitored apps' traffic, and no log stream (Convex Pro) is needed.
 * Only counts: no latency, error messages or console logs.
 *
 * Pure helpers (no Convex runtime imports) so they can be unit tested.
 */
import { emptyStat, emptyTotal, OTHER_FUNCTIONS_PATH, type StatDelta, type TotalDelta } from "./events";

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

/** How often the cron polls (crons.ts) and how far back a first poll reaches. */
export const POLL_INTERVAL_MINUTES = 5;
/** The metrics endpoints keep about an hour. */
export const MAX_BACKFILL_MINUTES = 55;
/**
 * Minutes are only recorded once they ended at least this long ago, so late metrics are in.
 * Each minute is recorded exactly once (`polledThrough`), never corrected later.
 */
export const SETTLE_MS = MINUTE_MS;
/** The endpoints reject k > 25. Functions outside the top K are reported as `_rest`. */
export const TOP_K = 25;
export const REST_KEY = "_rest";

/** `[{secs_since_epoch, nanos_since_epoch}, value | null]` */
export type MetricBucket = [{ secs_since_epoch: number; nanos_since_epoch: number }, number | null];
/** `[[functionKey, buckets]]` */
export type TopK = [string, MetricBucket[]][];

export interface PollWindow {
  /** Inclusive, minute-aligned. */
  start: number;
  /** Exclusive, minute-aligned. */
  end: number;
  buckets: number;
}

/**
 * The minutes to fetch: from where the last poll stopped (or a backfill on the first poll) up to
 * the newest settled minute. Null when there's nothing new yet.
 */
export function pollWindow(polledThrough: number | undefined, now: number): PollWindow | null {
  const end = Math.floor((now - SETTLE_MS) / MINUTE_MS) * MINUTE_MS;
  const earliest = end - MAX_BACKFILL_MINUTES * MINUTE_MS;
  const start = Math.max(polledThrough ?? earliest, earliest);
  if (start >= end) return null;
  return { start, end, buckets: Math.round((end - start) / MINUTE_MS) };
}

/** The `window` query parameter. */
export function windowParam(window: PollWindow): string {
  const date = (ms: number) => ({ secs_since_epoch: Math.floor(ms / 1000), nanos_since_epoch: 0 });
  return JSON.stringify({ start: date(window.start), end: date(window.end), num_buckets: window.buckets });
}

/** HTTP routes are reported by URL path ("/logs/*"), functions as "alerts.js:checkThresholds". */
export function isHttpRoute(key: string): boolean {
  return key.startsWith("/") || /^[A-Z]+ \//.test(key);
}

/** `"alerts.js:checkThresholds"` → `"alerts:checkThresholds"`, the path log streams report. */
export function functionPath(key: string): string {
  if (isHttpRoute(key)) return key;
  return key.replace(/\.(js|ts|jsx|tsx|mjs|cjs)(?=:)/, "");
}

/** Function types from `_system/cli/modules:apiSpec` (`functionType` "Query" → "query"). */
export function functionTypesFromSpec(spec: unknown): Map<string, string> {
  const types = new Map<string, string>();
  if (!Array.isArray(spec)) return types;
  for (const entry of spec) {
    if (typeof entry !== "object" || entry === null) continue;
    const { identifier, functionType } = entry as { identifier?: unknown; functionType?: unknown };
    if (typeof identifier !== "string" || typeof functionType !== "string") continue;
    const type = { Query: "query", Mutation: "mutation", Action: "action", HttpAction: "http_action" }[functionType];
    if (type) types.set(functionPath(identifier), type);
  }
  return types;
}

export function typeFor(path: string, types: Map<string, string>): string {
  if (isHttpRoute(path)) return "http_action";
  return types.get(path) ?? "unknown";
}

/** Keys (as paths) the type cache doesn't know yet, so the poller fetches the function spec. */
export function unknownPaths(calls: TopK, types: Map<string, string>): string[] {
  return calls
    .map(([key]) => key)
    .filter((key) => key !== REST_KEY && !isHttpRoute(key))
    .map(functionPath)
    .filter((path) => !types.has(path));
}

export interface LiteBatch {
  stats: StatDelta[];
  totals: TotalDelta[];
  /** End of the newest minute with any calls, or null if the window was idle. */
  lastActiveAt: number | null;
  /** Newest scheduler lag reading in the window, in seconds. */
  schedulerLag: { seconds: number; at: number } | null;
}

const bucketMs = (bucket: MetricBucket) => bucket[0].secs_since_epoch * 1000 + Math.floor(bucket[0].nanos_since_epoch / 1e6);
const floorTo = (ms: number, size: number) => Math.floor(ms / size) * size;

/**
 * Turns one poll's metrics into the same stat deltas a log stream batch produces (ingest.ts
 * applies both). Errors are calls × failure %: the endpoints only report percentages. Failures of
 * functions outside the top K are attributed to "(other functions)". No latency or usage data.
 */
export function buildLiteBatch(
  deploymentName: string,
  window: PollWindow,
  calls: TopK,
  failures: TopK,
  lag: MetricBucket[],
  types: Map<string, string>,
): LiteBatch {
  // Per function key: calls per minute (by bucket start).
  const callsByKey = new Map<string, Map<number, number>>();
  const totalCalls = new Map<number, number>();
  for (const [key, buckets] of calls) {
    const perMinute = new Map<number, number>();
    for (const bucket of buckets) {
      const minute = floorTo(bucketMs(bucket), MINUTE_MS);
      const value = bucket[1] ?? 0;
      if (minute < window.start || minute >= window.end || value <= 0) continue;
      perMinute.set(minute, (perMinute.get(minute) ?? 0) + value);
      totalCalls.set(minute, (totalCalls.get(minute) ?? 0) + value);
    }
    callsByKey.set(key, perMinute);
  }

  // Per path: errors per minute.
  const errorsByPath = new Map<string, Map<number, number>>();
  const addErrors = (path: string, minute: number, errors: number) => {
    if (errors <= 0) return;
    const perMinute = errorsByPath.get(path) ?? new Map<number, number>();
    perMinute.set(minute, (perMinute.get(minute) ?? 0) + errors);
    errorsByPath.set(path, perMinute);
  };
  const failureKeys = new Set(failures.map(([key]) => key).filter((key) => key !== REST_KEY));
  for (const [key, buckets] of failures) {
    for (const bucket of buckets) {
      const minute = floorTo(bucketMs(bucket), MINUTE_MS);
      const percent = bucket[1] ?? 0;
      if (minute < window.start || minute >= window.end || percent <= 0) continue;
      if (key === REST_KEY) {
        // The rest = every function not listed in the failure top K.
        let restCalls = totalCalls.get(minute) ?? 0;
        for (const listed of failureKeys) restCalls -= callsByKey.get(listed)?.get(minute) ?? 0;
        addErrors(OTHER_FUNCTIONS_PATH, minute, Math.round((Math.max(0, restCalls) * percent) / 100));
      } else {
        const known = callsByKey.get(key)?.get(minute);
        // A failing function outside the calls top K: at least one call failed.
        const errors = known === undefined ? 1 : Math.round((known * percent) / 100);
        addErrors(known === undefined ? OTHER_FUNCTIONS_PATH : functionPath(key), minute, errors);
      }
    }
  }

  const stats = new Map<string, StatDelta>();
  const totals = new Map<string, TotalDelta>();
  const addStat = (path: string, minute: number, callCount: number, errors: number) => {
    for (const [granularity, size] of [["minute", MINUTE_MS], ["hour", HOUR_MS], ["day", DAY_MS]] as const) {
      const bucketStart = floorTo(minute, size);
      const id = `${granularity}|${path}|${bucketStart}`;
      const stat = stats.get(id) ?? emptyStat(deploymentName, granularity, bucketStart, path, typeFor(path, types));
      stat.calls += callCount;
      stat.errors += errors;
      stats.set(id, stat);
    }
    for (const [granularity, size] of [["minute", MINUTE_MS], ["hour", HOUR_MS]] as const) {
      const bucketStart = floorTo(minute, size);
      const id = `${granularity}|${bucketStart}`;
      const total = totals.get(id) ?? emptyTotal(deploymentName, granularity, bucketStart);
      total.calls += callCount;
      total.errors += errors;
      totals.set(id, total);
    }
  };

  // Calls of `_rest` and of each function, merged by path (two keys can map to one path).
  const callsByPath = new Map<string, Map<number, number>>();
  for (const [key, perMinute] of callsByKey) {
    const path = key === REST_KEY ? OTHER_FUNCTIONS_PATH : functionPath(key);
    const merged = callsByPath.get(path) ?? new Map<number, number>();
    for (const [minute, value] of perMinute) merged.set(minute, (merged.get(minute) ?? 0) + value);
    callsByPath.set(path, merged);
  }
  const paths = new Set([...callsByPath.keys(), ...errorsByPath.keys()]);
  for (const path of paths) {
    const callMinutes = callsByPath.get(path) ?? new Map<number, number>();
    const errorMinutes = errorsByPath.get(path) ?? new Map<number, number>();
    for (const minute of new Set([...callMinutes.keys(), ...errorMinutes.keys()])) {
      const errors = errorMinutes.get(minute) ?? 0;
      // Failures attributed to "(other functions)" can exceed its counted calls.
      addStat(path, minute, Math.max(callMinutes.get(minute) ?? 0, errors), errors);
    }
  }

  const activeMinutes = [...totalCalls.keys()];
  const lastActiveAt = activeMinutes.length > 0 ? Math.max(...activeMinutes) + MINUTE_MS : null;

  let schedulerLag: LiteBatch["schedulerLag"] = null;
  for (const bucket of lag) {
    const at = bucketMs(bucket);
    if (bucket[1] === null || at < window.start || at >= window.end) continue;
    if (!schedulerLag || at > schedulerLag.at) schedulerLag = { seconds: bucket[1], at };
  }

  return { stats: [...stats.values()], totals: [...totals.values()], lastActiveAt, schedulerLag };
}
