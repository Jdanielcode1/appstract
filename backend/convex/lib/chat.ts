import type { ContentBlock, Message, ToolResultBlock, ToolUseBlock } from "./gateway";

/** Tools the chat model can call. run_query is executed by the app; answer ends the turn. */
export const CHAT_TOOLS = [
  {
    name: "run_query",
    description:
      "Run a read-only Convex query on the deployment (in the developer's app) and get its result or error back. Use for exploring values as well as for the final query.",
    input_schema: {
      type: "object",
      properties: {
        code: {
          type: "string",
          description:
            "Only the statements inside the handler, using `ctx` directly; do not wrap them in a function. A single expression is returned automatically; statements must end with return.",
        },
        purpose: { type: "string", description: "A few words on what this query checks, shown to the developer." },
      },
      required: ["code", "purpose"],
    },
  },
  {
    name: "answer",
    description: "Reply to the developer. Call exactly once, after the queries you need, to end your turn.",
    input_schema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The direct answer in one or two sentences, with caveats." },
        result_of: { type: "string", description: "id of the run_query call whose result to show under the text. Omit if none." },
        display: {
          type: "object",
          description:
            'How to show that result. {"type": "number", "title", "unit"} for a single number; {"type": "ranking", "title", "label": row field with the name, "value": row field with the number, "unit"} for rows sorted by a number; {"type": "list", "title", "label"} for other rows; {"type": "text", "title"} for a string.',
          properties: {
            type: { type: "string", enum: ["number", "ranking", "list", "text"] },
            title: { type: "string" },
            label: { type: "string" },
            value: { type: "string" },
            unit: { type: "string" },
          },
          required: ["type"],
        },
        followups: { type: "array", items: { type: "string" }, description: "Up to 3 short follow-up questions." },
      },
      required: ["text"],
    },
  },
];

/** Max run_query calls per question before the model is made to answer. */
export const MAX_QUERIES_PER_TURN = 5;

export type StoredMessage = { role: "user" | "assistant"; content: ContentBlock[] };

const blocks = (content: string | ContentBlock[]): ContentBlock[] =>
  typeof content === "string" ? [{ type: "text", text: content }] : content;

/**
 * tool_use ids in the last assistant message without a tool_result in the message after it.
 * Anthropic requires every tool_use to be answered before the conversation continues.
 */
export function unresolvedToolUses(messages: StoredMessage[]): ToolUseBlock[] {
  const lastAssistant = messages.map((m) => m.role).lastIndexOf("assistant");
  if (lastAssistant === -1) return [];
  const uses = messages[lastAssistant].content.filter((b): b is ToolUseBlock => b.type === "tool_use");
  const answered = new Set(
    messages
      .slice(lastAssistant + 1)
      .flatMap((m) => m.content)
      .filter((b): b is ToolResultBlock => b.type === "tool_result")
      .map((b) => b.tool_use_id),
  );
  return uses.filter((use) => !answered.has(use.id));
}

/** Tool results that close out tool calls the next message would otherwise leave dangling. */
export function closingResults(messages: StoredMessage[]): ToolResultBlock[] {
  return unresolvedToolUses(messages).map((use) => ({
    type: "tool_result",
    tool_use_id: use.id,
    content: use.name === "answer" ? "Shown to the developer." : "Not run: the developer asked something else.",
  }));
}

/** run_query calls since the developer's last question. */
export function queriesThisTurn(messages: StoredMessage[]): number {
  let count = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    const isQuestion = message.role === "user" && message.content.some((b) => b.type === "text");
    if (isQuestion) break;
    count += message.content.filter((b) => b.type === "tool_use" && b.name === "run_query").length;
  }
  return count;
}

/** Messages for the model; consecutive same-role messages are merged as Anthropic requires. */
export function toModelMessages(messages: StoredMessage[]): Message[] {
  const merged: Message[] = [];
  for (const message of messages) {
    const last = merged[merged.length - 1];
    if (last && last.role === message.role) last.content = [...blocks(last.content), ...message.content];
    else merged.push({ role: message.role, content: [...message.content] });
  }
  return merged;
}

export type ChatQuery = { id: string; code: string; purpose: string };
export type ChatAnswer = {
  text: string;
  resultOf?: string;
  display?: { type: "number" | "ranking" | "list" | "text"; title?: string; label?: string; value?: string; unit?: string };
  followups: string[];
};

/** Reads the answer tool's input defensively. */
export function readAnswer(input: Record<string, unknown>): ChatAnswer {
  const display = input.display as Record<string, unknown> | undefined;
  const types = ["number", "ranking", "list", "text"];
  const str = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim().slice(0, 200) : undefined);
  return {
    text: typeof input.text === "string" ? input.text.trim() : "",
    resultOf: str(input.result_of),
    display:
      display && typeof display.type === "string" && types.includes(display.type)
        ? {
            type: display.type as "number" | "ranking" | "list" | "text",
            title: str(display.title),
            label: str(display.label),
            value: str(display.value),
            unit: str(display.unit),
          }
        : undefined,
    followups: Array.isArray(input.followups)
      ? input.followups.filter((f): f is string => typeof f === "string" && f.trim().length > 0).slice(0, 3)
      : [],
  };
}

export type ChatTurn = { question: string; queries: ChatQuery[]; answer?: ChatAnswer };

/** The conversation as the app shows it: each question with the queries run and the answer. */
export function toTurns(messages: StoredMessage[]): ChatTurn[] {
  const turns: ChatTurn[] = [];
  for (const message of messages) {
    if (message.role === "user") {
      const text = message.content.find((b) => b.type === "text");
      if (text && text.type === "text") turns.push({ question: text.text, queries: [] });
      continue;
    }
    const turn = turns[turns.length - 1];
    if (!turn) continue;
    for (const block of message.content) {
      if (block.type !== "tool_use") continue;
      if (block.name === "run_query") {
        turn.queries.push({ id: block.id, code: String(block.input.code ?? ""), purpose: String(block.input.purpose ?? "") });
      } else if (block.name === "answer") {
        turn.answer = readAnswer(block.input);
      }
    }
    const text = message.content.find((b) => b.type === "text");
    if (!turn.answer && message.content.every((b) => b.type !== "tool_use") && text && text.type === "text") {
      turn.answer = { text: text.text, followups: [] };
    }
  }
  return turns;
}
