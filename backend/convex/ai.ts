import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import { action, internalMutation } from "./_generated/server";
import { parseAnswer } from "./lib/ai";
import { assertAppKey } from "./lib/auth";
import { aiModel, callClaude, textOf } from "./lib/gateway";
import { ONE_SHOT_PROMPT } from "./lib/prompts";

/**
 * Natural language → read-only Convex query, for the app's Run Query screen.
 * Uses the Convex AI Gateway (no provider API key; billed at provider list price on the Convex
 * invoice, paid plans only). The app runs the result in Convex's read-only query sandbox, so a
 * wrong query can't change data.
 */

export const displayValidator = v.object({
  type: v.union(v.literal("number"), v.literal("ranking"), v.literal("list"), v.literal("text")),
  title: v.optional(v.string()),
  label: v.optional(v.string()),
  value: v.optional(v.string()),
  unit: v.optional(v.string()),
});

export const generateQuery = action({
  args: {
    appKey: v.string(),
    question: v.string(),
    schema: v.string(),
    /** Adds that deployment's data catalog (catalog.ts) to the prompt when one has been built. */
    deploymentName: v.optional(v.string()),
    previousQuery: v.optional(v.string()),
    error: v.optional(v.string()),
  },
  returns: v.object({ query: v.string(), explanation: v.string(), display: v.optional(displayValidator) }),
  handler: async (ctx, { appKey, question, schema, deploymentName, previousQuery, error }) => {
    assertAppKey(appKey);
    const started = Date.now();
    let cost: number | undefined;
    const log = (result: { query?: string; explanation?: string; failure?: string }) =>
      ctx.runMutation(internal.ai.logQuery, {
        question: question.slice(0, 2_000),
        model: aiModel(),
        query: result.query,
        explanation: result.explanation,
        failure: result.failure,
        previousQuery: previousQuery?.slice(0, 8_000),
        previousError: error?.slice(0, 4_000),
        durationMs: Date.now() - started,
        cost,
      });
    if (question.trim().length === 0 && !previousQuery) throw new ConvexError("Ask a question first.");
    if (question.length > 2_000) throw new ConvexError("That question is too long (2,000 characters max).");

    const catalog = deploymentName ? await ctx.runQuery(internal.catalog.textFor, { deploymentName }) : null;
    let userMessage = `Question: ${question.trim() || "(fix the query below)"}`;
    if (previousQuery) {
      userMessage += `\n\nThe previous query:\n${previousQuery.slice(0, 8_000)}`;
      if (error) userMessage += `\n\nfailed with this error, so fix it:\n${error.slice(0, 4_000)}`;
    }

    try {
      const response = await callClaude({
        system: [ONE_SHOT_PROMPT, `Schema:\n${schema.slice(0, 60_000)}${catalog ? `\n\n${catalog}` : ""}`],
        messages: [{ role: "user", content: userMessage }],
        maxTokens: 1_500,
      });
      cost = response.cost;
      const text = textOf(response.content);
      if (!text) throw new ConvexError("The model returned an empty answer. Try rephrasing.");
      const answer = parseAnswer(text);
      await log(answer);
      return answer;
    } catch (failure) {
      await log({ failure: failure instanceof ConvexError ? String(failure.data) : String(failure) });
      throw failure;
    }
  },
});

export const logQuery = internalMutation({
  args: {
    question: v.string(),
    model: v.string(),
    query: v.optional(v.string()),
    explanation: v.optional(v.string()),
    previousQuery: v.optional(v.string()),
    previousError: v.optional(v.string()),
    failure: v.optional(v.string()),
    durationMs: v.number(),
    cost: v.optional(v.number()),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    await ctx.db.insert("aiQueries", args);
    return null;
  },
});
