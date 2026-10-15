import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, mutation, query, type MutationCtx } from "./_generated/server";
import {
  deploymentLabel,
  errorHeadline,
  errorSignature,
  logMatches,
  MAX_ALERTS_PER_RULE_PER_BATCH,
  ruleAppliesTo,
  truncate,
} from "./lib/alerts";
import { assertAppKey } from "./lib/auth";
import { isDeployAction, type AuditEntry, type ErrorEntry, type LogEntry } from "./lib/events";
import { alertRuleFields } from "./schema";

const MINUTE_MS = 60_000;

// MARK: - Firing

interface AlertInput {
  rule: Doc<"alertRules">;
  deploymentName: string;
  title: string;
  body: string;
  path?: string;
}

/** True when this rule already alerted for this deployment within its cooldown. */
async function inCooldown(ctx: MutationCtx, rule: Doc<"alertRules">, deploymentName: string, now: number) {
  if (rule.cooldownMinutes <= 0) return false;
  const last = await ctx.db
    .query("alertEvents")
    .withIndex("by_rule_deployment_time", (q) => q.eq("ruleId", rule._id).eq("deploymentName", deploymentName))
    .order("desc")
    .first();
  return last !== null && last.firedAt > now - rule.cooldownMinutes * MINUTE_MS;
}

/** Records the alert and schedules push delivery. */
async function fire(ctx: MutationCtx, alert: AlertInput) {
  const eventId = await ctx.db.insert("alertEvents", {
    ruleId: alert.rule._id,
    kind: alert.rule.kind,
    deploymentName: alert.deploymentName,
    title: truncate(alert.title, 120),
    body: truncate(alert.body, 400),
    path: alert.path,
    firedAt: Date.now(),
  });
  await ctx.scheduler.runAfter(0, internal.push.deliver, { eventId });
}

async function labelFor(ctx: MutationCtx, deploymentName: string) {
  const deployment = await ctx.db
    .query("deployments")
    .withIndex("by_name", (q) => q.eq("name", deploymentName))
    .unique();
  return deploymentLabel(deployment, deploymentName);
}

// MARK: - Evaluation at ingest (newError, logMatch, deploy)

/**
 * Called from `ingest.ingestBatch` with the batch's errors, logs, and audit events. Tracks error
 * signatures for every error (so rules created later don't fire on old errors) and fires matching rules.
 */
export async function evaluateIngest(ctx: MutationCtx, errors: ErrorEntry[], logs: LogEntry[], audits: AuditEntry[]) {
  const rules = (await ctx.db.query("alertRules").take(200)).filter((rule) => rule.enabled);
  const newErrorRules = rules.filter((rule) => rule.kind === "newError");
  const logRules = rules.filter((rule) => rule.kind === "logMatch");
  const deployRules = rules.filter((rule) => rule.kind === "deploy");
  const firedPerRule = new Map<Id<"alertRules">, number>();
  const canFire = (rule: Doc<"alertRules">) => (firedPerRule.get(rule._id) ?? 0) < MAX_ALERTS_PER_RULE_PER_BATCH;
  const countFire = (rule: Doc<"alertRules">) => firedPerRule.set(rule._id, (firedPerRule.get(rule._id) ?? 0) + 1);
  const now = Date.now();

  for (const error of errors) {
    const signature = errorSignature(error.message);
    const existing = await ctx.db
      .query("errorSignatures")
      .withIndex("by_key", (q) =>
        q.eq("deploymentName", error.deploymentName).eq("path", error.path).eq("signature", signature),
      )
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, {
        lastSeenAt: Math.max(existing.lastSeenAt, error.timestamp),
        count: existing.count + 1,
      });
      continue;
    }
    await ctx.db.insert("errorSignatures", {
      deploymentName: error.deploymentName,
      path: error.path,
      signature,
      sample: truncate(error.message, 2_000),
      firstSeenAt: error.timestamp,
      lastSeenAt: error.timestamp,
      count: 1,
    });

    for (const rule of newErrorRules) {
      if (!ruleAppliesTo(rule, error.deploymentName) || !canFire(rule)) continue;
      if (await inCooldown(ctx, rule, error.deploymentName, now)) continue;
      countFire(rule);
      await fire(ctx, {
        rule,
        deploymentName: error.deploymentName,
        title: `New error · ${await labelFor(ctx, error.deploymentName)}`,
        body: `${error.path}: ${errorHeadline(error.message)}`,
        path: error.path,
      });
    }
  }

  for (const rule of logRules) {
    // One alert per rule per deployment per batch; the cooldown limits it across batches.
    const firedDeployments = new Set<string>();
    for (const log of logs) {
      if (firedDeployments.has(log.deploymentName) || !canFire(rule)) continue;
      if (!ruleAppliesTo(rule, log.deploymentName) || !logMatches(rule, log)) continue;
      if (await inCooldown(ctx, rule, log.deploymentName, now)) {
        firedDeployments.add(log.deploymentName);
        continue;
      }
      firedDeployments.add(log.deploymentName);
      countFire(rule);
      await fire(ctx, {
        rule,
        deploymentName: log.deploymentName,
        title: `${log.level} log · ${await labelFor(ctx, log.deploymentName)}`,
        body: `${log.path ? `${log.path}: ` : ""}${log.message}`,
        path: log.path || undefined,
      });
    }
  }

  // One alert per deploy rule per deployment per batch (a batch can hold several pushes).
  const deploys = new Map<string, AuditEntry>();
  for (const audit of audits) {
    if (!isDeployAction(audit.action)) continue;
    const latest = deploys.get(audit.deploymentName);
    if (!latest || audit.timestamp > latest.timestamp) deploys.set(audit.deploymentName, audit);
  }
  for (const [deploymentName, audit] of deploys) {
    if (deployRules.length === 0) break;
    const deployment = await ctx.db
      .query("deployments")
      .withIndex("by_name", (q) => q.eq("name", deploymentName))
      .unique();
    for (const rule of deployRules) {
      if (!ruleAppliesTo(rule, deploymentName) || !canFire(rule)) continue;
      if (rule.prodOnly && deployment?.deploymentType !== "prod") continue;
      if (await inCooldown(ctx, rule, deploymentName, now)) continue;
      countFire(rule);
      await fire(ctx, {
        rule,
        deploymentName,
        title: `Deployed · ${deploymentLabel(deployment, deploymentName)}`,
        body: audit.summary ?? "Functions updated",
      });
    }
  }
}

// MARK: - Periodic evaluation (errorRate, schedulerLag)

export const checkThresholds = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const rules = (await ctx.db.query("alertRules").take(200)).filter(
      (rule) => rule.enabled && (rule.kind === "errorRate" || rule.kind === "schedulerLag"),
    );
    if (rules.length === 0) return null;

    const now = Date.now();
    const deployments = await ctx.db.query("deployments").take(100);

    for (const rule of rules) {
      for (const deployment of deployments) {
        if (!ruleAppliesTo(rule, deployment.name)) continue;

        if (rule.kind === "errorRate") {
          const windowMinutes = rule.windowMinutes ?? 5;
          const since = now - windowMinutes * MINUTE_MS;
          const totals = await ctx.db
            .query("deploymentStats")
            .withIndex("by_deploymentName_granularity_bucketStart", (q) =>
              q.eq("deploymentName", deployment.name).eq("granularity", "minute").gte("bucketStart", since),
            )
            .take(windowMinutes + 2);
          const calls = totals.reduce((sum, row) => sum + row.calls, 0);
          const errors = totals.reduce((sum, row) => sum + row.errors, 0);
          const threshold = rule.threshold ?? 0.05;
          if (calls < (rule.minCalls ?? 20) || errors / calls < threshold) continue;
          if (await inCooldown(ctx, rule, deployment.name, now)) continue;

          // Only the minute rows that had errors, to name the worst function.
          const failing = await ctx.db
            .query("functionStats")
            .withIndex("by_deploymentName_granularity_hasErrors_bucketStart", (q) =>
              q
                .eq("deploymentName", deployment.name)
                .eq("granularity", "minute")
                .eq("hasErrors", true)
                .gte("bucketStart", since),
            )
            .take(1_000);
          const errorsByPath = new Map<string, number>();
          for (const row of failing) errorsByPath.set(row.path, (errorsByPath.get(row.path) ?? 0) + row.errors);
          const [worstPath, worstErrors] = [...errorsByPath.entries()].sort((a, b) => b[1] - a[1])[0] ?? [];
          const worst = worstPath ? { path: worstPath, errors: worstErrors } : undefined;
          await fire(ctx, {
            rule,
            deploymentName: deployment.name,
            title: `Error rate ${Math.round((errors / calls) * 100)}% · ${deploymentLabel(deployment, deployment.name)}`,
            body: `${errors} of ${calls} calls failed in the last ${windowMinutes} min${worst?.errors ? `. Most from ${worst.path}` : ""}.`,
            path: worst?.errors ? worst.path : undefined,
          });
        } else {
          const lag = deployment.schedulerLagSeconds ?? 0;
          const fresh = (deployment.schedulerStatsAt ?? 0) > now - 5 * MINUTE_MS;
          if (!fresh || lag < (rule.lagSeconds ?? 60)) continue;
          if (await inCooldown(ctx, rule, deployment.name, now)) continue;
          await fire(ctx, {
            rule,
            deploymentName: deployment.name,
            title: `Scheduler behind · ${deploymentLabel(deployment, deployment.name)}`,
            body: `Scheduled jobs are ${Math.round(lag)}s behind (${deployment.schedulerRunningJobs ?? 0} running).`,
          });
        }
      }
    }
    return null;
  },
});

// MARK: - Public API (iOS app)

const ruleResult = v.object({ _id: v.id("alertRules"), _creationTime: v.number(), ...alertRuleFields, createdAt: v.number() });

export const listRules = query({
  args: { appKey: v.string() },
  returns: v.array(ruleResult),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    return await ctx.db.query("alertRules").order("asc").take(200);
  },
});

/** Creates a rule, or replaces the rule with `id`. */
export const saveRule = mutation({
  args: { appKey: v.string(), id: v.optional(v.id("alertRules")), ...alertRuleFields },
  returns: v.id("alertRules"),
  handler: async (ctx, { appKey, id, ...rule }) => {
    assertAppKey(appKey);
    if (rule.kind === "logMatch" && !rule.level && !rule.pattern && !rule.path) {
      throw new ConvexError("A log rule needs a level, text, or function to match.");
    }
    if (id) {
      const existing = await ctx.db.get(id);
      if (!existing) throw new ConvexError("Rule not found");
      await ctx.db.replace(id, { ...rule, createdAt: existing.createdAt });
      return id;
    }
    return await ctx.db.insert("alertRules", { ...rule, createdAt: Date.now() });
  },
});

export const setRuleEnabled = mutation({
  args: { appKey: v.string(), id: v.id("alertRules"), enabled: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { appKey, id, enabled }) => {
    assertAppKey(appKey);
    await ctx.db.patch(id, { enabled });
    return null;
  },
});

export const deleteRule = mutation({
  args: { appKey: v.string(), id: v.id("alertRules") },
  returns: v.null(),
  handler: async (ctx, { appKey, id }) => {
    assertAppKey(appKey);
    await ctx.db.delete(id);
    return null;
  },
});

/** Recommended starter rules: new errors anywhere, error rate above 5%, and production deploys. */
export const createDefaultRules = mutation({
  args: { appKey: v.string() },
  returns: v.null(),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const now = Date.now();
    await ctx.db.insert("alertRules", { kind: "newError", enabled: true, cooldownMinutes: 0, createdAt: now });
    await ctx.db.insert("alertRules", {
      kind: "errorRate",
      enabled: true,
      cooldownMinutes: 30,
      threshold: 0.05,
      minCalls: 20,
      windowMinutes: 5,
      createdAt: now,
    });
    await ctx.db.insert("alertRules", { kind: "deploy", enabled: true, cooldownMinutes: 5, prodOnly: true, createdAt: now });
    return null;
  },
});

export const recentEvents = query({
  args: { appKey: v.string(), limit: v.optional(v.number()) },
  returns: v.array(
    v.object({
      _id: v.id("alertEvents"),
      kind: v.string(),
      deploymentName: v.string(),
      title: v.string(),
      body: v.string(),
      path: v.optional(v.string()),
      firedAt: v.number(),
      deliveredCount: v.optional(v.number()),
      deliveryError: v.optional(v.string()),
    }),
  ),
  handler: async (ctx, { appKey, limit }) => {
    assertAppKey(appKey);
    const events = await ctx.db
      .query("alertEvents")
      .withIndex("by_time")
      .order("desc")
      .take(Math.min(limit ?? 50, 200));
    return events.map(({ _id, kind, deploymentName, title, body, path, firedAt, deliveredCount, deliveryError }) => ({
      _id,
      kind,
      deploymentName,
      title,
      body,
      path,
      firedAt,
      deliveredCount,
      deliveryError,
    }));
  },
});

/** Whether push is configured on this backend and how many devices are registered. */
export const status = query({
  args: { appKey: v.string() },
  returns: v.object({ pushConfigured: v.boolean(), deviceCount: v.number() }),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const devices = await ctx.db.query("devices").take(50);
    return {
      pushConfigured: Boolean(process.env.APNS_KEY_P8 && process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID),
      deviceCount: devices.length,
    };
  },
});

export const registerDevice = mutation({
  args: { appKey: v.string(), token: v.string(), sandbox: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { appKey, token, sandbox }) => {
    assertAppKey(appKey);
    const now = Date.now();
    const existing = await ctx.db
      .query("devices")
      .withIndex("by_token", (q) => q.eq("token", token))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { sandbox, lastSeenAt: now });
    } else {
      await ctx.db.insert("devices", { token, sandbox, createdAt: now, lastSeenAt: now });
    }
    return null;
  },
});

/** Fires a test alert to every registered device. */
export const sendTest = mutation({
  args: { appKey: v.string() },
  returns: v.id("alertEvents"),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const eventId = await ctx.db.insert("alertEvents", {
      kind: "test",
      deploymentName: "test",
      title: "Test alert",
      body: "Push notifications from your monitoring backend are working.",
      firedAt: Date.now(),
    });
    await ctx.scheduler.runAfter(0, internal.push.deliver, { eventId });
    return eventId;
  },
});

// MARK: - Internal (push delivery)

export const getDeliveryInfo = internalQuery({
  args: { eventId: v.id("alertEvents") },
  returns: v.union(
    v.null(),
    v.object({
      event: v.object({ title: v.string(), body: v.string(), deploymentName: v.string(), path: v.optional(v.string()) }),
      devices: v.array(v.object({ token: v.string(), sandbox: v.boolean() })),
    }),
  ),
  handler: async (ctx, { eventId }) => {
    const event = await ctx.db.get(eventId);
    if (!event) return null;
    const devices = await ctx.db.query("devices").take(50);
    return {
      event: { title: event.title, body: event.body, deploymentName: event.deploymentName, path: event.path },
      devices: devices.map(({ token, sandbox }) => ({ token, sandbox })),
    };
  },
});

export const recordDelivery = internalMutation({
  args: {
    eventId: v.id("alertEvents"),
    deliveredCount: v.number(),
    deliveryError: v.optional(v.string()),
    invalidTokens: v.array(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { eventId, deliveredCount, deliveryError, invalidTokens }) => {
    if (await ctx.db.get(eventId)) {
      await ctx.db.patch(eventId, { deliveredCount, deliveryError });
    }
    for (const token of invalidTokens) {
      const device = await ctx.db
        .query("devices")
        .withIndex("by_token", (q) => q.eq("token", token))
        .unique();
      if (device) await ctx.db.delete(device._id);
    }
    return null;
  },
});
