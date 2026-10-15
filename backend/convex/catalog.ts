import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import { action, internalMutation, internalQuery, query } from "./_generated/server";
import { assertAppKey } from "./lib/auth";
import { callClaude, textOf } from "./lib/gateway";
import { composeCatalog, parseCatalogAnswer, profileText, type DataProfile } from "./lib/catalog";
import { CATALOG_PROMPT } from "./lib/prompts";

/**
 * Data catalog: what each table and field of a deployment means, built once and sent with every
 * AI question (ai.ts, chat.ts). The app profiles the deployment with read-only queries (row
 * counts, fill rates, formats, a few values of low-variety fields, function names) because only
 * it holds the access token; this action turns that profile into plain-language descriptions.
 */

export const build = action({
  args: { appKey: v.string(), deploymentName: v.string(), profile: v.string() },
  returns: v.object({ builtAt: v.number(), tableCount: v.number(), notes: v.array(v.string()) }),
  handler: async (ctx, { appKey, deploymentName, profile }) => {
    assertAppKey(appKey);
    let parsed: DataProfile;
    try {
      parsed = JSON.parse(profile) as DataProfile;
    } catch {
      throw new ConvexError("The data profile couldn't be read.");
    }
    if (!Array.isArray(parsed.tables) || parsed.tables.length === 0) throw new ConvexError("The profile has no tables.");

    const response = await callClaude({
      system: [CATALOG_PROMPT],
      messages: [{ role: "user", content: profileText(parsed).slice(0, 150_000) }],
      maxTokens: 16_000,
    });
    const descriptions = parseCatalogAnswer(textOf(response.content));
    const builtAt = Date.now();
    const text = composeCatalog(parsed, descriptions, builtAt);
    await ctx.runMutation(internal.catalog.save, {
      deploymentName,
      builtAt,
      text,
      tableCount: parsed.tables.length,
      notes: descriptions.notes,
      cost: response.cost,
    });
    return { builtAt, tableCount: parsed.tables.length, notes: descriptions.notes };
  },
});

export const get = query({
  args: { appKey: v.string(), deploymentName: v.string() },
  returns: v.union(
    v.null(),
    v.object({ builtAt: v.number(), text: v.string(), tableCount: v.number(), notes: v.array(v.string()) }),
  ),
  handler: async (ctx, { appKey, deploymentName }) => {
    assertAppKey(appKey);
    const catalog = await ctx.db
      .query("catalogs")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
      .unique();
    if (!catalog) return null;
    return { builtAt: catalog.builtAt, text: catalog.text, tableCount: catalog.tableCount, notes: catalog.notes };
  },
});

export const textFor = internalQuery({
  args: { deploymentName: v.string() },
  returns: v.union(v.null(), v.string()),
  handler: async (ctx, { deploymentName }) => {
    const catalog = await ctx.db
      .query("catalogs")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", deploymentName))
      .unique();
    return catalog?.text ?? null;
  },
});

export const save = internalMutation({
  args: {
    deploymentName: v.string(),
    builtAt: v.number(),
    text: v.string(),
    tableCount: v.number(),
    notes: v.array(v.string()),
    cost: v.optional(v.number()),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("catalogs")
      .withIndex("by_deployment", (q) => q.eq("deploymentName", args.deploymentName))
      .unique();
    if (existing) await ctx.db.replace(existing._id, args);
    else await ctx.db.insert("catalogs", args);
    return null;
  },
});
