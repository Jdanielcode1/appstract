import { describe, expect, it } from "vitest";
import {
  buildBatch,
  deploySummary,
  latencyBucketIndex,
  normalizeFunctionPath,
  parsePayload,
  percentileFromHistogram,
  verifySignature,
  HISTOGRAM_SIZE,
  MAX_FUNCTION_PATHS_PER_BATCH,
  OTHER_FUNCTIONS_PATH,
  type RawEvent,
} from "../convex/lib/events";

const convex = {
  deployment_name: "happy-otter-123",
  deployment_type: "prod",
  project_name: "Demo",
  project_slug: "demo",
};

async function sign(secret: string, body: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return "sha256=" + [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const toBuffer = (s: string) => new TextEncoder().encode(s).buffer as ArrayBuffer;

describe("verifySignature", () => {
  it("accepts a valid signature and rejects tampering", async () => {
    const body = JSON.stringify([{ topic: "verification", timestamp: 1 }]);
    const header = await sign("s3cret", body);
    expect(await verifySignature("s3cret", toBuffer(body), header)).toBe(true);
    expect(await verifySignature("wrong", toBuffer(body), header)).toBe(false);
    expect(await verifySignature("s3cret", toBuffer(body + " "), header)).toBe(false);
    expect(await verifySignature("s3cret", toBuffer(body), null)).toBe(false);
    expect(await verifySignature("s3cret", toBuffer(body), "sha256=zz")).toBe(false);
  });
});

describe("parsePayload", () => {
  it("parses JSON arrays and JSONL", () => {
    expect(parsePayload('[{"topic":"a"},{"topic":"b"}]')).toHaveLength(2);
    expect(parsePayload('{"topic":"a"}\n{"topic":"b"}\n')).toHaveLength(2);
    expect(parsePayload("  ")).toEqual([]);
  });
});

describe("latency histogram", () => {
  it("buckets and estimates p95", () => {
    expect(latencyBucketIndex(5)).toBe(0);
    expect(latencyBucketIndex(10)).toBe(0);
    expect(latencyBucketIndex(11)).toBe(1);
    expect(latencyBucketIndex(999_999)).toBe(HISTOGRAM_SIZE - 1);

    const histogram = new Array(HISTOGRAM_SIZE).fill(0);
    histogram[0] = 95; // <=10ms
    histogram[5] = 5; // <=500ms
    expect(percentileFromHistogram(histogram, 0.95, 400)).toBe(10);
    expect(percentileFromHistogram(histogram, 0.99, 400)).toBe(400); // capped at observed max
    expect(percentileFromHistogram(new Array(HISTOGRAM_SIZE).fill(0), 0.95, 0)).toBe(0);
  });
});

describe("buildBatch", () => {
  const minute = Date.UTC(2026, 9, 5, 12, 30);

  const events: RawEvent[] = [
    {
      topic: "function_execution",
      timestamp: minute + 1_000,
      convex,
      function: { path: "goals:list", type: "query", request_id: "r1", cached: true },
      execution_time_ms: 8,
      status: "success",
      usage: { database_io_read_bytes: 100, database_read_documents: 2 },
    },
    {
      topic: "function_execution",
      timestamp: minute + 2_000,
      convex,
      function: { path: "goals:list", type: "query", request_id: "r2" },
      execution_time_ms: 300,
      status: "failure",
      error_message: "Uncaught Error: boom",
    },
    {
      topic: "console",
      timestamp: minute + 3_000,
      convex,
      function: { path: "goals:create", type: "mutation", request_id: "r3" },
      log_level: "WARN",
      message: "'careful'",
      is_truncated: false,
    },
    { topic: "scheduler_stats", timestamp: minute + 4_000, convex, lag_seconds: 2, num_running_jobs: 3 },
    { topic: "audit_log", timestamp: minute + 5_000, convex, audit_log_action: "push_config", audit_log_metadata: "{}" },
    { topic: "verification", timestamp: minute, message: "hi" }, // no convex metadata: ignored
  ];

  it("aggregates function executions into minute, hour, and day buckets", () => {
    const batch = buildBatch(events);
    expect(batch.stats).toHaveLength(3);
    const minuteStat = batch.stats.find((s) => s.granularity === "minute")!;
    expect(minuteStat).toMatchObject({
      deploymentName: "happy-otter-123",
      bucketStart: minute,
      path: "goals:list",
      calls: 2,
      errors: 1,
      cachedCalls: 1,
      totalMs: 308,
      maxMs: 300,
      dbReadBytes: 100,
      docsRead: 2,
    });
    expect(minuteStat.latencyHistogram[0]).toBe(1);
    expect(minuteStat.latencyHistogram[latencyBucketIndex(300)]).toBe(1);
    expect(batch.stats.find((s) => s.granularity === "hour")!.bucketStart).toBe(Date.UTC(2026, 9, 5, 12));
    expect(batch.stats.find((s) => s.granularity === "day")!.bucketStart).toBe(Date.UTC(2026, 9, 5));
  });

  it("adds deployment-wide minute and hour totals", () => {
    const twoFunctions: RawEvent[] = [
      ...events,
      {
        topic: "function_execution",
        timestamp: minute + 6_000,
        convex,
        function: { path: "goals:create", type: "mutation", request_id: "r4" },
        execution_time_ms: 20,
        status: "success",
      },
    ];
    const batch = buildBatch(twoFunctions);
    expect(batch.totals).toHaveLength(2);
    expect(batch.totals.find((t) => t.granularity === "minute")).toMatchObject({
      deploymentName: "happy-otter-123",
      bucketStart: minute,
      calls: 3,
      errors: 1,
      totalMs: 328,
      maxMs: 300,
    });
    expect(batch.totals.find((t) => t.granularity === "hour")!.bucketStart).toBe(Date.UTC(2026, 9, 5, 12));
  });

  it("folds function paths past the per-batch cap into one row", () => {
    const many: RawEvent[] = Array.from({ length: MAX_FUNCTION_PATHS_PER_BATCH + 5 }, (_, i) => ({
      topic: "function_execution",
      timestamp: minute,
      convex,
      function: { path: `generated:fn${i}`, type: "query" },
      execution_time_ms: 1,
      status: "success",
    }));
    const minuteRows = buildBatch(many).stats.filter((s) => s.granularity === "minute");
    expect(minuteRows).toHaveLength(MAX_FUNCTION_PATHS_PER_BATCH + 1);
    expect(minuteRows.find((s) => s.path === OTHER_FUNCTIONS_PATH)!.calls).toBe(5);
  });

  it("captures errors, logs, audits, scheduler stats, and deployment metadata", () => {
    const batch = buildBatch(events);
    expect(batch.errors).toEqual([
      {
        deploymentName: "happy-otter-123",
        timestamp: minute + 2_000,
        path: "goals:list",
        type: "query",
        requestId: "r2",
        message: "Uncaught Error: boom",
      },
    ]);
    expect(batch.logs[0]).toMatchObject({ level: "WARN", path: "goals:create", message: "'careful'" });
    expect(batch.audits[0]).toMatchObject({ action: "push_config" });
    expect(batch.deployments).toEqual([
      {
        name: "happy-otter-123",
        deploymentType: "prod",
        projectName: "Demo",
        projectSlug: "demo",
        lastEventAt: minute + 5_000,
        schedulerLagSeconds: 2,
        schedulerRunningJobs: 3,
        schedulerStatsAt: minute + 4_000,
      },
    ]);
  });
});

describe("deploySummary", () => {
  const push = (diff: object, message: string | null = null) =>
    JSON.stringify({
      auth_diff: { added: [], removed: [] },
      component_diffs: [{ component_diff: diff, component_path: null }],
      message,
      node_version_diff: null,
    });
  const empty = {
    cronDiff: { added: [], deleted: [], updated: [] },
    indexDiff: { added_indexes: [], disabled_indexes: [], enabled_indexes: [], removed_indexes: [] },
    moduleDiff: { added: [], removed: [] },
    schemaDiff: null,
    udfConfigDiff: null,
  };

  it("says functions were updated when only code changed", () => {
    expect(deploySummary(push(empty))).toBe("Functions updated");
  });

  it("lists what changed, with the deploy message first", () => {
    const diff = {
      ...empty,
      moduleDiff: { added: ["chat.js", "catalog.js"], removed: ["old.js"] },
      indexDiff: { ...empty.indexDiff, added_indexes: [{ name: "chatThreads.by_updated" }] },
      cronDiff: { added: [], deleted: [], updated: ["cleanup"] },
      schemaDiff: { next_schema: "{}" },
    };
    expect(deploySummary(push(diff, "ship chat"))).toBe(
      '"ship chat" · 2 files added · 1 file removed · 1 index added · 1 cron changed · schema changed',
    );
  });

  it("survives truncated metadata", () => {
    expect(deploySummary(push(empty).slice(0, 40))).toBe("Functions updated");
  });

  it("is attached to deploy audits only", () => {
    const convexInfo = { deployment_name: "happy-otter-123" };
    const batch = buildBatch([
      { topic: "audit_log", timestamp: 1, convex: convexInfo, audit_log_action: "push_config_with_components", audit_log_metadata: push(empty) },
      { topic: "audit_log", timestamp: 2, convex: convexInfo, audit_log_action: "create_integration", audit_log_metadata: "{}" },
    ]);
    expect(batch.audits.map((audit) => audit.summary)).toEqual(["Functions updated", undefined]);
  });
});

describe("normalizeFunctionPath", () => {
  it("leaves query/mutation/action paths alone", () => {
    expect(normalizeFunctionPath("goals:list")).toBe("goals:list");
    expect(normalizeFunctionPath("lib/v2/goals.js:list")).toBe("lib/v2/goals.js:list");
  });

  it("replaces IDs in HTTP action paths and drops the query string", () => {
    expect(normalizeFunctionPath("POST /logs/happy-otter-123")).toBe("POST /logs/:id");
    expect(normalizeFunctionPath("GET /users/42/posts?limit=5")).toBe("GET /users/:id/posts");
    expect(normalizeFunctionPath("GET /files/k57a1b2c3d4e5f6g7h8j9k0m1n2p3q4r")).toBe("GET /files/:id");
    expect(normalizeFunctionPath("GET /api/v1/oauth2/callback")).toBe("GET /api/v1/oauth2/callback");
  });
});
