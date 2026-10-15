import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { assertAppKey } from "./lib/auth";

/** Deployments with monitoring enabled. Secrets are never returned to clients. */
export const list = query({
  args: { appKey: v.string() },
  returns: v.array(v.object({ deploymentName: v.string(), logStreamId: v.string(), createdAt: v.number() })),
  handler: async (ctx, { appKey }) => {
    assertAppKey(appKey);
    const streams = await ctx.db.query("streams").take(500);
    return streams.map(({ deploymentName, logStreamId, createdAt }) => ({ deploymentName, logStreamId, createdAt }));
  },
});

/**
 * Called by the app right after it creates a webhook log stream on a deployment via the
 * Deployment API. Re-registering a deployment replaces its secret.
 */
export const register = mutation({
  args: {
    appKey: v.string(),
    deploymentName: v.string(),
    logStreamId: v.string(),
    hmacSecret: v.string(),
  },
  returns: v.null(),
  handler: async (ctx, { appKey, deploymentName, logStreamId, hmacSecret }) => {
    assertAppKey(appKey);
    const existing = await ctx.db
      .query("streams")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { logStreamId, hmacSecret });
    } else {
      await ctx.db.insert("streams", { deploymentName, logStreamId, hmacSecret, createdAt: Date.now() });
    }
    return null;
  },
});

/** Removes the stream registration and, optionally, all data collected for the deployment. */
export const unregister = mutation({
  args: { appKey: v.string(), deploymentName: v.string(), deleteData: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { appKey, deploymentName, deleteData }) => {
    assertAppKey(appKey);
    const existing = await ctx.db
      .query("streams")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
      .unique();
    if (existing) await ctx.db.delete(existing._id);
    if (deleteData) {
      await ctx.scheduler.runAfter(0, internal.streams.deleteDeploymentData, { deploymentName });
    }
    return null;
  },
});

/** Used by the /logs/<deployment> HTTP route to verify webhook signatures. */
export const getSecret = internalQuery({
  args: { deploymentName: v.string() },
  returns: v.union(v.string(), v.null()),
  handler: async (ctx, { deploymentName }) => {
    const stream = await ctx.db
      .query("streams")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
      .unique();
    return stream?.hmacSecret ?? null;
  },
});

const DELETE_BATCH = 1_000;

/** Deletes everything stored for a deployment in batches, rescheduling itself until done. */
export const deleteDeploymentData = internalMutation({
  args: { deploymentName: v.string() },
  returns: v.null(),
  handler: async (ctx, { deploymentName }) => {
    const batches = await Promise.all([
      ctx.db
        .query("functionStats")
        .withIndex("by_deployment_bucket", (q) => q.eq("deploymentName", deploymentName))
        .take(DELETE_BATCH),
      ctx.db
        .query("errors")
        .withIndex("by_deployment_time", (q) => q.eq("deploymentName", deploymentName))
        .take(DELETE_BATCH),
      ctx.db
        .query("logs")
        .withIndex("by_deployment_time", (q) => q.eq("deploymentName", deploymentName))
        .take(DELETE_BATCH),
      ctx.db
        .query("auditEvents")
        .withIndex("by_deployment_time", (q) => q.eq("deploymentName", deploymentName))
        .take(DELETE_BATCH),
    ]);

    for (const batch of batches) {
      for (const doc of batch) await ctx.db.delete(doc._id);
    }

    if (batches.some((batch) => batch.length === DELETE_BATCH)) {
      await ctx.scheduler.runAfter(0, internal.streams.deleteDeploymentData, { deploymentName });
      return null;
    }

    const deployment = await ctx.db
      .query("deployments")
      .withIndex("by_name", (q) => q.eq("name", deploymentName))
      .unique();
    if (deployment) await ctx.db.delete(deployment._id);
    return null;
  },
});
