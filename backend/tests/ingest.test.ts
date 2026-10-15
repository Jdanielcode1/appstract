// @vitest-environment edge-runtime
/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import { buildBatch, HISTOGRAM_SIZE, type RawEvent } from "../convex/lib/events";
import schema from "../convex/schema";

const modules = import.meta.glob("../convex/**/*.ts");
const APP_KEY = "test-app-key-0123456789abcdef";
const convex = { deployment_name: "happy-otter-123", deployment_type: "prod", project_name: "Demo" };

function call(path: string, timestamp: number, failed = false): RawEvent {
  return {
    topic: "function_execution",
    timestamp,
    convex,
    function: { path, type: "query", request_id: `r${timestamp}` },
    execution_time_ms: 10,
    status: failed ? "failure" : "success",
    ...(failed && { error_message: "boom" }),
  };
}

const log = (timestamp: number, message: string): RawEvent => ({
  topic: "console",
  timestamp,
  convex,
  function: { path: "goals:list" },
  log_level: "LOG",
  message,
});

beforeEach(() => {
  vi.stubEnv("APP_KEY", APP_KEY);
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.useRealTimers();
});

describe("ingestBatch", () => {
  it("stops storing log lines past the daily quota but keeps counting them", async () => {
    vi.stubEnv("MAX_LOG_LINES_PER_DAY", "3");
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.mutation(internal.ingest.ingestBatch, buildBatch([1, 2, 3, 4, 5].map((i) => log(now + i, `line ${i}`))));
    await t.mutation(internal.ingest.ingestBatch, buildBatch([log(now + 6, "line 6")]));

    const logs = await t.query(api.dashboard.recentLogs, { appKey: APP_KEY, deploymentName: convex.deployment_name });
    expect(logs.map((l) => l.message).sort()).toEqual(["line 1", "line 2", "line 3"]);
    const [deployment] = await t.query(api.dashboard.deployments, { appKey: APP_KEY });
    expect(deployment.logsDroppedToday).toBe(3);
  });

  it("keeps deployment totals and failing functions for the Overview", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.mutation(
      internal.ingest.ingestBatch,
      buildBatch([call("goals:list", now), call("goals:list", now + 1, true), call("goals:create", now + 2)]),
    );
    await t.mutation(internal.ingest.ingestBatch, buildBatch([call("goals:list", now + 3, true)]));

    const [row] = await t.query(api.dashboard.overview, { appKey: APP_KEY });
    expect(row).toMatchObject({ calls: 4, errors: 2, errorRate: 0.5 });
    expect(row.failingFunctions).toEqual([{ path: "goals:list", errors: 2, calls: 3 }]);

    const summary = await t.query(api.dashboard.functionSummary, {
      appKey: APP_KEY,
      deploymentName: convex.deployment_name,
      window: "7d",
    });
    expect(summary.totals).toEqual({ calls: 4, errors: 2, errorRate: 0.5 });
  });
});

describe("rollups:rebuild", () => {
  it("rebuilds totals and day rows from existing hour rows, and is safe to re-run", async () => {
    vi.useFakeTimers();
    const t = convexTest(schema, modules);
    const hour = Math.floor(Date.now() / 3_600_000) * 3_600_000;

    // Rows as an older version wrote them: hour rows only, no hasErrors, no deploymentStats.
    await t.run(async (ctx) => {
      await ctx.db.insert("deployments", { name: convex.deployment_name, lastEventAt: hour });
      for (const [path, calls, errors] of [
        ["goals:list", 10, 2],
        ["goals:create", 5, 0],
      ] as const) {
        await ctx.db.insert("functionStats", {
          deploymentName: convex.deployment_name,
          granularity: "hour",
          bucketStart: hour,
          path,
          type: "query",
          calls,
          errors,
          cachedCalls: 0,
          totalMs: calls * 10,
          maxMs: 10,
          latencyHistogram: new Array<number>(HISTOGRAM_SIZE).fill(0),
          dbReadBytes: 0,
          dbWriteBytes: 0,
          docsRead: 0,
          docsWritten: 0,
          egressBytes: 0,
        });
      }
    });

    for (let run = 0; run < 2; run++) {
      await t.mutation(internal.rollups.rebuild, {});
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    }

    const [row] = await t.query(api.dashboard.overview, { appKey: APP_KEY });
    expect(row).toMatchObject({ calls: 15, errors: 2 });
    expect(row.failingFunctions).toEqual([{ path: "goals:list", errors: 2, calls: 10 }]);
    const summary = await t.query(api.dashboard.functionSummary, {
      appKey: APP_KEY,
      deploymentName: convex.deployment_name,
      window: "7d",
    });
    expect(summary.functions.map((f) => [f.path, f.calls])).toEqual([
      ["goals:list", 10],
      ["goals:create", 5],
    ]);
  });
});
