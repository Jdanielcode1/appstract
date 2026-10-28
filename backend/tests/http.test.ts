// @vitest-environment edge-runtime
/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "../convex/_generated/api";
import schema from "../convex/schema";

const modules = import.meta.glob("../convex/**/*.ts");
const APP_KEY = "test-app-key-0123456789abcdef";
const DEPLOYMENT = "brave-heron-42";

async function sign(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return "sha256=" + Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}

const batch = () =>
  JSON.stringify([
    {
      topic: "function_execution",
      timestamp: Date.now(),
      convex: { deployment_name: DEPLOYMENT, deployment_type: "prod" },
      function: { path: "orders:list", type: "query", request_id: `r${Math.random()}` },
      execution_time_ms: 5,
      status: "success",
    },
  ]);

async function post(t: ReturnType<typeof convexTest>, secret: string) {
  const body = batch();
  return t.fetch(`/logs/${DEPLOYMENT}`, { method: "POST", body, headers: { "x-webhook-signature": await sign(secret, body) } });
}

const register = (t: ReturnType<typeof convexTest>, hmacSecret: string) =>
  t.mutation(api.streams.register, { appKey: APP_KEY, deploymentName: DEPLOYMENT, logStreamId: "ls", hmacSecret });

describe("webhook /logs/<deployment>", () => {
  beforeEach(() => vi.stubEnv("APP_KEY", APP_KEY));
  afterEach(() => vi.unstubAllEnvs());

  it("accepts batches after the stream is recreated with a new secret", async () => {
    const t = convexTest(schema, modules);
    await register(t, "first-secret");
    expect((await post(t, "first-secret")).status).toBe(200);

    // "Repair" recreates the stream: the cached secret is now stale.
    await register(t, "second-secret");
    expect((await post(t, "second-secret")).status).toBe(200);
    expect((await post(t, "first-secret")).status).toBe(401);

    const summary = await t.query(api.dashboard.functionSummary, { appKey: APP_KEY, deploymentName: DEPLOYMENT, window: "24h" });
    expect(summary.totals.calls).toBe(2);
  });

  it("acknowledges batches for deployments it doesn't know", async () => {
    const t = convexTest(schema, modules);
    expect((await post(t, "anything")).status).toBe(200);
  });
});
