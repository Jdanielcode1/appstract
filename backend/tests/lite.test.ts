// @vitest-environment edge-runtime
/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import { OTHER_FUNCTIONS_PATH } from "../convex/lib/events";
import { buildLiteBatch, functionPath, pollWindow, type MetricBucket, type TopK } from "../convex/lib/lite";
import schema from "../convex/schema";

const modules = import.meta.glob("../convex/**/*.ts");
const APP_KEY = "test-app-key-0123456789abcdef";
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
// 10:00 UTC on a fixed day.
const T0 = Date.UTC(2026, 9, 16, 10, 0, 0);

const bucket = (ms: number, value: number | null): MetricBucket => [
  { secs_since_epoch: ms / 1000, nanos_since_epoch: 0 },
  value,
];
const series = (start: number, values: (number | null)[]) => values.map((value, i) => bucket(start + i * MINUTE, value));

describe("pollWindow", () => {
  it("backfills 55 minutes on the first poll, up to the last settled minute", () => {
    const window = pollWindow(undefined, T0 + 30_000)!;
    expect(window.end).toBe(T0 - MINUTE);
    expect(window.start).toBe(T0 - 56 * MINUTE);
    expect(window.buckets).toBe(55);
  });

  it("resumes where the last poll stopped", () => {
    expect(pollWindow(T0 - 6 * MINUTE, T0 + 30_000)).toEqual({ start: T0 - 6 * MINUTE, end: T0 - MINUTE, buckets: 5 });
  });

  it("returns null when caught up", () => {
    expect(pollWindow(T0 - MINUTE, T0 + 30_000)).toBeNull();
  });

  it("skips a long gap instead of asking for more than the endpoints keep", () => {
    expect(pollWindow(T0 - 5 * HOUR, T0)!.buckets).toBe(55);
  });
});

describe("buildLiteBatch", () => {
  const window = { start: T0, end: T0 + 3 * MINUTE, buckets: 3 };

  it("strips file extensions like log streams report paths", () => {
    expect(functionPath("alerts.js:checkThresholds")).toBe("alerts:checkThresholds");
    expect(functionPath("lib/foo.ts:bar")).toBe("lib/foo:bar");
    expect(functionPath("/logs/*")).toBe("/logs/*");
  });

  it("turns calls and failure % into minute/hour/day stats and totals", () => {
    const calls: TopK = [
      ["orders.js:list", series(T0, [10, 4, null])],
      ["/webhook", series(T0, [2, 0, 0])],
      ["_rest", series(T0, [1, 0, 0])],
    ];
    const failures: TopK = [
      ["orders.js:list", series(T0, [50, 0, null])],
      ["_rest", series(T0, [0, 0, 0])],
    ];
    const types = new Map([["orders:list", "query"]]);
    const batch = buildLiteBatch("happy-otter-123", window, calls, failures, [], types);

    const minute = batch.stats.filter((s) => s.granularity === "minute" && s.path === "orders:list");
    expect(minute.map((s) => [s.bucketStart, s.calls, s.errors])).toEqual([
      [T0, 10, 5],
      [T0 + MINUTE, 4, 0],
    ]);
    const hour = batch.stats.find((s) => s.granularity === "hour" && s.path === "orders:list")!;
    expect([hour.calls, hour.errors, hour.type]).toEqual([14, 5, "query"]);
    expect(batch.stats.find((s) => s.path === "/webhook")!.type).toBe("http_action");
    expect(batch.stats.some((s) => s.path === OTHER_FUNCTIONS_PATH && s.granularity === "day" && s.calls === 1)).toBe(true);

    const minuteTotals = batch.totals.filter((t) => t.granularity === "minute");
    expect(minuteTotals.map((t) => [t.bucketStart, t.calls, t.errors])).toEqual([
      [T0, 13, 5],
      [T0 + MINUTE, 4, 0],
    ]);
    expect(batch.totals.find((t) => t.granularity === "hour")!.calls).toBe(17);
    expect(batch.lastActiveAt).toBe(T0 + 2 * MINUTE);
  });

  it("attributes failures outside the calls top K to other functions", () => {
    const calls: TopK = [["a.js:x", series(T0, [100, 0, 0])], ["_rest", series(T0, [10, 0, 0])]];
    const failures: TopK = [["rare.js:job", series(T0, [100, null, null])], ["_rest", series(T0, [10, 0, 0])]];
    const batch = buildLiteBatch("d", window, calls, failures, [], new Map());
    const other = batch.stats.find((s) => s.granularity === "minute" && s.path === OTHER_FUNCTIONS_PATH)!;
    // 1 from the unlisted failing function + 10% of the 110 other calls.
    expect(other.errors).toBe(12);
    expect(other.calls).toBe(12);
  });

  it("ignores buckets outside the window and keeps the newest scheduler lag", () => {
    const calls: TopK = [["a.js:x", series(T0 - MINUTE, [5, 1, 1, 1, 7])]];
    const lag = series(T0, [3, 8, null]);
    const batch = buildLiteBatch("d", window, calls, [], lag, new Map());
    const totals = batch.totals.filter((t) => t.granularity === "minute");
    expect(totals.map((t) => t.bucketStart)).toEqual([T0, T0 + MINUTE, T0 + 2 * MINUTE]);
    expect(batch.schedulerLag).toEqual({ seconds: 8, at: T0 + MINUTE });
  });
});

describe("Lite polling", () => {
  beforeEach(() => {
    vi.stubEnv("APP_KEY", APP_KEY);
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(T0 + 30_000);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  /** Fakes the deployment: 3 calls of orders:list every minute, one failing minute. */
  function stubMetrics() {
    const requests: string[] = [];
    vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      requests.push(url.pathname);
      expect(new Headers(init?.headers).get("Authorization")).toBe("Convex team-token");
      const window = JSON.parse(url.searchParams.get("window") ?? "null");
      const start = window ? window.start.secs_since_epoch * 1000 : 0;
      const minutes = window?.num_buckets ?? 0;
      const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });
      if (url.pathname.endsWith("/function_call_count_top_k")) {
        return json([["orders.js:list", series(start, new Array(minutes).fill(3))]]);
      }
      if (url.pathname.endsWith("/failure_percentage_top_k")) {
        return json([["orders.js:list", series(start, new Array(minutes).fill(0).map((_, i) => (i === 0 ? 100 : 0)))]]);
      }
      if (url.pathname.endsWith("/scheduled_job_lag")) return json(series(start, new Array(minutes).fill(null)));
      if (url.pathname === "/api/query") {
        return json({ status: "success", value: [{ identifier: "orders.js:list", functionType: "Query" }] });
      }
      return new Response("not found", { status: 404 });
    });
    return requests;
  }

  const enable = (t: ReturnType<typeof convexTest>) =>
    t.mutation(api.lite.enable, {
      appKey: APP_KEY,
      accessToken: "team-token",
      deploymentName: "happy-otter-123",
      deploymentUrl: "https://happy-otter-123.convex.cloud",
      deploymentType: "prod",
      projectName: "Shop",
    });

  async function minuteTotals(t: ReturnType<typeof convexTest>) {
    return t.run((ctx) =>
      ctx.db
        .query("deploymentStats")
        .withIndex("by_deploymentName_granularity_bucketStart", (q) =>
          q.eq("deploymentName", "happy-otter-123").eq("granularity", "minute"),
        )
        .collect(),
    );
  }

  it("backfills the last hour, then records only new minutes", async () => {
    const t = convexTest(schema, modules);
    const requests = stubMetrics();
    await enable(t);
    await t.action(internal.lite.poll, {});

    let totals = await minuteTotals(t);
    expect(totals).toHaveLength(55);
    expect(totals.reduce((sum, row) => sum + row.calls, 0)).toBe(165);
    expect(totals.reduce((sum, row) => sum + row.errors, 0)).toBe(3);
    expect(requests.filter((path) => path === "/api/query")).toHaveLength(1);

    const [deployment] = await t.query(api.dashboard.deployments, { appKey: APP_KEY });
    expect(deployment).toMatchObject({ name: "happy-otter-123", projectName: "Shop", deploymentType: "prod", mode: "lite" });
    const summary = await t.query(api.dashboard.functionSummary, { appKey: APP_KEY, deploymentName: "happy-otter-123", window: "24h" });
    expect(summary.functions[0]).toMatchObject({ path: "orders:list", type: "query", calls: 165, errors: 3 });

    // Five minutes later: only the five new minutes, and the function types are cached.
    vi.setSystemTime(T0 + 5 * MINUTE + 30_000);
    await t.action(internal.lite.poll, {});
    totals = await minuteTotals(t);
    expect(totals).toHaveLength(60);
    expect(totals.reduce((sum, row) => sum + row.calls, 0)).toBe(180);
    expect(requests.filter((path) => path === "/api/query")).toHaveLength(1);
  });

  it("drops a result from a poll that started before another one recorded", async () => {
    const t = convexTest(schema, modules);
    stubMetrics();
    await enable(t);
    await t.action(internal.lite.poll, {});
    await t.mutation(internal.lite.record, {
      evaluateAlerts: false,
      results: [
        {
          deploymentName: "happy-otter-123",
          // The value before the first poll recorded.
          from: undefined,
          through: T0,
          stats: [],
          totals: [
            {
              deploymentName: "happy-otter-123",
              granularity: "minute",
              bucketStart: T0 - 2 * MINUTE,
              calls: 1000,
              errors: 0,
              cachedCalls: 0,
              totalMs: 0,
              maxMs: 0,
              latencyHistogram: [],
            },
          ],
        },
      ],
    });
    const totals = await minuteTotals(t);
    expect(totals.reduce((sum, row) => sum + row.calls, 0)).toBe(165);
  });

  it("skips deployments that have a log stream and reports rejected tokens", async () => {
    const t = convexTest(schema, modules);
    const requests = stubMetrics();
    await t.mutation(api.streams.register, {
      appKey: APP_KEY,
      deploymentName: "happy-otter-123",
      logStreamId: "ls1",
      hmacSecret: "secret",
    });
    await enable(t);
    await t.action(internal.lite.poll, {});
    expect(requests).toHaveLength(0);

    await t.mutation(api.streams.unregister, { appKey: APP_KEY, deploymentName: "happy-otter-123", deleteData: false });
    // Lite resumes from the minute the stream was removed.
    vi.setSystemTime(T0 + 3 * MINUTE);
    vi.stubGlobal("fetch", async () => new Response("no", { status: 401 }));
    await t.action(internal.lite.poll, {});
    const [target] = await t.query(api.lite.list, { appKey: APP_KEY });
    expect(target.lastError).toMatch(/rejected the access token/);
  });

  it("forgets the token when the last deployment turns Lite off", async () => {
    const t = convexTest(schema, modules);
    stubMetrics();
    await enable(t);
    await t.mutation(api.lite.disable, { appKey: APP_KEY, deploymentName: "happy-otter-123", deleteData: false });
    const secrets = await t.run((ctx) => ctx.db.query("secrets").collect());
    expect(secrets).toHaveLength(0);
    expect(await t.query(api.lite.list, { appKey: APP_KEY })).toHaveLength(0);
  });

  it("requires the app key", async () => {
    const t = convexTest(schema, modules);
    await expect(t.query(api.lite.list, { appKey: "wrong" })).rejects.toThrow(/Unauthorized/);
  });
});
