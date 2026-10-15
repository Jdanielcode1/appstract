import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id, TableNames } from "./_generated/dataModel";
import { internalMutation } from "./_generated/server";
import { retention } from "./lib/config";

/** Max documents deleted per table per run; the job reschedules itself if more remain. */
const BATCH = 1_000;

export const purgeExpired = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const now = Date.now();
    // Retention windows; logs, errors, and the 30-day group are configurable (lib/config.ts).
    const windows = retention();
    const RETENTION = {
      logs: windows.logs,
      errors: windows.errors,
      minuteStats: windows.minuteStats,
      auditEvents: windows.stats,
      hourStats: windows.stats,
      alertEvents: windows.stats,
      errorSignatures: windows.stats,
      aiQueries: windows.stats,
      chatThreads: windows.stats,
    };
    let hitLimit = false;

    const purge = async (docs: { _id: Id<TableNames> }[]) => {
      for (const doc of docs) await ctx.db.delete(doc._id);
      if (docs.length === BATCH) hitLimit = true;
    };

    await purge(
      await ctx.db
        .query("logs")
        .withIndex("by_time", (q) => q.lt("timestamp", now - RETENTION.logs))
        .take(BATCH),
    );
    await purge(
      await ctx.db
        .query("errors")
        .withIndex("by_time", (q) => q.lt("timestamp", now - RETENTION.errors))
        .take(BATCH),
    );
    // Inactive chat threads, with their messages (a thread is deleted once its messages are gone).
    for (const thread of await ctx.db
      .query("chatThreads")
      .withIndex("by_updated", (q) => q.lt("updatedAt", now - RETENTION.chatThreads))
      .take(20)) {
      const messages = await ctx.db
        .query("chatMessages")
        .withIndex("by_thread", (q) => q.eq("threadId", thread._id))
        .take(BATCH);
      await purge(messages);
      if (messages.length < BATCH) await ctx.db.delete(thread._id);
    }
    await purge(
      await ctx.db
        .query("aiQueries")
        .withIndex("by_creation_time", (q) => q.lt("_creationTime", now - RETENTION.aiQueries))
        .take(BATCH),
    );
    await purge(
      await ctx.db
        .query("auditEvents")
        .withIndex("by_time", (q) => q.lt("timestamp", now - RETENTION.auditEvents))
        .take(BATCH),
    );
    await purge(
      await ctx.db
        .query("functionStats")
        .withIndex("by_granularity_bucket", (q) =>
          q.eq("granularity", "minute").lt("bucketStart", now - RETENTION.minuteStats),
        )
        .take(BATCH),
    );
    await purge(
      await ctx.db
        .query("functionStats")
        .withIndex("by_granularity_bucket", (q) =>
          q.eq("granularity", "hour").lt("bucketStart", now - RETENTION.hourStats),
        )
        .take(BATCH),
    );
    await purge(
      await ctx.db
        .query("functionStats")
        .withIndex("by_granularity_bucket", (q) =>
          q.eq("granularity", "day").lt("bucketStart", now - RETENTION.hourStats),
        )
        .take(BATCH),
    );
    for (const [granularity, maxAge] of [
      ["minute", RETENTION.minuteStats],
      ["hour", RETENTION.hourStats],
    ] as const) {
      await purge(
        await ctx.db
          .query("deploymentStats")
          .withIndex("by_granularity_bucketStart", (q) =>
            q.eq("granularity", granularity).lt("bucketStart", now - maxAge),
          )
          .take(BATCH),
      );
    }

    await purge(
      await ctx.db
        .query("alertEvents")
        .withIndex("by_time", (q) => q.lt("firedAt", now - RETENTION.alertEvents))
        .take(BATCH),
    );
    await purge(
      await ctx.db
        .query("errorSignatures")
        .withIndex("by_last_seen", (q) => q.lt("lastSeenAt", now - RETENTION.errorSignatures))
        .take(BATCH),
    );

    if (hitLimit) {
      await ctx.scheduler.runAfter(0, internal.cleanup.purgeExpired, {});
    }
    return null;
  },
});
