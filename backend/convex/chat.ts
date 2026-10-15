import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { displayValidator } from "./ai";
import { assertAppKey } from "./lib/auth";
import {
  CHAT_TOOLS,
  MAX_QUERIES_PER_TURN,
  queriesThisTurn,
  readAnswer,
  toModelMessages,
  toTurns,
  unresolvedToolUses,
  type StoredMessage,
} from "./lib/chat";
import { callClaude, type ContentBlock, type ToolResultBlock, type ToolUseBlock } from "./lib/gateway";
import { CHAT_PROMPT } from "./lib/prompts";

/**
 * Chat about a deployment's data. Each call to `send` is one model step: the model either asks
 * the app to run queries (status "run"; the app runs them with its own token in Convex's
 * read-only sandbox and calls `send` again with the results) or answers (status "answer").
 * Queries never run here: this backend has no access to the deployment's data.
 */

const queryValidator = v.object({ id: v.string(), code: v.string(), purpose: v.string() });
const answerValidator = v.object({
  text: v.string(),
  resultOf: v.optional(v.string()),
  display: v.optional(displayValidator),
  followups: v.array(v.string()),
});

export const send = action({
  args: {
    appKey: v.string(),
    deploymentName: v.string(),
    schema: v.string(),
    threadId: v.optional(v.id("chatThreads")),
    question: v.optional(v.string()),
    /** Results of the queries requested by the previous step, keyed by tool call id. */
    toolResults: v.optional(v.array(v.object({ id: v.string(), content: v.string(), isError: v.boolean() }))),
  },
  returns: v.object({
    threadId: v.id("chatThreads"),
    status: v.union(v.literal("run"), v.literal("answer")),
    queries: v.array(queryValidator),
    answer: v.optional(answerValidator),
  }),
  handler: async (ctx, args) => {
    assertAppKey(args.appKey);
    const question = args.question?.trim();
    if (!args.threadId && !question) throw new ConvexError("Ask a question first.");
    if (question && question.length > 2_000) throw new ConvexError("That question is too long (2,000 characters max).");

    const threadId: Id<"chatThreads"> =
      args.threadId ??
      (await ctx.runMutation(internal.chat.createThread, { deploymentName: args.deploymentName, title: question!.slice(0, 80) }));
    const stored: StoredMessage[] = await ctx.runQuery(internal.chat.storedMessages, { threadId });

    // Close every open tool call (with the app's results where given), then add the question.
    const provided = new Map((args.toolResults ?? []).map((result) => [result.id, result]));
    const results: ToolResultBlock[] = unresolvedToolUses(stored).map((use) => {
      const result = provided.get(use.id);
      if (result) return { type: "tool_result", tool_use_id: use.id, content: result.content.slice(0, 12_000), is_error: result.isError };
      return {
        type: "tool_result",
        tool_use_id: use.id,
        content: use.name === "answer" ? "Shown to the developer." : "Not run: the developer asked something else.",
      };
    });
    const userContent: ContentBlock[] = [...results, ...(question ? [{ type: "text" as const, text: question }] : [])];
    if (userContent.length === 0) throw new ConvexError("Nothing to send.");
    await ctx.runMutation(internal.chat.appendMessage, { threadId, role: "user", content: JSON.stringify(userContent) });
    const history: StoredMessage[] = [...stored, { role: "user", content: userContent }];

    const catalog = await ctx.runQuery(internal.catalog.textFor, { deploymentName: args.deploymentName });
    const mustAnswer = queriesThisTurn(history) >= MAX_QUERIES_PER_TURN;
    const response = await callClaude({
      system: [CHAT_PROMPT, `Schema:\n${args.schema.slice(0, 60_000)}${catalog ? `\n\n${catalog}` : ""}`],
      messages: toModelMessages(history.slice(-60)),
      tools: CHAT_TOOLS,
      toolChoice: mustAnswer ? { type: "tool", name: "answer" } : { type: "any" },
      maxTokens: 2_000,
    });
    await ctx.runMutation(internal.chat.appendMessage, {
      threadId,
      role: "assistant",
      content: JSON.stringify(response.content),
      cost: response.cost,
    });

    const uses = response.content.filter((block): block is ToolUseBlock => block.type === "tool_use");
    const queries = uses
      .filter((use) => use.name === "run_query")
      .map((use) => ({ id: use.id, code: String(use.input.code ?? ""), purpose: String(use.input.purpose ?? "") }));
    if (queries.length > 0) return { threadId, status: "run" as const, queries };
    const answerUse = uses.find((use) => use.name === "answer");
    const answer = answerUse
      ? readAnswer(answerUse.input)
      : { text: response.content.map((b) => (b.type === "text" ? b.text : "")).join("").trim() || "I couldn't answer that.", followups: [] };
    return { threadId, status: "answer" as const, queries: [], answer };
  },
});

export const threads = query({
  args: { appKey: v.string(), deploymentName: v.string() },
  returns: v.array(v.object({ _id: v.id("chatThreads"), title: v.string(), updatedAt: v.number() })),
  handler: async (ctx, { appKey, deploymentName }) => {
    assertAppKey(appKey);
    const rows = await ctx.db
      .query("chatThreads")
      .withIndex("by_deployment_updated", (q) => q.eq("deploymentName", deploymentName))
      .order("desc")
      .take(30);
    return rows.map((row) => ({ _id: row._id, title: row.title, updatedAt: row.updatedAt }));
  },
});

export const turns = query({
  args: { appKey: v.string(), threadId: v.id("chatThreads") },
  returns: v.array(v.object({ question: v.string(), queries: v.array(queryValidator), answer: v.optional(answerValidator) })),
  handler: async (ctx, { appKey, threadId }) => {
    assertAppKey(appKey);
    const messages = await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q) => q.eq("threadId", threadId))
      .take(500);
    return toTurns(messages.map((m) => ({ role: m.role, content: JSON.parse(m.content) as ContentBlock[] })));
  },
});

export const deleteThread = mutation({
  args: { appKey: v.string(), threadId: v.id("chatThreads") },
  returns: v.null(),
  handler: async (ctx, { appKey, threadId }) => {
    assertAppKey(appKey);
    const messages = await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q) => q.eq("threadId", threadId))
      .take(1_000);
    for (const message of messages) await ctx.db.delete(message._id);
    await ctx.db.delete(threadId);
    return null;
  },
});

export const createThread = internalMutation({
  args: { deploymentName: v.string(), title: v.string() },
  returns: v.id("chatThreads"),
  handler: async (ctx, { deploymentName, title }) =>
    await ctx.db.insert("chatThreads", { deploymentName, title, updatedAt: Date.now() }),
});

export const storedMessages = internalQuery({
  args: { threadId: v.id("chatThreads") },
  returns: v.array(v.object({ role: v.union(v.literal("user"), v.literal("assistant")), content: v.any() })),
  handler: async (ctx, { threadId }) => {
    const messages = await ctx.db
      .query("chatMessages")
      .withIndex("by_thread", (q) => q.eq("threadId", threadId))
      .take(500);
    return messages.map((m) => ({ role: m.role, content: JSON.parse(m.content) }));
  },
});

export const appendMessage = internalMutation({
  args: {
    threadId: v.id("chatThreads"),
    role: v.union(v.literal("user"), v.literal("assistant")),
    content: v.string(),
    cost: v.optional(v.number()),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    await ctx.db.insert("chatMessages", args);
    await ctx.db.patch(args.threadId, { updatedAt: Date.now() });
    return null;
  },
});
