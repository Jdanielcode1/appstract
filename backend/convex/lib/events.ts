/**
 * Pure helpers for Convex log stream webhooks: signature verification, payload parsing, and
 * folding raw events into an ingest batch. No Convex runtime imports so they can be unit tested.
 * Event schema: https://docs.convex.dev/production/integrations/log-streams#log-event-schema
 */

/** Upper bounds (ms) of the latency histogram buckets. The last bucket is unbounded. */
export const LATENCY_BUCKETS_MS = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000];
export const HISTOGRAM_SIZE = LATENCY_BUCKETS_MS.length + 1;

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

/** Caps per webhook batch so one noisy burst can't blow past mutation write limits. */
export const MAX_LOGS_PER_BATCH = 500;
export const MAX_ERRORS_PER_BATCH = 200;
/**
 * Distinct function paths per deployment per batch. Beyond this, calls are folded into
 * OTHER_FUNCTIONS_PATH so a flood of unique names can't create unbounded stat rows.
 */
export const MAX_FUNCTION_PATHS_PER_BATCH = 250;
export const OTHER_FUNCTIONS_PATH = "(other functions)";
const MAX_LOG_MESSAGE_CHARS = 2_000;
const MAX_ERROR_MESSAGE_CHARS = 4_000;

// MARK: Raw event shapes (only the fields we use)

export interface RawEvent {
  topic?: string;
  timestamp?: number;
  convex?: {
    deployment_name?: string;
    deployment_type?: string;
    project_name?: string;
    project_slug?: string;
  };
  function?: { path?: string; type?: string; request_id?: string; cached?: boolean };
  // function_execution
  execution_time_ms?: number;
  status?: string;
  error_message?: string;
  usage?: {
    database_io_read_bytes?: number;
    database_io_write_bytes?: number;
    database_read_documents?: number;
    database_write_documents?: number;
    network_egress_bytes?: number;
  };
  // console
  log_level?: string;
  message?: string;
  is_truncated?: boolean;
  // scheduler_stats
  lag_seconds?: number;
  num_running_jobs?: number;
  // audit_log
  audit_log_action?: string;
  audit_log_metadata?: string;
}

// MARK: Ingest batch (what the mutation receives)

export interface DeploymentUpdate {
  name: string;
  deploymentType?: string;
  projectName?: string;
  projectSlug?: string;
  lastEventAt: number;
  schedulerLagSeconds?: number;
  schedulerRunningJobs?: number;
  schedulerStatsAt?: number;
}

export interface StatDelta {
  deploymentName: string;
  granularity: "minute" | "hour" | "day";
  bucketStart: number;
  path: string;
  type: string;
  calls: number;
  errors: number;
  cachedCalls: number;
  totalMs: number;
  maxMs: number;
  latencyHistogram: number[];
  dbReadBytes: number;
  dbWriteBytes: number;
  docsRead: number;
  docsWritten: number;
  egressBytes: number;
}

/** Deployment-wide totals for one bucket (deploymentStats). */
export interface TotalDelta {
  deploymentName: string;
  granularity: "minute" | "hour";
  bucketStart: number;
  calls: number;
  errors: number;
  cachedCalls: number;
  totalMs: number;
  maxMs: number;
  latencyHistogram: number[];
}

export interface ErrorEntry {
  deploymentName: string;
  timestamp: number;
  path: string;
  type: string;
  requestId: string;
  message: string;
}

export interface LogEntry {
  deploymentName: string;
  timestamp: number;
  level: string;
  path: string;
  requestId: string;
  message: string;
  isTruncated: boolean;
}

export interface AuditEntry {
  deploymentName: string;
  timestamp: number;
  action: string;
  metadata: string;
  /** For deploys: what changed, from the full metadata (stored metadata is truncated). */
  summary?: string;
}

export interface IngestBatch {
  deployments: DeploymentUpdate[];
  stats: StatDelta[];
  totals: TotalDelta[];
  errors: ErrorEntry[];
  logs: LogEntry[];
  audits: AuditEntry[];
}

// MARK: Signature

/**
 * Verifies `x-webhook-signature` (`sha256=<lowercase hex HMAC-SHA256 of the raw body>`) using a
 * constant-time comparison via SubtleCrypto.verify.
 */
export async function verifySignature(
  secret: string,
  body: ArrayBuffer,
  header: string | null,
): Promise<boolean> {
  if (!header) return false;
  const signature = hexToBytes(header.replace(/^sha256=/, "").trim());
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify("HMAC", key, signature, body);
}

function hexToBytes(hex: string): Uint8Array<ArrayBuffer> | null {
  if (hex.length === 0 || hex.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(hex)) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

// MARK: Parsing

/** Accepts both webhook formats: a JSON array, or JSONL (one event per line). */
export function parsePayload(text: string): RawEvent[] {
  const trimmed = text.trim();
  if (trimmed.length === 0) return [];
  if (trimmed.startsWith("[")) {
    const parsed: unknown = JSON.parse(trimmed);
    return Array.isArray(parsed) ? (parsed as RawEvent[]) : [];
  }
  return trimmed
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as RawEvent);
}

export function newestTimestamp(events: RawEvent[]): number {
  let newest = 0;
  for (const event of events) {
    if (typeof event.timestamp === "number" && event.timestamp > newest) newest = event.timestamp;
  }
  return newest;
}

// MARK: Aggregation

export function latencyBucketIndex(ms: number): number {
  const index = LATENCY_BUCKETS_MS.findIndex((bound) => ms <= bound);
  return index === -1 ? LATENCY_BUCKETS_MS.length : index;
}

/** Approximate percentile from a histogram: the upper bound of the bucket containing it. */
export function percentileFromHistogram(histogram: number[], percentile: number, maxMs: number): number {
  const total = histogram.reduce((sum, count) => sum + count, 0);
  if (total === 0) return 0;
  const target = Math.ceil(total * percentile);
  let cumulative = 0;
  for (let i = 0; i < histogram.length; i++) {
    cumulative += histogram[i];
    if (cumulative >= target) {
      return i < LATENCY_BUCKETS_MS.length ? Math.min(LATENCY_BUCKETS_MS[i], maxMs) : maxMs;
    }
  }
  return maxMs;
}

export function mergeHistograms(a: number[], b: number[]): number[] {
  return Array.from({ length: HISTOGRAM_SIZE }, (_, i) => (a[i] ?? 0) + (b[i] ?? 0));
}

const truncate = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text);

const BUCKET_SIZES = { minute: MINUTE_MS, hour: HOUR_MS, day: DAY_MS } as const;

/**
 * HTTP actions report the request path ("GET /users/k57abc…"), so IDs and tokens in the URL
 * would make every request its own "function". Drops the query string and replaces segments
 * that look like identifiers with ":id".
 */
export function normalizeFunctionPath(path: string): string {
  const match = /^([A-Z]+) (\/\S*)$/.exec(path);
  if (!match) return path;
  const [, method, url] = match;
  const segments = url
    .split("?")[0]
    .split("/")
    .map((segment) => {
      if (segment === "") return segment;
      const looksLikeId =
        /^\d+$/.test(segment) ||
        (segment.length >= 8 && /\d/.test(segment)) ||
        segment.length > 24;
      return looksLikeId ? ":id" : segment;
    });
  return `${method} ${segments.join("/")}`;
}

/** Folds raw events into deployment updates, stat deltas, and capped error/log/audit lists. */
export function buildBatch(events: RawEvent[]): IngestBatch {
  const deployments = new Map<string, DeploymentUpdate>();
  const stats = new Map<string, StatDelta>();
  const totals = new Map<string, TotalDelta>();
  const pathsByDeployment = new Map<string, Set<string>>();
  const errors: ErrorEntry[] = [];
  const logs: LogEntry[] = [];
  const audits: AuditEntry[] = [];

  for (const event of events) {
    const name = event.convex?.deployment_name;
    const timestamp = event.timestamp;
    if (!name || typeof timestamp !== "number") continue;

    const deployment = deployments.get(name) ?? { name, lastEventAt: 0 };
    deployment.deploymentType ??= event.convex?.deployment_type;
    deployment.projectName ??= event.convex?.project_name;
    deployment.projectSlug ??= event.convex?.project_slug;
    deployment.lastEventAt = Math.max(deployment.lastEventAt, timestamp);
    deployments.set(name, deployment);

    switch (event.topic) {
      case "function_execution": {
        const reportedPath = normalizeFunctionPath(event.function?.path ?? "unknown");
        const type = event.function?.type ?? "unknown";
        const failed = event.status === "failure";
        const ms = event.execution_time_ms ?? 0;

        const seenPaths = pathsByDeployment.get(name) ?? new Set<string>();
        pathsByDeployment.set(name, seenPaths);
        let path = reportedPath;
        if (!seenPaths.has(path)) {
          if (seenPaths.size >= MAX_FUNCTION_PATHS_PER_BATCH) path = OTHER_FUNCTIONS_PATH;
          seenPaths.add(path);
        }

        for (const granularity of ["minute", "hour"] as const) {
          const bucketStart = Math.floor(timestamp / BUCKET_SIZES[granularity]) * BUCKET_SIZES[granularity];
          const key = `${name}|${granularity}|${bucketStart}`;
          const total = totals.get(key) ?? emptyTotal(name, granularity, bucketStart);
          total.calls += 1;
          total.errors += failed ? 1 : 0;
          total.cachedCalls += event.function?.cached ? 1 : 0;
          total.totalMs += ms;
          total.maxMs = Math.max(total.maxMs, ms);
          total.latencyHistogram[latencyBucketIndex(ms)] += 1;
          totals.set(key, total);
        }

        for (const granularity of ["minute", "hour", "day"] as const) {
          const bucketStart = Math.floor(timestamp / BUCKET_SIZES[granularity]) * BUCKET_SIZES[granularity];
          const key = `${name}|${granularity}|${path}|${bucketStart}`;
          const stat = stats.get(key) ?? emptyStat(name, granularity, bucketStart, path, type);
          stat.calls += 1;
          stat.errors += failed ? 1 : 0;
          stat.cachedCalls += event.function?.cached ? 1 : 0;
          stat.totalMs += ms;
          stat.maxMs = Math.max(stat.maxMs, ms);
          stat.latencyHistogram[latencyBucketIndex(ms)] += 1;
          stat.dbReadBytes += event.usage?.database_io_read_bytes ?? 0;
          stat.dbWriteBytes += event.usage?.database_io_write_bytes ?? 0;
          stat.docsRead += event.usage?.database_read_documents ?? 0;
          stat.docsWritten += event.usage?.database_write_documents ?? 0;
          stat.egressBytes += event.usage?.network_egress_bytes ?? 0;
          stats.set(key, stat);
        }

        if (failed && errors.length < MAX_ERRORS_PER_BATCH) {
          errors.push({
            deploymentName: name,
            timestamp,
            path: reportedPath,
            type,
            requestId: event.function?.request_id ?? "",
            message: truncate(event.error_message ?? "Unknown error", MAX_ERROR_MESSAGE_CHARS),
          });
        }
        break;
      }

      case "console": {
        if (logs.length < MAX_LOGS_PER_BATCH) {
          logs.push({
            deploymentName: name,
            timestamp,
            level: event.log_level ?? "LOG",
            path: event.function?.path ?? "",
            requestId: event.function?.request_id ?? "",
            message: truncate(event.message ?? "", MAX_LOG_MESSAGE_CHARS),
            isTruncated: (event.is_truncated ?? false) || (event.message?.length ?? 0) > MAX_LOG_MESSAGE_CHARS,
          });
        }
        break;
      }

      case "scheduler_stats": {
        if (timestamp >= (deployment.schedulerStatsAt ?? 0)) {
          deployment.schedulerLagSeconds = event.lag_seconds;
          deployment.schedulerRunningJobs = event.num_running_jobs;
          deployment.schedulerStatsAt = timestamp;
        }
        break;
      }

      case "audit_log": {
        audits.push({
          deploymentName: name,
          timestamp,
          action: event.audit_log_action ?? "unknown",
          metadata: truncate(event.audit_log_metadata ?? "", MAX_ERROR_MESSAGE_CHARS),
          ...(isDeployAction(event.audit_log_action) && { summary: deploySummary(event.audit_log_metadata ?? "") }),
        });
        break;
      }
    }
  }

  return {
    deployments: [...deployments.values()],
    stats: [...stats.values()],
    totals: [...totals.values()],
    errors,
    logs,
    audits,
  };
}

/** `push_config` (older) and `push_config_with_components`: a `npx convex deploy` or `dev` push. */
export function isDeployAction(action: string | undefined): boolean {
  return action?.startsWith("push_config") ?? false;
}

interface ComponentDiff {
  moduleDiff?: { added?: unknown[]; removed?: unknown[] };
  indexDiff?: { added_indexes?: unknown[]; removed_indexes?: unknown[] };
  cronDiff?: { added?: unknown[]; deleted?: unknown[]; updated?: unknown[] };
  schemaDiff?: unknown;
}

/**
 * One line describing a deploy, e.g. "\"fix signup\" · 2 files added · 1 index added · schema changed".
 * Pushes that only change code carry no diff, so they read "Functions updated".
 */
export function deploySummary(metadata: string): string {
  let parsed: { message?: string | null; component_diffs?: { component_diff?: ComponentDiff }[] };
  try {
    parsed = JSON.parse(metadata);
  } catch {
    return "Functions updated";
  }
  const count = (list: unknown[] | undefined) => list?.length ?? 0;
  const plural = (n: number, noun: string, verb: string) => `${n} ${noun}${n === 1 ? "" : noun.endsWith("x") ? "es" : "s"} ${verb}`;
  let filesAdded = 0, filesRemoved = 0, indexesAdded = 0, indexesRemoved = 0, crons = 0;
  let schemaChanged = false;
  for (const { component_diff: diff } of parsed.component_diffs ?? []) {
    if (!diff) continue;
    filesAdded += count(diff.moduleDiff?.added);
    filesRemoved += count(diff.moduleDiff?.removed);
    indexesAdded += count(diff.indexDiff?.added_indexes);
    indexesRemoved += count(diff.indexDiff?.removed_indexes);
    crons += count(diff.cronDiff?.added) + count(diff.cronDiff?.deleted) + count(diff.cronDiff?.updated);
    schemaChanged ||= diff.schemaDiff !== null && diff.schemaDiff !== undefined;
  }
  const parts: string[] = [];
  if (parsed.message) parts.push(`"${truncate(parsed.message, 80)}"`);
  if (filesAdded) parts.push(plural(filesAdded, "file", "added"));
  if (filesRemoved) parts.push(plural(filesRemoved, "file", "removed"));
  if (indexesAdded) parts.push(plural(indexesAdded, "index", "added"));
  if (indexesRemoved) parts.push(plural(indexesRemoved, "index", "removed"));
  if (crons) parts.push(plural(crons, "cron", "changed"));
  if (schemaChanged) parts.push("schema changed");
  return parts.length ? parts.join(" · ") : "Functions updated";
}

export function emptyTotal(deploymentName: string, granularity: "minute" | "hour", bucketStart: number): TotalDelta {
  return {
    deploymentName,
    granularity,
    bucketStart,
    calls: 0,
    errors: 0,
    cachedCalls: 0,
    totalMs: 0,
    maxMs: 0,
    latencyHistogram: new Array<number>(HISTOGRAM_SIZE).fill(0),
  };
}

export function emptyStat(
  deploymentName: string,
  granularity: "minute" | "hour" | "day",
  bucketStart: number,
  path: string,
  type: string,
): StatDelta {
  return {
    deploymentName,
    granularity,
    bucketStart,
    path,
    type,
    calls: 0,
    errors: 0,
    cachedCalls: 0,
    totalMs: 0,
    maxMs: 0,
    latencyHistogram: new Array<number>(HISTOGRAM_SIZE).fill(0),
    dbReadBytes: 0,
    dbWriteBytes: 0,
    docsRead: 0,
    docsWritten: 0,
    egressBytes: 0,
  };
}
