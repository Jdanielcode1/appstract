import { getServiceToken } from "convex/server";
import { ConvexError } from "convex/values";

/**
 * Calls Claude through the Convex AI Gateway's Anthropic Messages endpoint. Only works inside an
 * action (getServiceToken). The gateway bills at provider list price and reports `usage.cost`.
 */

/**
 * Default model. Override with the AI_MODEL env var (`npx convex env set AI_MODEL <id>`), using
 * any ID from the gateway's model list. The chat forces tool calls and every request turns
 * thinking off, so pick a model that accepts both: Claude Haiku 5.5 / 4.5, Sonnet 5 / 4.x, or
 * Opus 4.x. Claude Sonnet 5.5, Opus 5.5 and Fable 5.1 reject both and need code changes.
 */
export const DEFAULT_MODEL = "anthropic/claude-haiku-5.5";

/** The model in use: AI_MODEL if set, otherwise DEFAULT_MODEL. */
export function aiModel(): string {
  return process.env.AI_MODEL?.trim() || DEFAULT_MODEL;
}
const GATEWAY_URL = "https://ai-gateway.convex.dev/v1/messages";

export type TextBlock = { type: "text"; text: string };
export type ToolUseBlock = { type: "tool_use"; id: string; name: string; input: Record<string, unknown> };
export type ToolResultBlock = { type: "tool_result"; tool_use_id: string; content: string; is_error?: boolean };
export type ContentBlock = TextBlock | ToolUseBlock | ToolResultBlock;
export type Message = { role: "user" | "assistant"; content: string | ContentBlock[] };

export type ClaudeResponse = {
  content: ContentBlock[];
  stopReason: string;
  /** USD, when the gateway reports it. */
  cost?: number;
};

/**
 * `system` parts are sent as separate blocks with prompt caching, so repeated calls with the same
 * instructions/schema (chat steps, retries) pay ~10% for that prefix.
 */
export async function callClaude(args: {
  system: string[];
  messages: Message[];
  maxTokens: number;
  tools?: unknown[];
  toolChoice?: unknown;
}): Promise<ClaudeResponse> {
  let token: string;
  try {
    token = await getServiceToken("ai-gateway");
  } catch {
    throw new ConvexError("The Convex AI Gateway isn't available for this backend. It needs a paid Convex plan and convex 1.45+.");
  }
  const system = args.system
    .filter((part) => part.trim().length > 0)
    .map((text) => ({ type: "text", text, cache_control: { type: "ephemeral" } }));
  const response = await fetch(GATEWAY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: aiModel(),
      max_tokens: args.maxTokens,
      // Haiku 5.5 thinks by default; these short, structured tasks don't need it, and it would
      // spend the max_tokens budget before the answer.
      thinking: { type: "disabled" },
      system,
      messages: args.messages,
      ...(args.tools ? { tools: args.tools } : {}),
      ...(args.toolChoice ? { tool_choice: args.toolChoice } : {}),
    }),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new ConvexError(`AI Gateway error (${response.status}): ${body.slice(0, 300)}`);
  }
  const parsed = JSON.parse(body) as { content?: ContentBlock[]; stop_reason?: string; usage?: { cost?: number } };
  return { content: parsed.content ?? [], stopReason: parsed.stop_reason ?? "", cost: parsed.usage?.cost };
}

/** All text blocks joined. */
export function textOf(content: ContentBlock[]): string {
  return content
    .filter((block): block is TextBlock => block.type === "text")
    .map((block) => block.text)
    .join("")
    .trim();
}
